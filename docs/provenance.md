# Source provenance

## Upstream Git history

This fork retains the history of:

https://github.com/ASIXElectronics/asix-usb-nic-linux-driver

The import was based on upstream `main` commit `42feb1252fe0669845a8d6714bcc77bfc19eea1d`, whose driver reports 4.1.0. Vendor 4.2.0 was imported in a separate commit. The `vendor-4.2.0` tag marks that import before any downstream patches. All archive files match the vendor bytes; GitHub-only README and ignore rules were retained outside the archive file set.

## Vendor 4.2.0 archive

- Product/download page: https://www.asix.com.tw/en/product/USBEthernet/Super-Speed_USB_Ethernet/AX88179B
- Download URL: https://www.asix.com.tw/en/support/download/file/2151
- Filename: `ASIX_USB_NIC_Linux_Driver_Source_v4.2.0.tar.bz2`
- SHA-256: `dc8d89b1060ac2b0a4829d862f1cb39fbcb9fa5876746f8ff7b187567d237cfc`
- Website-listed release date when checked: 2026-10-13.

The download endpoint is mutable; verify the checksum rather than assuming it always serves the same archive. The Git tag preserves the exact imported file content independently of the endpoint.

## AUR prerequisite patch

- Package: https://aur.archlinux.org/packages/asix-ax88179-dkms
- AUR repository: https://aur.archlinux.org/asix-ax88179-dkms.git
- Packaging revision: `3f09dc929381bd70bf755dd97ecfa6ce59cf5e57`
- Patch: `0002-Complete-TX-NAPI-on-early-exit.patch`
- Original author: Maykel Moya <mmoya@mmoya.org>
- Original patch date: 2026-10-14.
- Original commit identified in the patch: `cb0d28afdfe39cffdfa43f2e3a2160a194f21d96`
- Patch SHA-256: `5ba79ac2d61ea9ece2ecb5c5219b109411d87e86b567b95511213de6571adf5d`

This fixes a separate early-exit path that leaves TX NAPI scheduled and can block `napi_disable()`. It is included in every baseline and candidate used in this investigation. Its original commit message and author were preserved when importing it here.

## Reset fixes and tested source identity

The reset changes modify `ax_main.c` and `ax88179a_772d.c`. The current sources are exactly those of local package **4.2.0-1.5**, installed on the physical host and reset-tested there on 2026-10-25:

- Combined recovery patch `packaging/arch/0003-reset-recovery.patch` (CRLF, `a/src/` paths, applied with `-p2` like the AUR patch), SHA-256 `0866dde7dcf8bd55868616dab79fea63823025a72f067f037a9196d8bbc11c4e`.
- Loaded module source version `56DFB0864FE0699E1CDFC5F`. A build of the same sources with LF line endings reports `B196B131DFCE128CB7DA2C0`; that LF build is the one used in the VM tests and the first host reset.
- All 16 source/header/Makefile inputs are listed in [source-sha256.json](source-sha256.json) and match the installed `/usr/src/asix-ax88179-4.2.0` byte for byte (`pacman -Qkk` reported no altered files).

Earlier local revisions, superseded and no longer in this history:

- **4.2.0-1.2**: first hardware-tested recovery (FW mode + `hw_init` + fresh link), source version `A697FD5CF5DF75390FAA018`, recovery patch SHA-256 `328b1c36b4cd95df03c6000eed6ecafa790d04c65b193f0f07ba8b6e48c90a9d`. It reset TX checksum offload to enabled after recovery.
- **4.2.0-1.3/1.4**: wording cleanup, then an 83-line helper replaying MAC, TX checksum, multicast hash and RX control after `hw_init`. Review found most of that replay unnecessary and its multicast snapshot racy; 1.5 replaced it with the smaller change described in [testing.md](testing.md).

Module binary hashes and build IDs can differ with build directory, compiler and build environment. No generated module, firmware image, private network configuration, SSH key or complete host diagnostic dump is included in the repository.
