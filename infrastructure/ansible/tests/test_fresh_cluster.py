"""Offline profile, trust, approval and rendering tests. No subprocess/network calls."""
import base64
import copy
import hashlib
import importlib.util
import json
import re
from pathlib import Path
import sys
import unittest

import yaml

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import fresh_cluster as fresh

spec = importlib.util.spec_from_file_location("fresh_publisher", Path(__file__).resolve().parents[2] / "level1/src/publish_firstboot_kvp.py")
publisher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publisher)


def binding(worker=False):
    name = 'w01' if worker else 'cp01'
    suffix = '31' if worker else '30'
    manifest = dict(schema=3, purpose='sentinel-fresh-cluster-v1', node=name,
                    privateIP='10.78.0.'+suffix, managementMAC='02AA780001'+suffix,
                    privateMAC='02AA780000'+suffix, kubernetesInstall=False,
                    nonce=('b' if worker else 'a')*64, sourceImageSHA256='c'*64,
                    vmId='11111111-1111-4111-8111-11111111111'+('2' if worker else '1'))
    wire = b'\x00\x00\x00\x0bssh-ed25519\x00\x00\x00\x20'+bytes([2 if worker else 1])*32
    line = manifest['privateIP']+' ssh-ed25519 '+base64.b64encode(wire).decode()+'\n'
    return fresh.validate_binding(name, manifest, line)


