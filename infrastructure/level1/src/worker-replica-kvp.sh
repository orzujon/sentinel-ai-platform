#!/usr/bin/env bash
# Disposable worker-only KVP package gate: plan is read-only, apply needs host approval.
set -euo pipefail
mode="${1:-}"
if [[ "$mode" != plan && "$mode" != apply && "$mode" != validate-simulation ]]; then
  echo 'BLOCKED: mode must be plan, apply or validate-simulation' >&2; exit 2
fi

validate_simulation() {
  awk '
    BEGIN {
      expected["linux-cloud-tools-common"]="7.0.0-42.42"
      expected["bpftool"]="7.7.0+7.0.0-42.42"
      expected["linux-libc-dev"]="7.0.0-42.42"
      expected["linux-perf"]="7.0.0-42.42"
      expected["linux-tools-common"]="7.0.0-42.42"
    }
    $1=="Rem" || $1=="Purg" {
      print "BLOCKED: package removal " $0 > "/dev/stderr"; bad=1
    }
    $1=="Inst" || $1=="Conf" {
      pkg=$2
      if (!(pkg in expected)) {
        print "BLOCKED: unexpected package " $0 > "/dev/stderr"; bad=1; next
      }
      n=split($0, parts, "(")
      if (n<2) {
        print "BLOCKED: version missing " $0 > "/dev/stderr"; bad=1; next
      }
      split(parts[2], fields, " ")
      if (fields[1]!=expected[pkg]) {
        print "BLOCKED: version mismatch " $0 > "/dev/stderr"; bad=1
      }
      if ($1=="Inst") {
        install[pkg]++
        installs++
      } else {
        configure[pkg]++
        configs++
      }
    }
    END {
      if (installs!=5 || configs!=5) {
        print "BLOCKED: expected exactly five Inst and five Conf rows" > "/dev/stderr"; bad=1
      }
      for (pkg in expected) {
        if (install[pkg]!=1 || configure[pkg]!=1) {
          print "BLOCKED: missing or duplicate approved package " pkg > "/dev/stderr"; bad=1
        }
      }
      if (bad) exit 2
      print "KVP_SIMULATION_PASS: exactly five approved package changes; no removals"
    }
  '
}

if [[ "$mode" == validate-simulation ]]; then
  validate_simulation
  exit 0
fi

if [[ "$(hostname)" != sentinel-e2e-w02 ]] ||
   ! grep -Eq '^VERSION_ID="?26\.04"?$' /etc/os-release; then
  echo 'BLOCKED: unexpected Ubuntu 26.04 disposable worker identity' >&2; exit 2
fi
if ! cloud-init status --long | grep -Eq '^status: done$'; then
  echo 'BLOCKED: cloud-init not done' >&2; exit 2
fi
for marker in /etc/kubernetes/admin.conf /etc/kubernetes/kubelet.conf \
              /etc/kubernetes/bootstrap-kubelet.conf /var/lib/kubelet/config.yaml; do
  if [[ -e "$marker" ]]; then
    echo "BLOCKED: Kubernetes marker $marker" >&2; exit 2
  fi
done

packages=(
  'linux-cloud-tools-common=7.0.0-42.42'
  'bpftool=7.7.0+7.0.0-42.42'
  'linux-libc-dev=7.0.0-42.42'
  'linux-perf=7.0.0-42.42'
  'linux-tools-common=7.0.0-42.42'
)
for pin in "${packages[@]}"; do
  pkg="${pin%%=*}"
  version="${pin#*=}"
  candidate="$(apt-cache policy "$pkg" | awk '$1=="Candidate:" {print $2}')"
  if [[ "$candidate" != "$version" ]]; then
    echo "BLOCKED: $pkg candidate $candidate != $version" >&2; exit 2
  fi
done
if dpkg-query -W -f='${Status}' linux-cloud-tools-common 2>/dev/null | grep -q 'install ok installed'; then
  echo 'BLOCKED: package already installed; inspect before retry' >&2; exit 2
fi
if ! getent ahostsv4 archive.ubuntu.com >/dev/null; then
  echo 'BLOCKED: DNS not ready' >&2; exit 2
fi

echo '=== SIMULATING EXACT PACKAGE TRANSACTION ==='
simulation="$(apt-get -s install --no-install-recommends "${packages[@]}")"
printf '%s\n' "$simulation"
validate_simulation <<< "$simulation"

if [[ "$mode" == plan ]]; then
  echo 'KVP_REPLICA_PLAN_READY: no package or service changes'
  exit 0
fi
if [[ "$EUID" -ne 0 ]]; then
  echo 'BLOCKED: apply requires sudo' >&2; exit 2
fi
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends --no-remove "${packages[@]}"
installed="$(dpkg-query -W -f='${Version}' linux-cloud-tools-common)"
if [[ "$installed" != '7.0.0-42.42' ]]; then
  echo "BLOCKED: unexpected KVP version $installed" >&2; exit 2
fi
# The VMBus device was enumerated at first boot before the udev rule existed.
# Reload and replay only this KVP device event. Never retrigger all devices.
device='/sys/devices/virtual/misc/vmbus!hv_kvp'
rule='/usr/lib/udev/rules.d/60-hv-kvp-daemon.rules'
unit='sys-devices-virtual-misc-vmbus\x21hv_kvp.device'
if [[ ! -e "$device" || ! -c /dev/vmbus/hv_kvp || ! -f "$rule" ]]; then
  echo 'BLOCKED: required KVP device, char node or package udev rule absent' >&2; exit 2
fi
if ! grep -Fq 'TAG+="systemd"' "$rule" ||
   ! grep -Fq 'SYSTEMD_WANTS' "$rule"; then
  echo 'BLOCKED: unexpected packaged KVP udev rule' >&2; exit 2
fi
echo '=== REPLAYING ONLY LATE-INSTALLED KVP UDEV RULE ==='
udevadm trigger --dry-run --action=add --verbose "$device"
udevadm control --reload
udevadm trigger --action=add "$device"
udevadm settle --timeout=20
if ! udevadm info --query=property --path="$device" | grep -Eq '^TAGS=.*:systemd:'; then
  echo 'BLOCKED: KVP device missing systemd udev tag after retrigger' >&2; exit 2
fi
if [[ "$(systemctl show "$unit" -p ActiveState --value)" != active ]]; then
  echo 'BLOCKED: systemd did not activate exact KVP VMBus device unit' >&2; exit 2
fi
systemctl enable --now hv-kvp-daemon.service
systemctl is-active --quiet hv-kvp-daemon.service
echo 'KVP_GUEST_DAEMON_ACTIVE_HOST_UNVERIFIED: verify Hyper-V integration independently'
