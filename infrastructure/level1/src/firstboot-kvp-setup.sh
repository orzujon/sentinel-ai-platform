#!/usr/bin/env bash
set -euo pipefail
umask 077
export DEBIAN_FRONTEND=noninteractive
STATUS=/var/lib/sentinel/firstboot-kvp.status
install -d -m 0700 /var/lib/sentinel
mark_failed() {
  local failed_line="${1:-unknown}"
  local failed_rc="${2:-1}"
  printf 'BLOCKED\n' > "$STATUS"
  printf 'FIRSTBOOT_KVP_BLOCKED: line=%s rc=%s; use guest console, never TOFU SSH\n' "$failed_line" "$failed_rc" >&2
}
trap 'mark_failed "$LINENO" "$?"' ERR
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
# DNS failures must be reported explicitly; cloud-init's openssh package stage
# might already have succeeded, but that does not prove DNS still works.
if ! getent ahostsv4 archive.ubuntu.com >/dev/null; then
  echo 'BLOCKED: guest DNS cannot resolve archive.ubuntu.com before KVP APT' >&2
  exit 2
fi
echo 'FIRSTBOOT_KVP_DNS_PASS: archive.ubuntu.com'
apt-get update -o APT::Update::Error-Mode=any -o Acquire::Retries=1 -o Acquire::http::Timeout=20
packages=(linux-cloud-tools-common "linux-cloud-tools-${generic_base}" "linux-cloud-tools-${kernel}")
for package in "${packages[@]}"; do
  # Do not exit awk early under pipefail: apt-cache may receive SIGPIPE
  # and abort cloud-init despite supplying a valid Candidate.
  policy="$(apt-cache policy "$package")"
  candidate="$(printf '%s\n' "$policy" | awk '$1=="Candidate:" {print $2}')"
  echo "FIRSTBOOT_KVP_CANDIDATE: $package=$candidate"
  [[ -n "$candidate" && "$candidate" != "(none)" ]] ||
    { echo "BLOCKED: missing signed Ubuntu package candidate for $package" >&2; exit 2; }
done
echo 'FIRSTBOOT_KVP_PACKAGE_CANDIDATES_PASS: starting guarded signed APT installation'
apt-get install -y --no-install-recommends --no-remove "${packages[@]}"
echo 'FIRSTBOOT_KVP_PACKAGES_INSTALLED: verifying targeted udev activation'
# Previous Stage 5.3 live acceptance required replaying the specific KVP
# udev add event: the VMBus device appeared before the package rule existed.
# Never retrigger other devices and never bypass the host-side KVP attestation.
device='/sys/devices/virtual/misc/vmbus!hv_kvp'
rule='/usr/lib/udev/rules.d/60-hv-kvp-daemon.rules'
unit='sys-devices-virtual-misc-vmbus\x21hv_kvp.device'
[[ -e "$device" && -c /dev/vmbus/hv_kvp && -f "$rule" ]] ||
  { echo 'BLOCKED: KVP device or packaged udev rule absent' >&2; exit 2; }
grep -Fq 'TAG+="systemd"' "$rule" && grep -Fq 'SYSTEMD_WANTS' "$rule" ||
  { echo 'BLOCKED: unexpected KVP udev rule' >&2; exit 2; }
udevadm trigger --dry-run --action=add --verbose "$device"
udevadm control --reload
udevadm trigger --action=add "$device"
udevadm settle --timeout=20
udevadm info --query=property --path="$device" | grep -Eq '^TAGS=.*:systemd:' ||
  { echo 'BLOCKED: KVP udev systemd tag absent' >&2; exit 2; }
[[ "$(systemctl show "$unit" -p ActiveState --value)" == active ]] ||
  { echo 'BLOCKED: KVP device unit inactive' >&2; exit 2; }
systemctl enable --now hv-kvp-daemon.service
systemctl is-active --quiet hv-kvp-daemon.service
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
