# Reset recovery testing — 2026-10-25

## Environment and scope

- AX88179B USB Ethernet adapter, USB ID `0b95:1790`, `bcdDevice=0x0200`, firmware `v1.3.0.3`; Ethernet 1 Gbps/full duplex, USB SuperSpeed.
- Linux `6.6.156-2-MANJARO`, x86_64; GCC 16.2.1 20260810.
- VM: Debian 13 guest under QEMU 11.1.1/KVM, same kernel as the host, physical USB passthrough. Guest management used virtual networking; test traffic used the passed-through adapter, crossing the physical LAN to the host's Wi-Fi address.
- Physical host: the same machine without a VM, using the host kernel and USB controller directly.
- USB autosuspend was disabled for the adapter. This setting is outside the patch.

Every result below is a single controlled reset, not a stress loop or long-term stability measurement. The trigger of the original spontaneous TX timeout remains unknown.

## Baseline and first recovery candidate

| Variant | Test | Outcome |
| --- | --- | --- |
| Vendor 4.2.0 + AUR early-exit patch | VM | Active RX URB resubmission warning, then `napi_enable` BUG at `net/core/dev.c:6618`; no recovery. |
| + duplicate-enable deletion | VM (different power/diagnostic settings) | No NAPI BUG, but active-URB warning and guest adapter loss. |
| + RX/TX URB drain | VM | No BUG/warning; adapter stayed enumerated, but ping/TCP failed for about 116 seconds. |
| + FW mode, `hw_init`, fresh link (4.2.0-1.2) | VM, then physical host | Recovered in about four seconds; 1 MiB TCP upload/echo passed at 15 and 90 seconds; host ping 95/99. TX checksum offload was silently re-enabled by `hw_init`. |

## Review variants (VM, one reset each)

Each started from vendor 4.2.0 + AUR patch with a custom MAC (`02:0b:95:17:90:42`), IPv4/IPv6 TX checksum offload disabled, and a multicast group joined. Every checkpoint read the MAC registers live (`ethtool -d`, one control transfer per byte), then ran five bound pings, a byte-verified 1 MiB TCP upload/echo, and multicast delivery checked against the physical interface index.

| Variant | Change after reset | Outcome |
| --- | --- | --- |
| C | drain + duplicate fix + `carrier_off` only | No link event; traffic failed at 15 and 45 seconds. MAC, TX checksum, multicast hash and RX control registers unchanged. |
| D | C + firmware-mode write | Same as C. |
| A | current change + explicit MAC write | Pass at 15/90 s, recovered in place. |
| **A2** | **current change** (no MAC write) | **Pass at 15/90 s, recovered in place** (no re-probe or rename). All registers equal to pre-reset; re-enabling TX checksum afterwards gave `0x67` with traffic passing. |
| F | A + debug-only forced `post_reset` failure | USB core unbound and re-probed the interface; link up about four seconds later, traffic passed, no hung task after 130 seconds. Settings returned to factory defaults, as expected for a re-probe. |

Conclusions for this adapter: a USB port reset keeps the MAC-side configuration registers, but no link event arrives without `hw_init`. Firmware mode alone is not enough. `hw_init`'s unconditional TX checksum write was the only user setting it clobbered, which is why that write now follows the netdev features. The receive-mode replay covers rx-mode changes dropped while the device was disabled during reset.

## Physical host

| Build | Event (local time, UTC−3) | Outcome |
| --- | --- | --- |
| A2 module loaded with `insmod` | reset 19:26:23 | Link back at 1 Gbps at 19:26:27, in place. At 15 and 90 seconds: 5/5 gateway pings, gateway HTTP 200, 10 MB HTTPS download over Ethernet at 44–65 MB/s. No BUG, warning, watchdog or hung task through 110 seconds. The continuous ping logger exited early, so no loss figure. |
| Installed package 4.2.0-1.5 | reboot 19:32 | Driver loaded from DKMS; link at 1 Gbps with Ethernet as the default route. |
| Installed package 4.2.0-1.5 | reset 19:35:30 | Link back at 19:35:34, in place. 2 of 200 half-second gateway probes lost (both within the first 3 seconds); 15/90-second checks as above; kernel log clean. |

## What these tests do not establish

Other chips (AX88772D shares the reset path but was not tested), other kernels, tasklet/PTP/queue-priority builds, autosuspend-enabled operation, suspend/resume, MTU/pause/EEE settings, VLAN traffic, and concurrent configuration changes during a reset were not covered on hardware. Changing the interface's up/down state while a reset is in progress can still unbalance NAPI. That is a pre-existing limitation, not introduced by these changes. These resets do not prove that spontaneous TX timeouts can no longer occur.
