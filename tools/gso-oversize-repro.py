#!/usr/bin/env python3
"""Send one GSO TCPv4 frame of an exact length through an interface.

Reproducer for the AX88179A-family TX wedge: the vendor driver advertised
tso_max_size = tx_casecade_size (23552) but needs 8 more bytes for its TX
header, so a GSO frame of 23545..23551 bytes passes the kernel's
skb->len >= gso_max_size check, never fits in a TX buffer, and is
requeued at the head of the driver's queue forever.

The frame goes through the qdisc and validate_xmit_skb like forwarded
traffic (AF_PACKET + PACKET_VNET_HDR), so the kernel's GSO size check
applies exactly as it does in production.

Needs CAP_NET_RAW.  Usage:
  gso-oversize-repro.py IFACE DST_MAC SRC_IP DST_IP [--len 23548]
"""
import argparse
import socket
import struct

SOL_PACKET = 263
PACKET_VNET_HDR = 15
VIRTIO_NET_HDR_F_NEEDS_CSUM = 1
VIRTIO_NET_HDR_GSO_TCPV4 = 1


def csum(data: bytes) -> int:
    if len(data) % 2:
        data += b"\0"
    s = sum(struct.unpack(f"!{len(data) // 2}H", data))
    while s >> 16:
        s = (s & 0xFFFF) + (s >> 16)
    return s


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("iface")
    ap.add_argument("dst_mac")
    ap.add_argument("src_ip")
    ap.add_argument("dst_ip")
    ap.add_argument("--len", type=int, default=23548, help="total frame length incl. Ethernet header")
    ap.add_argument("--mss", type=int, default=1448)
    ap.add_argument("--count", type=int, default=1)
    a = ap.parse_args()

    src_mac = bytes.fromhex(open(f"/sys/class/net/{a.iface}/address").read().strip().replace(":", ""))
    dst_mac = bytes.fromhex(a.dst_mac.replace(":", ""))
    src_ip, dst_ip = socket.inet_aton(a.src_ip), socket.inet_aton(a.dst_ip)

    eth = dst_mac + src_mac + b"\x08\x00"
    payload_len = a.len - 14 - 20 - 20
    assert payload_len > a.mss, "frame must need segmentation"
    ip_len = 20 + 20 + payload_len  # > 65535 is impossible here; GSO fixes it per segment
    ip = struct.pack("!BBHHHBBH4s4s", 0x45, 0, ip_len, 0x1234, 0x4000, 64, 6, 0, src_ip, dst_ip)
    ip = ip[:10] + struct.pack("!H", (~csum(ip)) & 0xFFFF) + ip[12:]
    # TCP checksum field carries the pseudo-header sum (NEEDS_CSUM convention).
    pseudo = csum(src_ip + dst_ip + struct.pack("!BBH", 0, 6, 20 + payload_len))
    tcp = struct.pack("!HHIIBBHHH", 40000, 9, 1, 0, 5 << 4, 0x18, 65535, pseudo, 0)
    frame = eth + ip + tcp + b"\xa5" * payload_len
    assert len(frame) == a.len

    vnet = struct.pack(
        "<BBHHHH",
        VIRTIO_NET_HDR_F_NEEDS_CSUM,
        VIRTIO_NET_HDR_GSO_TCPV4,
        14 + 20 + 20,  # hdr_len
        a.mss,  # gso_size
        14 + 20,  # csum_start
        16,  # csum_offset (TCP checksum)
    )

    s = socket.socket(socket.AF_PACKET, socket.SOCK_RAW)
    s.setsockopt(SOL_PACKET, PACKET_VNET_HDR, 1)
    s.bind((a.iface, 0))
    for _ in range(a.count):
        s.send(vnet + frame)
    print(f"sent {a.count} GSO frame(s) of {len(frame)} bytes (gso_size {a.mss}) on {a.iface}")


if __name__ == "__main__":
    main()
