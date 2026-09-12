#!/bin/bash
# Root. Test the data plane against a Mac whose awdl0 MAC is given.
#   ./mac-test.sh <mac-awdl0-MAC> [duration]
# Pins the Mac's link-local, pings it (true unicast), runs OpenDrop + responder, captures.
cd "$(dirname "$0")"; V=./opendrop-venv/bin; OUT=/tmp/awdl-mac; mkdir -p $OUT; rm -f $OUT/*
MAC=$(echo "$1" | tr 'A-F' 'a-f'); DUR=${2:-120}
[ -z "$MAC" ] && { echo "usage: $0 <mac awdl0 MAC> [duration]"; exit 1; }
pkill -f '^python3 \./awdlevents.py' 2>/dev/null; sleep 0.3
nohup python3 ./awdlevents.py -v > $OUT/events.log 2>&1 & EVPID=$!
echo 1 > /sys/module/brcmfmac/parameters/awdl_rxdecap; echo ${TXENCAP:-0} > /sys/module/brcmfmac/parameters/awdl_txencap
./awdl-up.sh || exit 1
ip link set awdl0 allmulticast on
./announce.py "$(hostname)" >/dev/null
for i in $(seq 1 20); do ip -6 addr show awdl0 | grep -q tentative || break; sleep 0.5; done
OURMAC=$(cat /sys/class/net/awdl0/address); OURLL=$(ip -6 addr show awdl0 | awk '/inet6 fe80/{print $2}' | cut -d/ -f1)
echo "== laptop awdl0: $OURMAC  $OURLL"
echo "== waiting for the Mac ($MAC) sync frames..."
for i in $(seq 1 60); do grep -a -q "ACTION_FRAME_RX .* $MAC" $OUT/events.log && break; sleep 1; done
grep -a -q "ACTION_FRAME_RX .* $MAC" $OUT/events.log && echo "   Mac heard after ${i}s" || echo "   Mac NOT heard in 60s (is its AirDrop window open?) — continuing anyway"
python3 - "$MAC" <<'PY' > $OUT/peerop.hex
import sys; print(sys.argv[1].replace(':',''))
PY
./brcmiovar.py -b 2 set awdl_peer_op "0000$(cat $OUT/peerop.hex)00" >/dev/null && echo "   Mac added to firmware peer table"
LL=$(python3 -c "
m=bytes.fromhex('$(cat $OUT/peerop.hex)'); b=bytearray(m[:3]+b'\xff\xfe'+m[3:]); b[0]^=2
print('fe80::'+':'.join('%x'%((b[i]<<8)|b[i+1]) for i in range(0,8,2)))")
ip -6 neigh replace $LL lladdr $MAC dev awdl0 nud permanent
echo "== Mac link-local (derived): $LL  (pinned, ND bypassed)"
tcpdump -i awdl0 -n -e -s0 -w $OUT/awdl0.pcap 2>/dev/null & TCPID=$!
timeout $DUR $V/opendrop -i awdl0 -n "Ubuntu MacBook" -m "MacBookPro16,2" -d receive > $OUT/opendrop.log 2>&1 & ODPID=$!
./airdrop-responder.py -i awdl0 -n 1.5 -w 25 -d $DUR > $OUT/beacon.log 2>&1 &
sleep 3
for round in 1 2 3; do
  echo "== ping6 Mac (round $round):"; ping -6 -I awdl0 -c 5 -W 2 $LL 2>&1 | grep -E 'packets|bytes from' | head -2
  echo "   firmware: $(./awdlstats.py)"; sleep $(( (DUR-25)/3 ))
done
wait $ODPID 2>/dev/null; sleep 1; kill $TCPID 2>/dev/null; sleep 1
echo "== frames from the Mac on awdl0: $(tcpdump -r $OUT/awdl0.pcap -n -e 2>/dev/null | grep -a -c "^.* $MAC >")"
echo "== Mac -> us unicast / TCP 8771 / echo replies:"; tcpdump -r $OUT/awdl0.pcap -n 2>/dev/null | grep -a -E "> $OURLL|\.8771|echo reply" | grep -a -v "^.*$OURLL >" | head -8
echo "== mDNS from the Mac:"; python3 pcapmdns.py $OUT/awdl0.pcap $OURMAC 2>&1 | head -12
echo "== responder:"; tail -3 $OUT/beacon.log
echo "== opendrop requests:"; grep -a -E 'POST|GET|Discover|Ask' $OUT/opendrop.log | head -5
echo "== sync frames from the Mac: $(grep -a -c "ACTION_FRAME_RX .* $MAC" $OUT/events.log)"
kill $EVPID 2>/dev/null; ./awdl-down.sh >/dev/null; echo "== done (AWDL off)"
