#!/usr/bin/env bash
set -euo pipefail
test "$(uname -m)" = aarch64
# Use currently maintained distribution repositories and their normal
# package authentication. No frozen Debian archives or signature bypass.
source /etc/os-release
echo "Build distribution: $PRETTY_NAME ($ID)"
case "$ID" in
  openeuler)
    header_root=/usr/src/kernels
    install_dependencies() {
      dnf --refresh --setopt=retries=2 --setopt=timeout=45 --setopt=gpgcheck=1 -y install \
        gcc gcc-c++ make binutils ca-certificates curl file kmod elfutils-libelf-devel \
        openssl-devel python3 bc tar gzip findutils git "$HEADERS"
    }
    ;;
  ubuntu)
    export DEBIAN_FRONTEND=noninteractive
    header_root=/usr/src
    apt_options=(-o Acquire::Retries=2 -o Acquire::http::Timeout=45 -o Acquire::https::Timeout=45 -o APT::Update::Error-Mode=any)
    install_dependencies() {
      apt-get "${apt_options[@]}" update &&
        apt-get "${apt_options[@]}" install -y --no-install-recommends \
          build-essential binutils ca-certificates curl file kmod libelf-dev libssl-dev \
          pkg-config python3 bc tar gzip git "$HEADERS"
    }
    ;;
  *) echo "Unsupported CI distribution: $ID" >&2; exit 1 ;;
esac
installed=false
for attempt in 1 2 3; do
  echo "::group::Install build dependencies (attempt $attempt/3)"
  if install_dependencies; then
    installed=true
    echo "::endgroup::"
    break
  fi
  echo "::endgroup::"
  if [[ "$attempt" -lt 3 ]]; then
    echo 'Dependency installation failed; refreshing repositories before retry.'
    sleep "$((attempt * 3))"
  fi
done
[[ "$installed" = true ]] || { echo 'Failed to install authenticated build dependencies after 3 attempts' >&2; exit 1; }
mapfile -t candidates < <(find "$header_root" -mindepth 1 -maxdepth 1 -type d -name "$HEADER_PATTERN" | sort -V)
test "${#candidates[@]}" -gt 0
kdir="${candidates[-1]}"
release="$(make -s -C "$kdir" ARCH=arm64 kernelrelease)"
case "$release" in "$KERNEL_PREFIX"*) ;; *) echo "Unexpected kernel: $release" >&2; exit 1;; esac
test -s "$kdir/Module.symvers" || { echo "Missing Module.symvers in $kdir" >&2; exit 1; }
echo "Kernel target: $release ($kdir)"
gcc --version
export KDIR="$kdir"
curl --retry 3 --retry-delay 2 --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs -o /tmp/rustup-init.sh
sh /tmp/rustup-init.sh -y --profile minimal --default-toolchain 1.90.0
export PATH="$HOME/.cargo/bin:$PATH"
rustup target add aarch64-unknown-none-softfloat
rustc --version
cargo test --locked --manifest-path src/rust/Cargo.toml --lib
bash scripts/arm64/build.sh
bash scripts/arm64/package.sh
