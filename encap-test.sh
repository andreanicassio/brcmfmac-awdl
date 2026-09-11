#!/bin/bash
# Root. Wait for an Apple peer, then for each awdl_txencap mode: send mDNS queries for
# _airdrop._tcp (multicast) and the peer's AAAA (unicast) over awdl0, capture what comes back.
cd "$(dirname "$0")"
WAIT=${1:-180}; CAP=${CAP:-20}
pkill -f '^python3 /home/andrea/awdl-brcmfmac/awdlevents.py' 2>/dev/null
nohup python3 ./awdlevents.py -v > events.log 2>&1 &
./awdl-up.sh >/dev/null || exit 1
./announce.py "$(hostname)" >/dev/null
echo "waiting up to ${WAIT}s for an Apple device..."
PEER=""
for i in $(seq 1 "$WAIT"); do
    PEER=$(grep -m1 -o -E 'ACTION_FRAME_RX .* ([0-9a-f]{2}:){5}[0-9a-f]{2}' events.log | grep -o -E '([0-9a-f]{2}:){5}[0-9a-f]{2}$')
    [ -n "$PEER" ] && break; sleep 1
done
[ -z "$PEER" ] && { echo "no peer in ${WAIT}s"; ./awdl-down.sh >/dev/null; exit 2; }
HEX=$(echo "$PEER" | tr -d :)
NAME=$(python3 awdlparse.py events.log | grep -m1 hostname | awk '{print $2}')
echo "peer $PEER  hostname $NAME  (after ${i}s)"
./brcmiovar.py -b 2 set awdl_peer_op "0000${HEX}00" >/dev/null && echo "peer added"
LL=$(python3 -c "
m=bytes.fromhex('$HEX'); b=bytearray(m[:3]+b'\xff\xfe'+m[3:]); b[0]^=2
print('fe80::'+':'.join('%x'%((b[i]<<8)|b[i+1]) for i in range(0,8,2)))")
for mode in ${MODES:-0 1}; do
    echo "===== awdl_txencap=$mode"
    echo $mode > /sys/module/brcmfmac/parameters/awdl_txencap
    PCAP=/tmp/awdl-encap-$mode.pcap; rm -f $PCAP
    timeout $CAP tcpdump -i awdl0 -n -e -w $PCAP 2>/dev/null &
    sleep 1
    python3 - "$LL" "$NAME" <<'PY'
import socket, struct, time, sys
ll, name = sys.argv[1], sys.argv[2]
def q(n, t=12, qu=False):
    b=b''.join(bytes([len(l)])+l.encode() for l in n.split('.'))+b'\x00'
    return struct.pack('>HHHHHH',0,0,1,0,0,0)+b+struct.pack('>HH',t,(0x8000 if qu else 0)|1)
s=socket.socket(socket.AF_INET6,socket.SOCK_DGRAM); s.setsockopt(socket.SOL_SOCKET,25,b'awdl0')
s.setsockopt(socket.IPPROTO_IPV6,socket.IPV6_MULTICAST_HOPS,255); s.setsockopt(socket.IPPROTO_IPV6,socket.IPV6_UNICAST_HOPS,255)
s.bind(('::',5353))
for i in range(4):
    s.sendto(q('_airdrop._tcp.local'),('ff02::fb%awdl0',5353))
    if name: s.sendto(q(name,28,True),('ff02::fb%awdl0',5353)); s.sendto(q(name,28,True),(ll+'%awdl0',5353))
    time.sleep(2)
print('queries sent')
PY
    ping -6 -I awdl0 -c 3 -W 2 "$LL" 2>&1 | grep -E 'packets|bytes from' | head -2
    sleep $(( CAP - 10 ))
    echo "-- received from others:"; tcpdump -r $PCAP -n 2>/dev/null | grep -v "$(cat /sys/class/net/awdl0/address) >" | grep -v -E "^\s" | head -8
    tcpdump -r $PCAP -n -X 2>/dev/null | grep -i -o -E '_airdrop|[a-f0-9]{12}\._airdrop' | sort | uniq -c | head -3
done
./awdl-down.sh >/dev/null
