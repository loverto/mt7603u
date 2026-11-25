#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
test "$(uname -m)" = aarch64
apt-get update
apt-get install -y --no-install-recommends \
  build-essential binutils ca-certificates curl file kmod libelf-dev pkg-config \
  python3 bc "$HEADERS"
curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs -o /tmp/rustup-init.sh
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
