#!/bin/bash
# Root. AWDL up + announce + peer, then OpenDrop find (we browse) and receive (iPad browses).
cd "$(dirname "$0")"; V=./opendrop-venv/bin
pkill -f '^python3 /home/andrea/awdl-brcmfmac/awdlevents.py' 2>/dev/null; sleep 0.5
nohup python3 ./awdlevents.py -v > events.log 2>&1 &
echo 1 > /sys/module/brcmfmac/parameters/awdl_rxdecap
echo ${TXENCAP:-0} > /sys/module/brcmfmac/parameters/awdl_txencap
echo "txencap=$(cat /sys/module/brcmfmac/parameters/awdl_txencap) rxdecap=$(cat /sys/module/brcmfmac/parameters/awdl_rxdecap)"
./awdl-up.sh >/dev/null || exit 1
./announce.py "$(hostname)" >/dev/null
for i in $(seq 1 20); do ip -6 addr show awdl0 | grep -q tentative || break; sleep 0.5; done
PEER=""; for i in $(seq 1 ${1:-90}); do PEER=$(grep -a -m1 -o -E 'ACTION_FRAME_RX .* ([0-9a-f]{2}:){5}[0-9a-f]{2}' events.log | grep -o -E '([0-9a-f]{2}:){5}[0-9a-f]{2}$'); [ -n "$PEER" ] && break; sleep 1; done
[ -z "$PEER" ] && { echo "no peer"; ./awdl-down.sh >/dev/null; exit 2; }
echo "peer $PEER after ${i}s"; ./brcmiovar.py -b 2 set awdl_peer_op "0000$(echo $PEER | tr -d :)00" >/dev/null && echo "peer added"
PCAP=/tmp/awdl-opendrop.pcap; rm -f $PCAP; timeout 100 tcpdump -i awdl0 -n -e -w $PCAP 2>/dev/null &
if [ -n "$FIND" ]; then echo "===== opendrop find (30s)"; timeout 35 $V/opendrop -i awdl0 -d find 2>&1 | grep -v -E 'pkg_resources|from pkg_resources' | tail -15; fi
echo "===== opendrop receive (60s) as 'Ubuntu MacBook'"; timeout ${RECV:-75} $V/opendrop -i awdl0 -n "Ubuntu MacBook" -m "MacBookPro16,2" -d receive 2>&1 | grep -v -E 'pkg_resources|from pkg_resources' | tail -25
sleep 2
echo "===== frames from others on awdl0 during the test:"; tcpdump -r $PCAP -n -e 2>/dev/null | grep -a -v "$(cat /sys/class/net/awdl0/address) >" | grep -a -v -E '^\s' | cut -c1-160 | head -12
echo "rx_packets: $(cat /sys/class/net/awdl0/statistics/rx_packets)"
./awdl-down.sh >/dev/null
