#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
release="$(modinfo -F vermagic ./mt7603u.ko | cut -d ' ' -f1)"
[[ "$release" =~ ^[A-Za-z0-9._+-]+$ ]]
label="${BUILD_LABEL:-local}"
[[ "$label" =~ ^[A-Za-z0-9._+-]+$ ]]
name="mt7603u-arm64-$label-$release"
mkdir -p dist
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
mkdir "$stage/$name"
p="$stage/$name"
install -m 0644 mt7603u.ko "$p/"
for f in check.sh install.sh uninstall.sh; do install -m 0755 "scripts/arm64/$f" "$p/"; done
install -m 0644 scripts/arm64/README.md "$p/"
printf '%s\n' "$release" > "$p/KERNEL_RELEASE"
modinfo -F vermagic ./mt7603u.ko > "$p/VERMAGIC"
# Vendor firmware is not packaged because its independent redistribution terms
# are not documented in the upstream project. Provide its exact reference hash.
sha256sum harness/fixtures/mt7603u_e2.bin | cut -d ' ' -f1 > "$p/FIRMWARE_SHA256"
{
  printf 'source_commit=%s\n' "${SOURCE_COMMIT:-$(git rev-parse HEAD)}"
  printf 'kernel_release=%s\n' "$release"
  printf 'architecture=aarch64\n'
  rustc --version
  gcc --version | head -n 1
  ld --version | head -n 1
  modinfo ./mt7603u.ko
} > "$p/BUILD_INFO"
(cd "$p"; sha256sum mt7603u.ko KERNEL_RELEASE VERMAGIC FIRMWARE_SHA256 BUILD_INFO README.md check.sh install.sh uninstall.sh > SHA256SUMS)
tar -C "$stage" -czf "dist/$name.tar.gz" "$name"
(cd dist; sha256sum "$name.tar.gz" > "$name.tar.gz.sha256")
