#!/bin/bash
# Root. Decisive unicast test: pin the peer's IPv6 link-local to its MAC (skip neighbor
# discovery, which is multicast and has never been answered), then a true unicast ping.
# A reply proves the us->iPad unicast data path. Then run OpenDrop+responder with the pin
# in place and watch for the iPad's TCP connection to port 8771.
cd "$(dirname "$0")"; V=./opendrop-venv/bin; OUT=/tmp/awdl-uc; mkdir -p $OUT; rm -f $OUT/*
pkill -f '^python3 \./awdlevents.py' 2>/dev/null; sleep 0.3
nohup python3 ./awdlevents.py -v > $OUT/events.log 2>&1 &
EVPID=$!
echo 1 > /sys/module/brcmfmac/parameters/awdl_rxdecap; echo ${TXENCAP:-0} > /sys/module/brcmfmac/parameters/awdl_txencap
./awdl-up.sh || exit 1
ip link set awdl0 allmulticast on
./announce.py "$(hostname)" >/dev/null
for i in $(seq 1 20); do ip -6 addr show awdl0 | grep -q tentative || break; sleep 0.5; done
OURMAC=$(cat /sys/class/net/awdl0/address)
# wait for the peer
PEER=""; for i in $(seq 1 60); do PEER=$(grep -a -o -E 'ACTION_FRAME_RX .* ([0-9a-f]{2}:){5}[0-9a-f]{2}' $OUT/events.log | grep -o -E '([0-9a-f]{2}:){5}[0-9a-f]{2}$' | sort -u | grep -v "^$OURMAC$" | head -1); [ -n "$PEER" ] && break; sleep 1; done
[ -z "$PEER" ] && { echo "no peer in 60s"; kill $EVPID; ./awdl-down.sh >/dev/null; exit 2; }
echo "== peer $PEER"
./peerop.py $OUT/events.log 2>&1 | tail -2
HEX=$(echo $PEER | tr -d :)
LL=$(python3 -c "
m=bytes.fromhex('$HEX'); b=bytearray(m[:3]+b'\xff\xfe'+m[3:]); b[0]^=2
print('fe80::'+':'.join('%x'%((b[i]<<8)|b[i+1]) for i in range(0,8,2)))")
echo "== pin neighbor $LL -> $PEER (skips multicast ND)"
ip -6 neigh replace $LL lladdr $PEER dev awdl0 nud permanent
ip -6 neigh show dev awdl0 | grep -i "$PEER"
dmesg -C
tcpdump -i awdl0 -n -e -s0 -w $OUT/awdl0.pcap 2>/dev/null & TCPID=$!
sleep 1
S0=$(./awdlstats.py)
echo "== TRUE UNICAST ping6 to $LL (5 tries):"
ping -6 -I awdl0 -c 5 -W 2 $LL 2>&1 | tail -3
echo "== firmware delta:"; echo "   before: $S0"; echo "   after:  $(./awdlstats.py)"
echo "== kernel log (flowring / tx errors):"; dmesg | grep -a -iE 'flowring|flow ring|txstatus|awdl|drop' | grep -a -v -E 'forwarded|iovar|cmd=' | tail -8
echo "== now OpenDrop + responder for ${DUR:-90}s with the pin in place. KEEP the iPad share sheet open."
timeout ${DUR:-90} $V/opendrop -i awdl0 -n "Ubuntu MacBook" -m "MacBookPro16,2" -d receive > $OUT/opendrop.log 2>&1 & ODPID=$!
./airdrop-responder.py -i awdl0 -n 1.5 -w 25 -d ${DUR:-90} > $OUT/beacon.log 2>&1 &
wait $ODPID 2>/dev/null; sleep 1; kill $TCPID 2>/dev/null; sleep 1
echo "== responder:"; cat $OUT/beacon.log | tail -5
echo "== TCP to 8771 or unicast from iPad to us:"; tcpdump -r $OUT/awdl0.pcap -n 2>/dev/null | grep -a -E '\.8771|> fe80::3c22:fbff:fef0:eaa' | grep -a -v '^fe80::3c22' | head -10
echo "== ICMP echo replies from iPad:"; tcpdump -r $OUT/awdl0.pcap -n 2>/dev/null | grep -a -E 'echo reply' | head -3
echo "== opendrop requests:"; grep -a -E 'POST|GET|Discover|Ask|Upload|connect' $OUT/opendrop.log | head -8
echo "== frames from iPad (any):"; tcpdump -r $OUT/awdl0.pcap -n -e 2>/dev/null | grep -a "^.* $PEER >" | wc -l
kill $EVPID 2>/dev/null; ./awdl-down.sh >/dev/null
