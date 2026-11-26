#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "ARM64 packaging failed at line $LINENO: $BASH_COMMAND" >&2' ERR
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
  if [[ -n "${KDIR:-}" ]]; then
    printf 'kernel_headers_package_version=%s\n' "${KERNEL_HEADERS_PACKAGE_VERSION:-unknown}"
    printf 'kernel_module_symvers_sha256='
    sha256sum "$KDIR/Module.symvers" | cut -d ' ' -f1
    if [[ -f "$KDIR/include/config/auto.conf" ]]; then
      printf 'kernel_auto_conf_sha256='
      sha256sum "$KDIR/include/config/auto.conf" | cut -d ' ' -f1
      grep '^CONFIG_CC_VERSION_TEXT=' "$KDIR/include/config/auto.conf" || true
    fi
  fi
  rustc --version
  gcc --version | sed -n '1p'
  ld --version | sed -n '1p'
  modinfo ./mt7603u.ko
} > "$p/BUILD_INFO"
(cd "$p"; sha256sum mt7603u.ko KERNEL_RELEASE VERMAGIC FIRMWARE_SHA256 BUILD_INFO README.md check.sh install.sh uninstall.sh > SHA256SUMS)
tar -C "$stage" -czf "dist/$name.tar.gz" "$name"
(cd dist; sha256sum "$name.tar.gz" > "$name.tar.gz.sha256")
