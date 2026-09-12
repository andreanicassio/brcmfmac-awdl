#!/bin/bash
# Root, laptop-only. Which step makes the firmware suppress data TX? Oracle: awdl_stats txsupr.
cd "$(dirname "$0")"
stats() { ./brcmiovar.py -b 2 get awdl_stats 256 | python3 -c '
import sys,re,struct
hx="".join(re.findall(r"^\w{4}  ((?:[0-9a-f]{2} ?){1,16})", sys.stdin.read(), re.M)).replace(" ","")
v=struct.unpack_from("<18I",bytes.fromhex(hx)[:72]); print("datatx=%d txsupr=%d txdrop=%d aws=%d"%(v[2],v[12],v[4],v[9]))'; }
mcast() { for i in $(seq 1 20); do python3 -c "
import socket; s=socket.socket(socket.AF_INET6,socket.SOCK_DGRAM); s.setsockopt(socket.SOL_SOCKET,25,b'awdl0'); s.setsockopt(socket.IPPROTO_IPV6,socket.IPV6_MULTICAST_HOPS,255); s.sendto(b'x'*40,('ff02::fb%awdl0',5353))"; sleep 0.15; done; sleep 1; }
PEER=${1:?peer mac}; HEX=$(echo $PEER|tr -d :)
LL=$(python3 -c "
m=bytes.fromhex('$HEX'); b=bytearray(m[:3]+b'\xff\xfe'+m[3:]); b[0]^=2
print('fe80::'+':'.join('%x'%((b[i]<<8)|b[i+1]) for i in range(0,8,2)))")
pkill -f '^python3 \./awdlevents.py' 2>/dev/null; sleep 0.3; nohup python3 ./awdlevents.py -v > /tmp/supr-events.log 2>&1 & EV=$!
./awdl-up.sh >/dev/null; ./announce.py "$(hostname)" >/dev/null; sleep 3
echo "A) no peer registered:        before: $(stats)"; mcast; echo "                               after:  $(stats)"
./brcmiovar.py -b 2 set awdl_peer_op "0000${HEX}00" >/dev/null
echo "B) minimal peer_op add:       before: $(stats)"; mcast; echo "                               after:  $(stats)"
sleep 2; ./peerop.py /tmp/supr-events.log 2>&1 | tail -1
echo "C) full peer entry (chanseq): before: $(stats)"; mcast; echo "                               after:  $(stats)"
ip -6 neigh replace $LL lladdr $PEER dev awdl0 nud permanent
echo "D) pinned neighbor + 5 unicast pings: before: $(stats)"; ping -6 -I awdl0 -c 5 -W 1 $LL >/dev/null 2>&1; sleep 1; echo "                               after:  $(stats)"
echo "E) 20 multicast again (peer+pin present): before: $(stats)"; mcast; echo "                               after:  $(stats)"
ip -6 neigh del $LL dev awdl0 2>/dev/null; kill $EV 2>/dev/null; ./awdl-down.sh >/dev/null
