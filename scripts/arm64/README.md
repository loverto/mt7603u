# MT7603U ARM64 build candidates

This fork adds a native ARM64 build path for the C + Rust MT7603U driver.
The existing x86_64 build is unchanged. Device IDs: 0e8d:760c and 0e8d:7603.
Upstream declares GPLv2 for the driver in its README; the source commit is recorded
in BUILD_INFO. This is a compile-tested candidate, NOT a hardware-tested or
Kylin-certified driver. Do not install it on restricted systems without approval.

## Installation on an authorized test machine

1. Verify the archive checksum and extract it.
2. Run `bash check.sh` to check the exact kernel release, architecture and hashes.
3. Obtain the reference firmware from an authorized source. The upstream project
   uses `harness/fixtures/mt7603u_e2.bin`; its expected SHA-256 is in
   FIRMWARE_SHA256. The vendor firmware is not redistributed in this package
   because separate distribution terms have not been established.
4. Run `sudo bash install.sh /absolute/path/to/mt7603u_e2.bin`.
5. If approved, load via `sudo modprobe mt7603u`; check `iw dev` and system logs.
6. Remove with `sudo bash uninstall.sh`; shared firmware is retained.

## CI environment

The workflow uses native ARM64 GitHub-hosted Ubuntu runners, with openEuler
22.03 LTS SP4 and Ubuntu 24.04 containers for their respective kernel development
trees. The openEuler build is pinned to the original SP4 kernel-devel RPM
5.10.0-216.0.0.115.oe2203sp4.aarch64, using only signed release repositories
OS and everything, not the moving update repository. This is a historical
ABI build target, not a recommendation to deploy that OS or kernel.
The runner's own kernel release is not the target. Both builds are independent.
When one build fails, successfully checked artifacts may still be published as
an explicitly partial prerelease; the workflow remains failed until both pass.

## Kylin-specific builds

Generic openEuler 22.03 LTS SP4 (5.10) and Ubuntu 24.04 (6.8) modules are not universal ARM64 modules. Even
identical release strings do not guarantee matching ABI, config, symbol CRCs
or signature policy. For a Kylin-specific build use its exact prepared ARM64
kernel headers/build tree, including Module.symvers, and the matching compiler.
For the 5.4.18-53-generic target, the separate Kylin ARM64 workflow obtains
paired header packages from the vendor's signed APT index, using the vendor's
HTTPS keyring package as the bootstrap trust anchor. For an independently
verified keyring package, set the repository variable KYLIN_KEYRING_SHA256.
It never uses trusted=yes or substitutes the Ubuntu headers. If the official
archive is unavailable, the exact build fails and must not publish a Kylin
candidate. The parallel Ubuntu 5.4 API regression artifact is not a Kylin driver.

For an authorized ARM64 build host with the exact vendor headers installed,
install Rust 1.90.0 with aarch64-unknown-none-softfloat and the matching compiler:

    KDIR=/path/to/exact/kernel/build bash scripts/arm64/build-kylin.sh

The diagnostic output includes the header release and compiler information;
BUILD_INFO records the symbol-version and configuration hashes. Match the
installed kernel package revision as well as uname -r. Vendor header packages
and internal diagnostic logs are never uploaded by this workflow.

No automatic MOK enrollment, signature bypass, USB-policy modification or
network configuration changes are performed. Physical hardware operation,
suspend/resume and stability require separate validation.
