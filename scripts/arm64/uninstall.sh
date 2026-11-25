#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
test "$(id -u)" -eq 0
bash check.sh
dest="/lib/modules/$(uname -r)/updates/mt7603u.ko"
if [[ ! -e "$dest" && ! -L "$dest" ]]; then echo 'Package module not installed.'; exit 0; fi
[[ -f "$dest" && ! -L "$dest" ]] && cmp -s mt7603u.ko "$dest" || { echo 'Installed module differs; refusing to remove.' >&2; exit 1; }
if [[ -d /sys/module/mt7603u ]]; then modprobe -r mt7603u; fi
rm -- "$dest"
depmod -a
echo 'Removed this module; firmware retained to avoid deleting a shared file.'
