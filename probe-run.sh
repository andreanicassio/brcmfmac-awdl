#!/bin/bash
# Root. One instrumented AWDL/AirDrop receive window.
#   DUR=150 TXENCAP=0 ./probe-run.sh <tag>
# Records: firmware AWDL counters over time, awdl0 rx/tx counters, a pcap of awdl0,
# the decoded vendor-event stream and the OpenDrop receive log.
cd "$(dirname "$0")"; V=./opendrop-venv/bin
TAG=${1:-run}; DUR=${DUR:-150}; OUT=/tmp/awdl-$TAG
mkdir -p $OUT; rm -f $OUT/*
kill $(pgrep -f '^python3 \./awdlevents.py' ) 2>/dev/null; sleep 0.3
nohup python3 ./awdlevents.py -v > $OUT/events.log 2>&1 &
EVPID=$!
echo ${RXDECAP:-1} > /sys/module/brcmfmac/parameters/awdl_rxdecap
echo ${TXENCAP:-0} > /sys/module/brcmfmac/parameters/awdl_txencap
echo "== $TAG txencap=$(cat /sys/module/brcmfmac/parameters/awdl_txencap) rxdecap=$(cat /sys/module/brcmfmac/parameters/awdl_rxdecap) dur=$DUR"
./awdl-up.sh || exit 1
ip link set awdl0 allmulticast on
./announce.py "$(hostname)" | sed 's/^/   /'
for i in $(seq 1 20); do ip -6 addr show awdl0 | grep -q tentative || break; sleep 0.5; done
OURMAC=$(cat /sys/class/net/awdl0/address)
tcpdump -i awdl0 -n -e -s0 -w $OUT/awdl0.pcap 2>/dev/null &
TCPID=$!
timeout $DUR $V/opendrop -i awdl0 -n "Ubuntu MacBook" -m "MacBookPro16,2" -d receive > $OUT/opendrop.log 2>&1 &
ODPID=$!
# keep re-announcing: zeroconf stops after ~2 s, which on AWDL is close to never
./airdrop-responder.py -i awdl0 -n ${BEACON:-1.5} -w 25 -d $DUR > $OUT/beacon.log 2>&1 &
RX0=$(cat /sys/class/net/awdl0/statistics/rx_packets); TX0=$(cat /sys/class/net/awdl0/statistics/tx_packets)
PEER=""
for t in $(seq 1 $((DUR/5))); do
    sleep 5
    NEW=$(grep -a -o -E 'ACTION_FRAME_RX .* ([0-9a-f]{2}:){5}[0-9a-f]{2}' $OUT/events.log | grep -o -E '([0-9a-f]{2}:){5}[0-9a-f]{2}$' | sort -u | grep -v "^$OURMAC$" | head -1)
    if [ -n "$NEW" ] && [ "$NEW" != "$PEER" ]; then
        PEER=$NEW
        ./peerop.py $OUT/events.log | sed "s/^/   [$((t*5))s] /"
    fi
    echo "   [$((t*5))s] rx=$(( $(cat /sys/class/net/awdl0/statistics/rx_packets) - RX0 )) tx=$(( $(cat /sys/class/net/awdl0/statistics/tx_packets) - TX0 )) fw: $(./awdlstats.py) enc=$(cat /sys/module/brcmfmac/parameters/awdl_rx_encapped)/$(cat /sys/module/brcmfmac/parameters/awdl_rx_plain)"
done
wait $ODPID 2>/dev/null
sleep 1; kill $TCPID 2>/dev/null; sleep 1
echo "== final: awdl0 rx_delta=$(( $(cat /sys/class/net/awdl0/statistics/rx_packets) - RX0 )) tx_delta=$(( $(cat /sys/class/net/awdl0/statistics/tx_packets) - TX0 ))"
echo "== firmware: $(./awdlstats.py)"
echo "== mcast_list on the AWDL bsscfg:"; ./brcmiovar.py -b 2 get mcast_list 64 2>&1 | head -3
echo "== opmode/election:"; ./brcmiovar.py -b 2 get awdl_opmode 64 2>&1 | head -2
echo "== frames on awdl0 not from us:"
tcpdump -r $OUT/awdl0.pcap -n -e 2>/dev/null | grep -v "$OURMAC >" | head -20
echo "== mDNS summary:"; python3 ./pcapmdns.py $OUT/awdl0.pcap $OURMAC 2>&1 | head -40
echo "== beacon:"; cat $OUT/beacon.log
echo "== opendrop log:"; grep -v -E 'pkg_resources' $OUT/opendrop.log | tail -20
echo "== action frames seen:"; python3 ./awdlparse.py $OUT/events.log 2>&1 | grep -E '^==|election |hostname|datapath_flags' | head -20
kill $EVPID 2>/dev/null
./awdl-down.sh >/dev/null
