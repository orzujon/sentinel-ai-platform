#!/usr/bin/env bash
# Runs inside the Ubuntu-26.04 WSL distro. Called by Sentinel Stage 3.
set -euo pipefail
mode="${1:?mode}"; shift
case "$mode" in
  check)
    command -v qemu-img >/dev/null || { echo 'MISSING: qemu-img (install qemu-utils in Ubuntu WSL)' >&2; exit 3; }
    command -v cloud-localds >/dev/null || { echo 'MISSING: cloud-localds (install cloud-image-utils in Ubuntu WSL)' >&2; exit 3; }
    ;;
  disk)
    src="${1:?src .img}"; target="${2:?dest .vhdx}"
    [[ -f "$src" && ! -e "$target" ]] || { echo 'Source missing or destination exists' >&2; exit 4; }
    qemu-img info -f qcow2 "$src" >/dev/null
    qemu-img convert -p -f qcow2 -O vhdx -o subformat=dynamic "$src" "$target"
    qemu-img info -f vhdx "$target" >/dev/null
    ;;
  seed)
    user_data="${1:?user-data}"; meta_data="${2:?meta-data}"; network_config="${3:?network-config}"; iso="${4:?seed.iso}"
    [[ -f "$user_data" && -f "$meta_data" && -f "$network_config" && ! -e "$iso" ]] || { echo 'Missing seed input or destination already exists' >&2; exit 5; }
    cloud-localds --network-config="$network_config" "$iso" "$user_data" "$meta_data"
    [[ -s "$iso" ]] || { echo 'Seed ISO empty' >&2; exit 6; }
    ;;
  *) echo "Unsupported mode: $mode" >&2; exit 2;;
esac
