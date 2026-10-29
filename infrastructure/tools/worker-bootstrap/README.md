# Sentinel worker — automated Hyper-V provisioning (lab-only)

This provisions a **new** worker `k8s-w01` using the **official Ubuntu 26.04 cloud image**, not the interactive Ubuntu Server installer. It uses **PowerShell + Hyper-V + WSL qemu-img + cloud-init**. It does not alter the existing `k8s-cp01` VM or install Kubernetes.

## Prerequisites

1. Windows 11 Pro Hyper-V enabled, `Default Switch` available, **Administrator PowerShell**.
2. WSL with an Ubuntu Linux distribution. In PowerShell, check: `wsl -l -v`.
3. In WSL, install tools: `sudo apt-get update && sudo apt-get install -y qemu-utils cloud-image-utils`.
4. A Windows SSH public key at `~/.ssh/id_ed25519.pub`. Check in PowerShell: `Test-Path "$HOME\.ssh\id_ed25519.pub"`. If none exists, create an ED25519 key: `ssh-keygen -t ed25519 -f "$HOME\.ssh\id_ed25519"` and choose a passphrase. **Never share the private key.**
5. Internet access to `cloud-images.ubuntu.com`. The script downloads around 819 MB plus a checksum listing and verifies SHA256 before provisioning.

## Run

Copy `New-SentinelWorker.ps1` to a working folder. From **Administrator PowerShell** in that folder:

```powershell
.\New-SentinelWorker.ps1 -Name k8s-w01
```

If Windows blocks scripts, inspect the file first (`Get-Content .\New-SentinelWorker.ps1`). Prefer a narrowly scoped policy for the current session over a permanent machine-wide bypass. Do not disable endpoint security or override company policy.

## What it changes

- Downloads and verifies an official Ubuntu 26.04 released cloud image under `C:\Sentinel\Images`.
- Creates **only** `C:\Sentinel\VMs\k8s-w01`, with a dedicated 60 GB expandable VHDX and cloud-init seed ISO.
- Creates a Hyper-V Generation 2 VM with 2 vCPUs, 4 GiB RAM, Ubuntu-UEFI-compatible Secure Boot and `Default Switch`.
- Boots from the image and uses cloud-init to create account `orzu` with SSH public-key-only login, root login disabled and passwordless sudo (**lab only; do not use this privilege configuration in production**).
- Exits on an existing VM registration or worker directory; does **not** remove existing VMs or disks.

**Note:** A checksum comparison protects against accidental download corruption, but production supply-chain verification would also validate the **signature** on Canonical's checksum manifest and manage approved image versions centrally.

## Inspect

```powershell
Get-VM -Name k8s-w01
Get-VMNetworkAdapter -VMName k8s-w01 | Select-Object VMName, IPAddresses
```

IP assignment and cloud-init provisioning are asynchronous. The Hyper-V Default Switch leases may change. When an IPv4 address appears, test `Test-NetConnection <IP> -Port 22` and then connect using your private key: `ssh -i "$HOME\.ssh\id_ed25519" orzu@<IP>`.

Inspect bootstrap if SSH isn't available by opening the Hyper-V console. On the guest `cloud-init status --wait` and `sudo cat /var/log/cloud-init-output.log` show provisioning progress. Neither the source VM nor any other VM needs to be deleted/recreated.

## What comes next

After a successful worker bootstrap, move the configuration into a Git repository and run the same provisioning script from a **restricted, dedicated local runner**, after validation and approval. Next, use Ansible to install containerd, kubelet and kubeadm, with a pinned Kubernetes version. The worker will only join the cluster when explicitly instructed.

**Technical references:** [Canonical's Hyper-V cloud-image instructions](https://ubuntu.com/blog/how-to-use-ubuntu-on-windows), [Canonical Ubuntu 26.04 cloud images](https://cloud-images.ubuntu.com/releases/26.04/release/), [cloud-init NoCloud](https://docs.cloud-init.io/en/latest/reference/datasources/nocloud.html), [Hyper-V PowerShell firmware configuration](https://learn.microsoft.com/en-us/powershell/module/hyper-v/set-vmfirmware).
