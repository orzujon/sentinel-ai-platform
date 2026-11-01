#!/usr/bin/env bash
# Stage 5.3 KVP recovery on the EXACT disposable worker already running 7.0.0-38.
# PLAN is read-only; APPLY installs ONLY two kernel-ABI-matched Ubuntu packages.
set -euo pipefail
mode="${1:-}"
case "$mode" in
  plan|apply|validate-simulation) ;;
  *) echo 'BLOCKED: expected plan, apply or validate-simulation' >&2; exit 2 ;;
esac

validate_simulation() {
  awk '
    BEGIN {
      expected["linux-cloud-tools-7.0.0-38"]="7.0.0-38.38"
      expected["linux-cloud-tools-7.0.0-38-generic"]="7.0.0-38.38"
    }
    $1=="Rem" || $1=="Purg" {
      print "BLOCKED: removal in APT simulation: " $0 > "/dev/stderr"; fail=1
    }
    $1=="Inst" || $1=="Conf" {
      pkg=$2
      if (!(pkg in expected)) {
        print "BLOCKED: additional package change: " $0 > "/dev/stderr"; fail=1; next
      }
      n=split($0, parts, "(")
      if (n<2) {
        print "BLOCKED: missing version in " $0 > "/dev/stderr"; fail=1; next
      }
      split(parts[2], fields, " ")
      if (fields[1]!=expected[pkg]) {
        print "BLOCKED: package version drift " $0 > "/dev/stderr"; fail=1
      }
      if ($1=="Inst") {
        installs[pkg]++; ni++
      } else {
        configs[pkg]++; nc++
      }
    }
    END {
      if (ni!=2 || nc!=2) {
        print "BLOCKED: require exactly two Inst and two Conf rows" > "/dev/stderr"; fail=1
      }
      for (pkg in expected) {
        if (installs[pkg]!=1 || configs[pkg]!=1) {
          print "BLOCKED: missing or repeated package: " pkg > "/dev/stderr"; fail=1
        }
      }
      if (fail) exit 2
      print "KVP_KERNEL_SIMULATION_PASS: two kernel-specific packages only; no removals"
    }
  '
}

if [[ "$mode" == validate-simulation ]]; then
  validate_simulation
  exit 0
fi

[[ "$(hostname)" == "sentinel-e2e-w02" ]] || {
  echo 'BLOCKED: unexpected VM hostname' >&2; exit 2;
}
[[ "$(uname -r)" == "7.0.0-38-generic" ]] || {
  echo 'BLOCKED: running kernel changed; do not install mismatched tools' >&2; exit 2;
}
grep -Eq '^ID=ubuntu$' /etc/os-release &&
grep -Eq '^VERSION_ID="?26\.04"?$' /etc/os-release || {
  echo 'BLOCKED: Ubuntu 26.04 required' >&2; exit 2;
}
systemd-detect-virt | grep -qx 'microsoft' || {
  echo 'BLOCKED: hypervisor is not Microsoft' >&2; exit 2;
}
cloud-init status --long | grep -Eq '^status: done$' || {
  echo 'BLOCKED: cloud-init not done' >&2; exit 2;
}
for marker in /etc/kubernetes/admin.conf /etc/kubernetes/kubelet.conf \
              /etc/kubernetes/bootstrap-kubelet.conf /var/lib/kubelet/config.yaml; do
  if [[ -e "$marker" ]]; then
    echo "BLOCKED: Kubernetes state at $marker" >&2; exit 2
  fi
done
common_version="$(dpkg-query -W -f='${Version}' linux-cloud-tools-common)"
[[ "$common_version" == '7.0.0-42.42' ]] || {
  echo "BLOCKED: original installed common package drift: $common_version" >&2; exit 2;
}
for pkg in linux-cloud-tools-7.0.0-38 linux-cloud-tools-7.0.0-38-generic; do
  if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed'; then
    echo "BLOCKED: $pkg already installed; inspect state before recovery" >&2; exit 2
  fi
done

device='/sys/devices/virtual/misc/vmbus!hv_kvp'
unit='sys-devices-virtual-misc-vmbus\x21hv_kvp.device'
if [[ ! -c /dev/vmbus/hv_kvp || ! -e "$device" ]] ||
   [[ "$(systemctl show "$unit" -p ActiveState --value)" != active ]]; then
  echo 'BLOCKED: KVP VMBus systemd device is not active' >&2; exit 2
fi
if ! udevadm info --query=property --path="$device" | grep -Eq '^TAGS=.*:systemd:'; then
  echo 'BLOCKED: KVP device lacks systemd tag' >&2; exit 2
fi
if ! getent ahostsv4 archive.ubuntu.com >/dev/null; then
  echo 'BLOCKED: Ubuntu package DNS resolution failed' >&2; exit 2
fi

packages=(
  'linux-cloud-tools-7.0.0-38=7.0.0-38.38'
  'linux-cloud-tools-7.0.0-38-generic=7.0.0-38.38'
)
for pin in "${packages[@]}"; do
  pkg="${pin%%=*}"
  version="${pin#*=}"
  candidate="$(apt-cache policy "$pkg" | awk '$1=="Candidate:" {print $2}')"
  if [[ "$candidate" != "$version" ]]; then
    echo "BLOCKED: $pkg candidate $candidate differs from $version" >&2; exit 2
  fi
done

echo '=== READ-ONLY APT SIMULATION FOR RUNNING KERNEL 7.0.0-38 ==='
simulation="$(apt-get -s install --no-install-recommends --no-remove "${packages[@]}")"
printf '%s\n' "$simulation"
validate_simulation <<< "$simulation"

if [[ "$mode" == plan ]]; then
  echo 'KVP_KERNEL_PLAN_READY: no package, kernel or service changes'
  exit 0
fi

if [[ "$EUID" -ne 0 ]]; then
  echo 'BLOCKED: apply requires sudo/root' >&2; exit 2
fi

echo '=== INSTALL ONLY TWO PINNED KERNEL-SPECIFIC PACKAGES ==='
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends --no-remove "${packages[@]}"
for pin in "${packages[@]}"; do
  pkg="${pin%%=*}"
  version="${pin#*=}"
  installed="$(dpkg-query -W -f='${Version}' "$pkg")"
  if [[ "$installed" != "$version" ]]; then
    echo "BLOCKED: post-install version mismatch for $pkg" >&2; exit 2
  fi
done
# The kernel version remains unchanged. Reset only the failed KVP service state.
systemctl reset-failed hv-kvp-daemon.service
systemctl restart hv-kvp-daemon.service
sleep 3
systemctl is-active --quiet hv-kvp-daemon.service || {
  journalctl -u hv-kvp-daemon.service -n 20 --no-pager
  echo 'BLOCKED: KVP service did not remain active' >&2; exit 2
}
main_pid="$(systemctl show hv-kvp-daemon.service -p MainPID --value)"
if [[ ! "$main_pid" =~ ^[1-9][0-9]*$ ]] || ! kill -0 "$main_pid"; then
  echo 'BLOCKED: no persistent KVP daemon process' >&2; exit 2
fi
echo "KVP_GUEST_DAEMON_STABLE_HOST_UNVERIFIED: pid=$main_pid kernel=$(uname -r)"
