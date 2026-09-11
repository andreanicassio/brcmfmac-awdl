#!/bin/bash
# Root. Wait for an Apple peer, then for each awdl_txencap mode: send mDNS queries for
# _airdrop._tcp (multicast) and the peer's AAAA (unicast) over awdl0, capture what comes back.
cd "$(dirname "$0")"
WAIT=${1:-180}; CAP=${CAP:-20}
pkill -f '^python3 /home/andrea/awdl-brcmfmac/awdlevents.py' 2>/dev/null; sleep 0.5
nohup python3 ./awdlevents.py -v > events.log 2>&1 &
./awdl-up.sh >/dev/null || exit 1
./announce.py "$(hostname)" >/dev/null
for i in $(seq 1 20); do ip -6 addr show awdl0 | grep -q tentative || break; sleep 0.5; done   # wait for DAD
echo "waiting up to ${WAIT}s for an Apple device..."
PEER=""
for i in $(seq 1 "$WAIT"); do
    PEER=$(grep -a -m1 -o -E 'ACTION_FRAME_RX .* ([0-9a-f]{2}:){5}[0-9a-f]{2}' events.log | grep -o -E '([0-9a-f]{2}:){5}[0-9a-f]{2}$')
    [ -n "$PEER" ] && break; sleep 1
done
[ -z "$PEER" ] && { echo "no peer in ${WAIT}s"; ./awdl-down.sh >/dev/null; exit 2; }
HEX=$(echo "$PEER" | tr -d :)
sleep 3; NAME=$(python3 awdlparse.py events.log 2>/dev/null | grep -a -m1 hostname | awk '{print $2}')
echo "peer $PEER  hostname $NAME  (after ${i}s)"
./brcmiovar.py -b 2 set awdl_peer_op "0000${HEX}00" >/dev/null && echo "peer added"
LL=$(python3 -c "
m=bytes.fromhex('$HEX'); b=bytearray(m[:3]+b'\xff\xfe'+m[3:]); b[0]^=2
print('fe80::'+':'.join('%x'%((b[i]<<8)|b[i+1]) for i in range(0,8,2)))")
for mode in ${MODES:-0:0 0:1 1:1 1:0}; do
    tx=${mode%%:*}; rx=${mode##*:}
    echo "===== awdl_txencap=$tx awdl_rxdecap=$rx"
    echo $tx > /sys/module/brcmfmac/parameters/awdl_txencap
    echo $rx > /sys/module/brcmfmac/parameters/awdl_rxdecap
    RX0=$(cat /sys/class/net/awdl0/statistics/rx_packets)
    PCAP=/tmp/awdl-encap-$tx$rx.pcap; rm -f $PCAP
    timeout $CAP tcpdump -i awdl0 -n -e -w $PCAP 2>/dev/null &
    sleep 1
    python3 - "$LL" "$NAME" <<'PY'
import socket, struct, time, sys, select
ll, name = sys.argv[1], sys.argv[2]
def q(n, t=12, qu=False):
    b=b''.join(bytes([len(l)])+l.encode() for l in n.split('.'))+b'\x00'
    return struct.pack('>HHHHHH',0x1234,0,1,0,0,0)+b+struct.pack('>HH',t,(0x8000 if qu else 0)|1)
def names(pkt):
    out=[]; i=12
    try:
        while i < len(pkt):
            if pkt[i]==0: i+=1; break
            if pkt[i]&0xc0==0xc0: i+=2; break
            out.append(pkt[i+1:i+1+pkt[i]].decode(errors='replace')); i+=1+pkt[i]
    except Exception: pass
    return '.'.join(out)
s=socket.socket(socket.AF_INET6,socket.SOCK_DGRAM); s.setsockopt(socket.SOL_SOCKET,25,b'awdl0')
s.setsockopt(socket.IPPROTO_IPV6,socket.IPV6_MULTICAST_HOPS,255); s.setsockopt(socket.IPPROTO_IPV6,socket.IPV6_UNICAST_HOPS,255)
s.settimeout(0.5); got=0
for i in range(5):
    s.sendto(q('_airdrop._tcp.local'),('ff02::fb%awdl0',5353))
    s.sendto(q('_airdrop._tcp.local'),(ll+'%awdl0',5353))
    if name: s.sendto(q(name,28),(ll+'%awdl0',5353))
    t0=time.time()
    while time.time()-t0 < 2:
        try:
            d,a=s.recvfrom(4096); got+=1
            print('  REPLY from %s: %d bytes, %d answers, q=%s %s' % (a[0], len(d), struct.unpack_from('>H',d,6)[0], names(d), ('_airdrop' in d.decode('latin1'))*' [contains _airdrop]'))
        except socket.timeout: pass
print('queries sent, %d unicast replies' % got)
PY
    ping -6 -I awdl0 -c 3 -W 2 "$LL" 2>&1 | grep -E 'packets|bytes from' | head -2
    sleep $(( CAP - 10 ))
    echo "-- awdl0 rx_packets delta: $(( $(cat /sys/class/net/awdl0/statistics/rx_packets) - RX0 ))"
    echo "-- received from others:"; tcpdump -r $PCAP -n -e 2>/dev/null | grep -a -v "$(cat /sys/class/net/awdl0/address) >" | grep -a -v -E "^\s" | cut -c1-200 | head -8
    tcpdump -r $PCAP -n -X 2>/dev/null | grep -i -o -E '_airdrop|[a-f0-9]{12}\._airdrop' | sort | uniq -c | head -3
done
./awdl-down.sh >/dev/null
