# Stage 4 — Ansible guest readiness (first increment)

**Current scope: read-only inventory and readiness only.** No host bootstrap,
package installation, containerd configuration, Kubernetes installation,
VM start/stop or reboot is performed in this increment.

## Sequence

1. Stage 1–3 sandbox guests must already exist and be powered on **by the
   operator**. Do not target any pre-existing or protected VMs.
2. On a trusted management system, fetch a full commit SHA from the **private**
   environment configuration repository. A moving branch name is not accepted
   by the inventory renderer.
3. The renderer reuses Sentinel's strict YAML policy and writes native Ansible
   YAML inventory under the operator's private home state directory, outside
   the public Git checkout. It never prints VM IPs or usernames to standard
   output. Existing inventory files are not overwritten.
4. Run the non-mutating guest readiness playbook. It uses SSH host-key checking,
   confirms hostname and configured IP, checks cloud-init and passwordless
   sudo, and checks that Python 3 is available.

## Toolchain discovery (safe to run now)

Run from PowerShell:

```powershell
wsl -d Ubuntu-26.04 -- bash -lc 'command -v ansible-playbook || echo ANSIBLE_NOT_INSTALLED; python3 --version'
```

If Ansible is missing, install it in a dedicated WSL virtual environment
after checking distribution package compatibility. **Do not install it on
the sandbox guests.** Ansible acts from the management controller over SSH.

## Private inventory creation (after controller prerequisites are ready)

The following shell is for **Ubuntu WSL**, with `CONFIG_ROOT` set to the
existing private configuration clone as a WSL filesystem path.
`REPO_ROOT` is the public platform clone mounted under `/mnt/c`.

```bash
CONFIG_ROOT=/mnt/c/path/to/your/private-config-clone
REPO_ROOT=/mnt/c/path/to/your/platform-clone
REVISION=$(git -C "$CONFIG_ROOT" rev-parse origin/main)
python3 "$REPO_ROOT/infrastructure/ansible/render_inventory.py" \
  --config-repo "$CONFIG_ROOT" \
  --revision "$REVISION" \
  --environment lab

INV="$HOME/.local/state/sentinel/inventory-lab-${REVISION:0:12}.yml"
ansible-inventory -i "$INV" --graph
ansible-playbook --syntax-check \
  "$REPO_ROOT/infrastructure/ansible/playbooks/00-readiness.yml"
```

**Before remotely executing the playbook**, the operator must verify that
all expected sandbox VMs are running and that the SSH host keys have been
authenticated/accepted in WSL via a trusted channel. Do not disable host-key
validation or use the protected production inventory.

```bash
ansible-playbook -i "$INV" \
  "$REPO_ROOT/infrastructure/ansible/playbooks/00-readiness.yml"
```

The playbook reads guest state and reports PASS/FAIL. It should report
`changed=0` for each node. Failed SSH or identity checks are blockers,
not reasons to switch off security checks.

## Acceptance criteria

- Private inventory produced from an immutable configuration revision
- No real inventory copied to public Git or GitHub Actions logs
- Both target guests authenticated via SSH, with strict host-key checks
- Hostnames and guest IPs match desired inventory
- Cloud-init finished, non-interactive sudo works, Python 3 available
- No changes made to VM resources or guest package/configuration state

**Only after these gates pass:** Stage 4.2 Ansible OS baseline and containerd
installation, in a separate reviewable change with explicit apply approval.
