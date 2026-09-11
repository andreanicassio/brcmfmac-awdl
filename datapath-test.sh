#!/bin/bash
# Data-path experiment (root): enable AWDL, announce ourselves, wait for an Apple peer,
# add it to the firmware peer table, then see whether unicast/multicast data flows on awdl0.
# Usage: datapath-test.sh [wait-seconds]
cd "$(dirname "$0")"
WAIT=${1:-120}
PCAP=${PCAP:-/tmp/awdl-datapath-$$.pcap}; rm -f "$PCAP"
pkill -f '^python3 /home/andrea/awdl-brcmfmac/awdlevents.py' 2>/dev/null; sleep 0.5
nohup python3 ./awdlevents.py -v > events.log 2>&1 &
./awdl-up.sh || exit 1
./announce.py "$(hostname)" | tail -1
echo "waiting up to ${WAIT}s for an Apple device's AWDL frames..."
PEER=""
for i in $(seq 1 "$WAIT"); do
    PEER=$(grep -a -m1 -o -E 'ACTION_FRAME_RX .* ([0-9a-f]{2}:){5}[0-9a-f]{2}' events.log | grep -o -E '([0-9a-f]{2}:){5}[0-9a-f]{2}$')
    [ -n "$PEER" ] && break
    sleep 1
done
if [ -z "$PEER" ]; then echo "no peer heard in ${WAIT}s"; ./awdl-down.sh; exit 2; fi
echo "peer: $PEER (after ${i}s)"
python3 awdlparse.py events.log 2>/dev/null | grep -E '^==|hostname|awdl_version' | head -6
HEX=$(echo "$PEER" | tr -d :)
# old-format awdl_peer_op_t {version=0, opcode=0 (ADD), addr, mode=0}
./brcmiovar.py -b 2 set awdl_peer_op "0000${HEX}00" && echo "peer added to firmware table"
# link-local from MAC (EUI-64)
LL=$(python3 -c "
m=bytes.fromhex('$HEX'); b=bytearray(m[:3]+b'\xff\xfe'+m[3:]); b[0]^=2
print('fe80::'+':'.join('%x'%((b[i]<<8)|b[i+1]) for i in range(0,8,2)))")
echo "peer link-local: $LL"
timeout ${CAP:-25} tcpdump -i awdl0 -n -e -w "$PCAP" 2>/dev/null &
sleep 1
ping -6 -I awdl0 -c 5 -W 2 "$LL" 2>&1 | tail -2
# a couple of mDNS queries for AirDrop, like a sender would
python3 - <<PY
import socket, struct, time
def q(name):
    b=b''.join(bytes([len(l)])+l.encode() for l in name.split('.'))+b'\x00'
    return struct.pack('>HHHHHH',0,0,1,0,0,0)+b+struct.pack('>HH',12,1)
s=socket.socket(socket.AF_INET6,socket.SOCK_DGRAM); s.setsockopt(socket.SOL_SOCKET,25,b'awdl0')
s.setsockopt(socket.IPPROTO_IPV6,socket.IPV6_MULTICAST_HOPS,255)
for i in range(3):
    s.sendto(q('_airdrop._tcp.local'),('ff02::fb%awdl0',5353)); time.sleep(2)
print('sent 3 mDNS _airdrop queries')
PY
sleep $(( ${CAP:-25} - 12 ))
echo "== awdl0 counters:"; ip -s link show awdl0 | sed -n 3,6p
echo "== frames received from others on awdl0:"; tcpdump -r "$PCAP" -n -e 2>/dev/null | grep -v "$(cat /sys/class/net/awdl0/address) >" | head -15
echo "== firmware advertisers:"; ./brcmiovar.py -b 2 get awdl_advertisers 120 | head -4
echo "== firmware peer table:"; ./brcmiovar.py -b 2 get awdl_peer_op 200 | head -4
./awdl-down.sh
