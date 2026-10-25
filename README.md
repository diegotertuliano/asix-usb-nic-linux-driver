# ASIX USB Ethernet 4.2.0 with reset recovery fixes

Unofficial fork of the [ASIX Linux driver](https://github.com/ASIXElectronics/asix-usb-nic-linux-driver), based on the vendor's **4.2.0** source release. It adds the AUR TX-NAPI fix and USB reset recovery changes tested with an **AX88179B** on **Linux 6.6.156-2-MANJARO**.

Before these changes, a USB reset (for example the one queued after a TX timeout) hit a kernel BUG in `napi_enable()` from `ax_post_reset()` and Ethernet stayed down until reboot. With them, the adapter recovers in place in about four seconds, keeping its configured MAC, checksum offload and multicast settings. This does not identify the trigger of the original spontaneous TX timeout. See [test results and limitations](docs/testing.md).

## Changes

Each change has a separate commit on `main`:

1. Import untouched vendor 4.2.0 files, tagged `vendor-4.2.0`.
2. Apply Maykel Moya's AUR patch to complete TX NAPI on early exit.
3. Remove the duplicate TX NAPI enable (tasklet: extra disable) in `ax_post_reset()`.
4. Drain outstanding bulk RX/TX transfers in `ax_pre_reset()`, as the USB reset API requires.
5. Program TX checksum offload from the configured netdev features in `ax88179a_hw_init()` instead of always enabling it. This also fixes `ethtool -K tx off` being undone by ifdown/ifup or resume.
6. For `AX_VERSION_AX88179A_772D`, restore firmware mode and run `hw_init` after reset, force a fresh link event, and replay the receive mode. On failure, return an error so the USB core re-probes the interface.

Other device families get changes 3–4 only; their hardware is not reinitialized after reset. Alternate build options (tasklets, PTP, queue priority) compile but were not tested on hardware. This fork is not an official ASIX release.

[Source provenance and patch credits](docs/provenance.md) document the archive checksum and AUR revision. The vendor's [Readme](Readme) remains unchanged.

## Build the module

Install a C toolchain and kernel headers matching the target kernel. From the repository root:

```sh
make -C /lib/modules/"$(uname -r)"/build M="$PWD" modules
modinfo ./ax_usb_nic.ko
```

This builds only the module, without installing or loading it. The original `make` target also builds the vendor's programming utilities, which these fixes do not need.

## Arch / Manjaro DKMS package

[packaging/arch](packaging/arch) contains local package version **4.2.0-1.5**, the build installed and reset-tested on the physical host. It downloads the checksum-verified vendor archive and applies the AUR patch plus `0003-reset-recovery.patch` (changes 3–6), producing the same driver sources as this checkout byte for byte.

With `base-devel`, `dkms` and matching kernel headers installed:

```sh
cd packaging/arch
makepkg --cleanbuild
sudo pacman -U ./asix-ax88179-dkms-4.2.0-1.5-any.pkg.tar.zst
```

Installing the package rebuilds the DKMS module; it does not replace an already loaded module. The recipe uses the same package name as AUR `asix-ax88179-dkms`, so a later AUR upgrade can replace these local patches. Review its changes before upgrading.

The tests kept USB autosuspend disabled for the adapter. That power policy is external to the driver and is not installed by this package.

## License

Original source notices are retained. The files contain GPL notices, including GPL version 2 or later language; see the individual file headers and [COPYING](COPYING). Original driver copyright belongs to ASIX Electronics Corporation and the other credited authors. The AUR patch retains Maykel Moya's authorship in Git history.
