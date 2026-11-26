#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
test "$(uname -m)" = aarch64
# Debian 11 reached EOL on 2026-08-31. The live security index may
# still refer to removed packages. Use a dated official archive snapshot
# for this historical build-only environment; keep APT signature and
# package hash verification enabled. Only its fixed metadata expiry is waived.
apt_options=(-o Acquire::Retries=2 -o Acquire::http::Timeout=45 -o Acquire::https::Timeout=45 -o APT::Update::Error-Mode=any)
if [[ "$BUILD_LABEL" = debian11-5.10 ]]; then
  snapshot=20260831T230000Z
  cat > /tmp/mt7603u-bullseye.list <<EOF
deb [check-valid-until=no signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] http://snapshot.debian.org/archive/debian/$snapshot/ bullseye main
deb [check-valid-until=no signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] http://snapshot.debian.org/archive/debian-security/$snapshot/ bullseye-security main
EOF
  apt_options+=(-o Dir::Etc::sourcelist=/tmp/mt7603u-bullseye.list -o Dir::Etc::sourceparts=-)
fi
installed=false
for attempt in 1 2 3; do
  echo "::group::Install build dependencies (attempt $attempt/3)"
  if apt-get "${apt_options[@]}" update && apt-get "${apt_options[@]}" install -y --no-install-recommends \
    build-essential binutils ca-certificates curl file kmod libelf-dev pkg-config \
    python3 bc "$HEADERS"; then
    installed=true
    echo "::endgroup::"
    break
  fi
  echo "::endgroup::"
  if [[ "$attempt" -lt 3 ]]; then
    echo "Dependency download failed; refreshing package indexes before retry"
    apt-get clean
    sleep "$((attempt * 3))"
  fi
done
[[ "$installed" = true ]] || { echo 'Failed to install authenticated build dependencies after 3 attempts' >&2; exit 1; }
curl --retry 3 --retry-delay 2 --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs -o /tmp/rustup-init.sh
sh /tmp/rustup-init.sh -y --profile minimal --default-toolchain 1.90.0
export PATH="$HOME/.cargo/bin:$PATH"
rustup target add aarch64-unknown-none-softfloat
mapfile -t candidates < <(find /usr/src -maxdepth 1 -type d -name "$HEADER_PATTERN" | sort -V)
test "${#candidates[@]}" -gt 0
kdir="${candidates[-1]}"
release="$(make -s -C "$kdir" ARCH=arm64 kernelrelease)"
case "$release" in "$KERNEL_PREFIX"*) ;; *) echo "Unexpected kernel: $release" >&2; exit 1;; esac
export KDIR="$kdir"
cargo test --locked --manifest-path src/rust/Cargo.toml --lib
bash scripts/arm64/build.sh
bash scripts/arm64/package.sh
