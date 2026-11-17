#!/usr/bin/env bash
# Prove the oversized-GSO TX wedge on the loaded driver, then swap in a
# patched build and show the same frames no longer wedge it.
#
#   sudo systemd-run --unit=asix-gso-test --collect \
#       bash "$PWD/tools/test-gso-oversize.sh" /path/to/patched/ax_usb_nic.ko
# (systemd-run starts in /, so the script path must be absolute.)
#   journalctl -u asix-gso-test -f       # or: cat /var/log/asix-gso-test.log
#
# Ethernet is down for about 30 s in phase A (that is the bug); the
# watchdog is stopped meanwhile and restarted on exit.  Run it
# detached as above: an SSH session over Ethernet freezes meanwhile.
# Wi-Fi stays up throughout.  Phase A can be skipped with SKIP_A=1.
set -uo pipefail

KO=${1:?patched ax_usb_nic.ko}
IF=enp0s13f0u1
GW=192.168.15.170
SRC_IP=192.168.15.41
DST_IP=192.168.15.100            # this host's Wi-Fi address
DST_MAC=00:d7:6d:5f:b2:b6        # this host's Wi-Fi MAC
HERE=$(cd "$(dirname "$0")" && pwd)
REPRO="$HERE/gso-oversize-repro.py"
LOG=/var/log/asix-gso-test.log

exec > >(tee -a "$LOG") 2>&1
say() { echo "[$(date +%T)] $*"; }
txto() { cat /sys/class/net/$IF/queues/tx-0/tx_timeout 2>/dev/null || echo NA; }
# Every ping is time-limited: on a wedged queue, ping blocks in sendmsg
# forever (its socket buffer never drains), which hung the first run.
ping_eth() { timeout -s KILL 10 ping -I $IF -c 5 -i 0.5 -W 1 -q $GW | tail -2 | head -1; }
load() { timeout -s KILL 15 ping -I $IF -c 40 -i 0.25 -W 1 -q $GW >/dev/null 2>&1; }
wait_link() {
	for _ in $(seq 60); do
		[[ $(cat /sys/class/net/$IF/operstate 2>/dev/null) == up ]] &&
			ip -4 addr show $IF | grep -q "inet $SRC_IP" && return 0
		sleep 1
	done
	return 1
}
probe() { # $1 = label
	say "$1: tx_timeout=$(txto) tx_dropped=$(cat /sys/class/net/$IF/statistics/tx_dropped 2>/dev/null)"
	say "$1: ping gw via $IF: $(ping_eth)"
}

say "=== start; loaded srcversion $(cat /sys/module/ax_usb_nic/srcversion)"
say "patched module: $(modinfo -F srcversion "$KO")"
systemctl stop nic-tx-watchdog
trap 'systemctl start nic-tx-watchdog; say "watchdog restarted"' EXIT
KSTART=$(date '+%F %T')

if [[ ${SKIP_A:-0} != 1 ]]; then
	say "--- phase A: current driver, one 23548-byte GSO frame"
	probe "A before"
	python3 -I "$REPRO" $IF $DST_MAC $SRC_IP $DST_IP --len 23548
	# Keep normal traffic flowing so the queue fills and the timer fires.
	load &
	sleep 15
	probe "A after 15s"
	wait
fi

say "--- swapping in patched module"
modprobe -r ax_usb_nic || rmmod ax_usb_nic
modprobe mii
insmod "$KO" || { say "insmod failed; restoring DKMS module"; modprobe ax_usb_nic; exit 1; }
wait_link && say "link up: $(cat /sys/module/ax_usb_nic/srcversion)" || say "link did not come up in 60 s"
sleep 3
probe "B before"

say "--- phase B: frames around the boundary on the patched driver"
for len in 23543 23544 23545 23548 23551 23552 23600; do
	python3 -I "$REPRO" $IF $DST_MAC $SRC_IP $DST_IP --len $len --count 3
done
load
probe "B after"
say "gso/tso limits: $(ip -d link show $IF | grep -o 'gso_max_size [0-9]*\|tso_max_size [0-9]*\|gso_ipv4_max_size [0-9]*' | tr '\n' ' ')"

say "--- kernel log since start"
journalctl -k --since "$KSTART" --no-pager -o short-precise | grep -E 'ax_usb_nic|NETDEV WATCHDOG|reset SuperSpeed|oversized' | tail -40
say "=== done"