class FreshClusterTests(unittest.TestCase):
    def test_fresh_seed_requires_separate_schema(self):
        for b in (binding(), binding(True)):
            seed = dict(schema=3, node=b['node'], ip=b['privateIP'], nonce=b['nonce'])
            publisher.validate_manifest(seed)
            with self.assertRaises(publisher.Blocked):
                publisher.validate_manifest(dict(seed, schema=2))

    def test_cross_profile_and_unknown_seed_rejected(self):
        for node, ip in [('sentinel-l1-w01','10.78.0.11'), ('k8s-cp01','10.77.0.10'),
                         ('sentinel-e2e-auto20','10.78.0.20'), ('unknown',None),
                         ('w01','10.78.0.30')]:
            with self.subTest(node=node), self.assertRaises(publisher.Blocked):
                publisher.validate_manifest(dict(schema=3,node=node,ip=ip,nonce='a'*64))

    def test_original_disposable_contract_still_works(self):
        publisher.validate_manifest(dict(schema=2,node='sentinel-e2e-auto20',ip='10.78.0.20',nonce='a'*64))

    def test_pair_requires_distinct_vm_nonce_and_host_key(self):
        for field in ('nonce','vmId'):
            a,b = binding(),binding(True)
            b[field]=a[field]
            with self.assertRaises(fresh.Blocked): fresh.validate_pair([a,b])
        a,b=binding(),binding(True)
        b['trustedLine']=b['privateIP']+' '+' '.join(a['trustedLine'].split()[1:])+'\n'
        with self.assertRaises(fresh.Blocked): fresh.validate_pair([a,b])

    def test_pair_requires_same_image(self):
        a,b=binding(),binding(True)
        b['sourceImageSHA256']='d'*64
        with self.assertRaises(fresh.Blocked): fresh.validate_pair([a,b])

    def test_manifest_changes_block(self):
        b=binding()
        for field,value in [('purpose','old'),('schema',2),('kubernetesInstall',0),
                            ('privateIP','10.78.0.10'),('vmId','00000000-0000-0000-0000-000000000000')]:
            changed=dict(b,**{field:value})
            with self.subTest(field=field), self.assertRaises((fresh.Blocked,ValueError)):
                fresh.validate_binding(b['node'],changed,b['trustedLine'])

    def test_trust_does_not_accept_multiple_or_foreign_records(self):
        b=binding()
        for line in [b['trustedLine']*2, b['trustedLine'].replace('10.78.0.30','10.78.0.10'),
                     b['trustedLine'].replace('ssh-ed25519','ssh-rsa')]:
            with self.assertRaises(fresh.Blocked): fresh.validate_binding(b['node'],b,line)

    def test_identity_gate_covers_every_supported_stage(self):
        # Regression: a stage added to the runner must also be allowed through
        # the shared firstboot/cluster identity check run before each playbook.
        import ast
        identity = yaml.safe_load((fresh.PLAYBOOKS / "05-fresh-identity.yml").read_text())
        gate = identity[0]["tasks"][0]["ansible.builtin.assert"]["that"]
        stage_checks = [check for check in gate if check.startswith("sentinel_fresh_stage in ")]
        self.assertEqual(len(stage_checks), 1)
        allowed = set(ast.literal_eval(stage_checks[0].split(" in ", 1)[1]))
        self.assertEqual(allowed, set(fresh.STAGES))

        # A reboot occurs on an initialized cluster. All pre-reboot identity,
        # node-name and Kubernetes network checks must remain enforced.
        post_init_tasks = identity[1]["tasks"]
        self.assertEqual(len(post_init_tasks), 3)
        for task in post_init_tasks:
            when = task["when"]
            stages = set(ast.literal_eval(when.split(" in ", 1)[1]))
            self.assertIn("reboot-test", stages)
            self.assertIn("verify", stages)
        self.assertNotIn("reboot-test", fresh.READ_ONLY)
        with self.assertRaises(fresh.Blocked):
            fresh.require_approval("reboot-test", None)
        fresh.require_approval("reboot-test", "FRESH_REBOOT_TEST")

    def test_approvals_cannot_cross_stages(self):
        for stage in fresh.STAGES:
            if stage in fresh.READ_ONLY:
                fresh.require_approval(stage,None)
                with self.assertRaises(fresh.Blocked): fresh.require_approval(stage,'FRESH_BASELINE')
            else:
                for token in (None,'wrong','FRESH_CREATE_CONTROL_PLANE'):
                    with self.assertRaises(fresh.Blocked): fresh.require_approval(stage,token)
                fresh.require_approval(stage,'FRESH_'+stage.upper().replace('-','_'))

    def test_inventory_has_only_fresh_targets_and_strict_ssh(self):
        inv=fresh.build_inventory([binding(),binding(True)],'/home/orzu/.ssh/id_ed25519',Path('/home/orzu/private/known_hosts'))
        hosts=inv['all']['children']['sentinel_sandbox']['hosts']
        self.assertEqual(set(hosts),set(fresh.NODES))
        for host in hosts.values():
            self.assertIn('StrictHostKeyChecking=yes',host['ansible_ssh_common_args'])
            self.assertIn('GlobalKnownHostsFile=/dev/null',host['ansible_ssh_common_args'])
            self.assertNotIn('accept-new',host['ansible_ssh_common_args'])

    def test_controller_key_rejects_shell_or_other_paths(self):
        for key in ('/tmp/key','/home/orzu/.ssh/id_ed25519;echo bad','/home/a b/.ssh/id_ed25519'):
            with self.assertRaises(fresh.Blocked): fresh.build_inventory([binding(),binding(True)],key,Path('/home/x/trust'))

    def test_real_playbooks_render_without_changing_originals(self):
        for stage,path in fresh.STAGES.items():
            source=(fresh.PLAYBOOKS/path).read_text()
            rendered=fresh.render_playbook(stage,source)
            self.assertIsInstance(yaml.safe_load(rendered),list)
            if stage=='init':
                self.assertIn(fresh.SERVICE_CIDR,rendered)
                self.assertIn(fresh.POD_CIDR,rendered)
                self.assertIn('10.96.0.0/12',source)
            if stage not in ('init','cni','network-test'): self.assertEqual(source,rendered)

    def test_reboot_waits_for_kubelet_and_worker_node_ready(self):
        # Regression: reboot module only waits for SSH; kubelet may still be
        # 'activating' and must get a bounded, non-mutating startup window.
        plays = yaml.safe_load((fresh.PLAYBOOKS / "170-fresh-reboot-persistence.yml").read_text())
        self.assertEqual(len(plays), 2)
        second = plays[1]
        self.assertEqual(second["serial"], 1)
        self.assertEqual(second["order"], "reverse_inventory")
        tasks = second["tasks"]
        reboots = [t for t in tasks if "ansible.builtin.reboot" in t]
        self.assertEqual(len(reboots), 1)
        services = next(t for t in tasks if t["name"].startswith("Wait for runtime services"))
        self.assertEqual(services["loop"], ["kubelet", "containerd"])
        self.assertEqual(services["retries"], 36)
        self.assertEqual(services["delay"], 10)
        self.assertIn("after_services.rc == 0", services["until"])
        self.assertIn("'active'", services["until"])
        self.assertEqual(services["changed_when"], False)
        ready = next(t for t in tasks if t["name"].startswith("Require recovered Kubernetes Node"))
        self.assertEqual(ready["delegate_to"], "cp01")
        self.assertEqual(ready["retries"], 6)
        self.assertEqual(ready["delay"], 10)
        self.assertIn("node/{{ inventory_hostname }}", ready["ansible.builtin.command"]["argv"])
        self.assertIn("after_node_ready.rc == 0", ready["until"])
        self.assertLess(tasks.index(services), tasks.index(ready))
        for component in ("Flannel", "CoreDNS"):
            check = next(t for t in tasks if t["name"].startswith("Require " + component + " restored"))
            self.assertEqual(check["delegate_to"], "cp01")
            self.assertEqual(check["when"], "inventory_hostname == 'cp01'")
        self.assertFalse(any("ansible.builtin.systemd_service" in t for t in tasks))

    def test_network_probes_accept_new_pod_cidr_and_reject_old(self):
        source=(fresh.PLAYBOOKS/fresh.STAGES['network-test']).read_text()
        rendered=fresh.render_playbook('network-test',source)
        patterns=re.findall(r"status[.]podIP is match\('([^']+)'\)", rendered)
        self.assertEqual(len(patterns),2)
        for pattern in patterns:
            self.assertRegex('10.245.0.5',pattern)
            self.assertRegex('10.245.255.250',pattern)
            for foreign in ('10.244.0.5','10.78.0.30','10.112.0.10'):
                self.assertIsNone(re.fullmatch(pattern,foreign))
        self.assertEqual(source.count('^10[.]244[.][0-9]+[.][0-9]+$'),2)
        self.assertNotIn('^10[.]244[.]',rendered)

    def test_network_probe_source_drift_blocks_render(self):
        source=(fresh.PLAYBOOKS/fresh.STAGES['network-test']).read_text()
        with self.assertRaises(fresh.Blocked):
            fresh.render_playbook('network-test',source.replace('^10[.]244[.]','^10[.]243[.]',1))

    def test_unexpected_source_layout_rejected(self):
        for text in ('nothing','10.244.0.0/16 10.244.0.0/16'):
            with self.assertRaises(fresh.Blocked): fresh.render_playbook('cni',text)

    def flannel(self):
        return yaml.safe_dump_all([
            {'apiVersion':'v1','kind':'ConfigMap','metadata':{'name':'kube-flannel-cfg'},
             'data':{'net-conf.json':json.dumps({'Network':'10.244.0.0/16','Backend':{'Type':'vxlan'}})}},
            {'apiVersion':'apps/v1','kind':'DaemonSet','metadata':{'name':'kube-flannel-ds'},
             'spec':{'template':{'spec':{'containers':[{'name':'kube-flannel',
                'image':'ghcr.io/flannel-io/flannel:v0.28.10','args':['--ip-masq','--kube-subnet-mgr']}]}}}}
        ],sort_keys=False).encode()

    def test_flannel_keeps_upstream_and_rendered_hashes_distinct(self):
        payload=self.flannel()
        digest=hashlib.sha256(payload).hexdigest()
        rendered=fresh.render_flannel(payload,digest)
        self.assertNotEqual(hashlib.sha256(rendered).hexdigest(),digest)
        docs=list(yaml.safe_load_all(rendered))
        self.assertEqual(json.loads(docs[0]['data']['net-conf.json'])['Network'],fresh.POD_CIDR)
        self.assertIn('--iface=sentinel0',docs[1]['spec']['template']['spec']['containers'][0]['args'])
        self.assertIn(b'10.244.0.0/16',payload)

    def test_flannel_wrong_hash_or_existing_interface_override_blocked(self):
        payload=self.flannel()
        with self.assertRaises(fresh.Blocked): fresh.render_flannel(payload,'0'*64)
        changed=payload.replace(b'--ip-masq',b'--iface=eth0')
        with self.assertRaises(fresh.Blocked): fresh.render_flannel(changed,hashlib.sha256(changed).hexdigest())


if __name__=='__main__': unittest.main()
