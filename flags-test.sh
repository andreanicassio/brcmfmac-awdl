#!/bin/bash
# Root, laptop-only. Does the peer-entry flags byte control unicast suppression? Oracle: txsupr delta per ping.
cd "$(dirname "$0")"
stats() { ./brcmiovar.py -b 2 get awdl_stats 256 | python3 -c '
import sys,re,struct
hx="".join(re.findall(r"^\w{4}  ((?:[0-9a-f]{2} ?){1,16})", sys.stdin.read(), re.M)).replace(" ","")
v=struct.unpack_from("<18I",bytes.fromhex(hx)[:72]); print("%d %d"%(v[2],v[12]))'; }
PEER=${1:?}; HEX=$(echo $PEER|tr -d :)
LL=$(python3 -c "
m=bytes.fromhex('$HEX'); b=bytearray(m[:3]+b'\xff\xfe'+m[3:]); b[0]^=2
print('fe80::'+':'.join('%x'%((b[i]<<8)|b[i+1]) for i in range(0,8,2)))")
./awdl-up.sh >/dev/null; ./announce.py "$(hostname)" >/dev/null; sleep 3
ip -6 neigh replace $LL lladdr $PEER dev awdl0 nud permanent
for FL in 01 08 0b 2b 3f 20 00; do
  ./brcmiovar.py -b 2 set awdl_peer_op "0001${HEX}00" >/dev/null 2>&1   # del
  ./brcmiovar.py -b 2 set awdl_peer_op "0000${HEX}${FL}" >/dev/null 2>&1 || { echo "flags 0x$FL: add rejected"; continue; }
  sleep 1; read d0 s0 <<<"$(stats)"
  ping -6 -I awdl0 -c 3 -W 1 $LL 2>&1 | grep -q 'bytes from' && R=REPLY || R=noreply
  sleep 1; read d1 s1 <<<"$(stats)"
  echo "flags 0x$FL: tx=+$((d1-d0)) suppressed=+$((s1-s0)) $R"
done
ip -6 neigh del $LL dev awdl0 2>/dev/null; ./awdl-down.sh >/dev/null
