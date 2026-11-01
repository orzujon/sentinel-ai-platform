#!/usr/bin/env bash
set -euo pipefail
umask 077
export DEBIAN_FRONTEND=noninteractive
STATUS=/var/lib/sentinel/firstboot-kvp.status
install -d -m 0700 /var/lib/sentinel
mark_failed() {
  printf 'BLOCKED\n' > "$STATUS"
  echo 'FIRSTBOOT_KVP_BLOCKED: use guest console, never TOFU SSH' >&2
}
trap mark_failed ERR
[[ $(id -u) -eq 0 ]] || { echo 'BLOCKED: root required' >&2; exit 2; }
[[ -f /etc/sentinel/bootstrap.json ]] || { echo 'BLOCKED: seed config missing' >&2; exit 2; }
[[ -f /usr/local/lib/sentinel/publish_firstboot_kvp.py ]] || { echo 'BLOCKED: publisher missing' >&2; exit 2; }
[[ ! -e /etc/kubernetes/kubelet.conf && ! -e /etc/kubernetes/admin.conf ]] ||
  { echo 'BLOCKED: existing Kubernetes guest' >&2; exit 2; }
kernel="$(uname -r)"
[[ "$kernel" =~ ^[0-9]+\.[0-9]+\.[0-9]+-[0-9]+-generic$ ]] ||
  { echo 'BLOCKED: unrecognised kernel ABI' >&2; exit 2; }
generic_base="${kernel%-generic}"
echo "FIRSTBOOT_KVP_PACKAGE_PLAN: kernel=$kernel"
apt-get update -o Acquire::Retries=1 -o Acquire::http::Timeout=20
packages=(linux-cloud-tools-common "linux-cloud-tools-${generic_base}" "linux-cloud-tools-${kernel}")
for package in "${packages[@]}"; do
  candidate="$(apt-cache policy "$package" | awk '/Candidate:/ {print $2; exit}')"
  [[ -n "$candidate" && "$candidate" != "(none)" ]] ||
    { echo "BLOCKED: missing signed Ubuntu package candidate for $package" >&2; exit 2; }
done
apt-get install -y --no-install-recommends "${packages[@]}"
systemctl enable --now hv-kvp-daemon.service
systemctl is-active --quiet hv-kvp-daemon.service
[[ -c /dev/vmbus/hv_kvp ]] || { echo 'BLOCKED: KVP device absent' >&2; exit 2; }
pool_count=0
for pool in /var/lib/hyperv/.kvp_pool_1 /var/opt/hyperv/.kvp_pool_1; do
  if [[ -f "$pool" && ! -L "$pool" ]]; then (( pool_count+=1 )); fi
done
[[ "$pool_count" -eq 1 ]] || { echo 'BLOCKED: exactly one daemon KVP pool required' >&2; exit 2; }
python3 /usr/local/lib/sentinel/publish_firstboot_kvp.py \
  --mode publish --approval PUBLISH_FIRSTBOOT_SENTINEL_KVP_PUBLIC_HOST_KEY
printf 'KVP_PUBLISHED_PENDING_HOST_VERIFICATION\n' > "$STATUS"
trap - ERR
echo 'FIRSTBOOT_KVP_GUEST_READY: await independent Hyper-V verification'
