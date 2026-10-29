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

## Normal use — one PowerShell command

From the public platform checkout on the Windows management host, with the
trusted private config repository cloned locally:

```powershell
.\infrastructure\ansible\Invoke-SentinelReadiness.ps1 -ConfigRepo 'C:\ExamplePrivateConfig'
```

The script resolves the current private `origin/main` to its full commit,
converts Windows paths to WSL paths without shell interpolation, invokes
the Ubuntu WSL controller, derives Ansible inventory from validated private
YAML, pins existing trusted Windows SSH host keys, and runs the read-only
playbook. No copying into a public repo and no repeated hand-crafted Bash
commands. Real paths are supplied only at execution time.

## Single-command controller workflow

Use the new `run_readiness.py` entrypoint **inside Ubuntu WSL**, after
switching to this PR's branch. The operator supplies an existing local private
configuration clone, an immutable Git commit SHA, and the Windows
`known_hosts` file mounted under `/mnt/c`:

```bash
REV=$(git -C /mnt/c/path/to/private-config rev-parse origin/main)
python3 infrastructure/ansible/run_readiness.py \
  --config-repo /mnt/c/path/to/private-config \
  --revision "$REV" \
  --environment lab \
  --trusted-known-hosts /mnt/c/Users/EXAMPLE/.ssh/known_hosts
```

The entrypoint validates private YAML, extracts target IPs, reads *only*
existing matching SSH keys from the supplied trust store, pins those records
under a private WSL state path with restrictive permissions, emits a native
Ansible inventory bound to that trust file, checks playbook syntax, and runs
the read-only readiness playbook. Later invocations are idempotent if the
private config and trusted key records are unchanged. A missing or changed
trusted host key blocks the run rather than triggering automatic acceptance.

**Trust prerequisite:** Windows' existing host keys must have been
authenticated via a trusted channel when they were first accepted. This
script cannot independently prove historical trust. This process does not
transfer private SSH keys or bridge the Windows SSH agent: WSL must already
have access to an authorized SSH identity. Failed SSH authentication is a
BLOCKED result to investigate, not a reason to disable host-key checking.

No VM power operations, packages or system changes are performed. Expected
result: `TRUST_READY`, `INVENTORY_READY`, Ansible guest checks, then
`STAGE4_READY`.

## Manual troubleshooting (not the normal workflow)

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
