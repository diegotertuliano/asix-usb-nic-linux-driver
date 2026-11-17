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

# Oversized-GSO TX wedge — 2026-11-17 (4.2.0-1.6)

## Cause

The spontaneous TX timeouts (2026-11-08, 11-10, 11-15) were not a hardware or USB fault. `ax88179a_772d.c` advertised `tso_max_size = tx_casecade_size` (23552), but `ax88179a_tx_fixup()` needs an 8-byte header per frame inside that buffer. The core software-segments GSO frames only when `skb->len >= gso_max_size` (`gso_within_dev_limits()` in `net/core/dev.c`), so frames of 23545–23551 bytes reached the driver whole. Even an empty buffer could not hold them, so the fixup requeued each one at the queue head, packed nothing, and repeated forever. Nothing behind it was sent, the netdev watchdog fired, and `ax_tx_timeout()` queued a USB reset. The reset leaves the software TX queue intact, so the same frame wedged TX again within seconds. Only recreating the netdev (re-enumeration, rmmod, reboot) cleared it. Such frames are rare: they come from GRO-aggregated forwarded TCP (Docker bridge, Tailscale) whose length lands in a 7-byte window.

The vendor source contains the correct value (`tx_casecade_size - AX88179A_TX_HEADER_SIZE`) behind `#if 0`.

## Fix (`0004-tx-oversize-frame.patch`)

- Advertise `tx_casecade_size - AX88179A_TX_HEADER_SIZE` (23544) for the 179A family.
- In both TX fixups, drop (rate-limited warning, `tx_dropped`) a frame that does not fit an empty buffer instead of requeueing it.
- Do not submit a zero-length TX URB when nothing was packed.
- Clamp the TX NAPI poll's return value to its budget (work counts GSO segments; seen as `returned 65, exceeding its budget of 64` on 2026-11-13).

## Test (physical host, Linux 7.3.3, `tools/test-gso-oversize.sh`)

`tools/gso-oversize-repro.py` injects a TCPv4 GSO frame of an exact length with AF_PACKET + `PACKET_VNET_HDR`, so it passes through the qdisc and `validate_xmit_skb()` like forwarded traffic.

| Driver | Frames | Outcome |
| --- | --- | --- |
| 4.2.0-1.5 (`D26A8FC63059B21D86A6E9A`) | one 23548-byte frame | Gateway ping 5/5 before, 0/5 15 s later. Then the 11-08 loop: TX timeout, USB reset, link up, timeout again within seconds (663 timeouts over 71 minutes; the test script hung on a blocked ping and the watchdog was stopped). `rmmod` cleared it. |
| 1.6 build (`8E42AAEE81B02B78A835410`, `insmod`) | 3 each of 23543, 23544, 23545, 23548, 23551, 23552, 23600 bytes | `tso_max_size`/`gso_max_size` 23544. No TX timeout, `tx_dropped` 0, gateway ping 5/5 after. Everything at or above the limit was segmented by the core, so the driver's drop path was not exercised. |
