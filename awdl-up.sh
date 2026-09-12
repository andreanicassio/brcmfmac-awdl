#!/bin/sh
# WARNING: while AWDL is on, the radio leaves the AP's channel for the AWDL slots, so
# Wi-Fi throughput drops (Apple has the same trade-off). Run awdl-down.sh when done testing.
# Bring up AWDL on the Broadcom firmware's built-in engine (needs the patched
# brcmfmac from this project and root). Creates awdl0, configures sync
# parameters + channel sequence the way Apple's iOS driver does, enables AWDL.
set -e
cd "$(dirname "$0")"
IF=${IF:-wlp229s0}
CFG=${CFG:-2}                      # bsscfg index to use for the AWDL interface
MASTER_CHAN=${MASTER_CHAN:-6}      # master/home channel announced in sync params
AWDL_MAC=${AWDL_MAC:-}             # default: primary MAC with local bit set, last byte 0xaa

if ! ip link show awdl0 >/dev/null 2>&1; then
    if [ -z "$AWDL_MAC" ]; then
        p=$(cat /sys/class/net/$IF/address)
        AWDL_MAC=$(printf '%02x%s' $(( 0x${p%%:*} | 0x02 )) "$(echo "$p" | cut -d: -f2-5 | tr -d :)")aa
    fi
    # wl_awdl_if2_t { int32 cfg_idx; int32 up; bssid[6]; if_addr[6]; } ; AWDL BSSID is fixed
    ./brcmiovar.py -i $IF set awdl_if "$(printf '%02x000000' $CFG)01000000002500ff9473$AWDL_MAC" >/dev/null
    for i in 1 2 3 4 5 6 7 8 9 10; do ip link show awdl0 >/dev/null 2>&1 && break; sleep 0.2; done
fi
ip link set awdl0 up
# sync params: full awdl_sync_params_t (36 B), mirroring what the peer iOS device
# advertises in its SYNC_PARAMS TLV: master channel 6, aw_period 16 TU, action-frame
# period 110 TU (the firmware's own default is 1000 TU = one announcement per second,
# ~9x rarer than Apple devices announce), guard 0, ext counts 3/3/3/3, presence mode 4.
SYNC=$(MC=$MASTER_CHAN AF=${AF_PERIOD:-110} python3 -c "
import os, struct
b = bytearray(36)
b[6] = int(os.environ['MC'])                       # master_chan
b[7] = 0                                           # guard_time
struct.pack_into('<HHH', b, 8, 16, int(os.environ['AF']), 0)   # aw_period, af_period, flags
struct.pack_into('<HHH', b, 14, 16, 16, 0)         # aw_ext_len, aw_cmn_len, aw_remaining
b[20:24] = bytes([3, 3, 3, 3])                     # min_ext, max_ext multi/uni/af
b[30] = 4                                          # presence_mode
print(b.hex())")
./brcmiovar.py -i $IF -b $CFG set awdl_sync_params $SYNC >/dev/null
# channel sequence (enc=2, big-endian D11AC chanspecs, 16 slots), slot-for-slot ALIGNED
# with the sequence Apple devices advertise: 5 GHz social channel in slots 2 and 10,
# 2.4 GHz social channel in slot 8, infra channel (= the AP's, so Wi-Fi keeps working)
# everywhere else. Meeting the peer on the same channel in the same availability window
# is what makes data flow; a mismatched sequence only overlaps by luck.
INFRA_CHAN=${INFRA_CHAN:-$(iw dev $IF link 2>/dev/null | awk '/freq:/{f=$2} END{if(f>5000)print int((f-5000)/5); else print int((f-2407)/5)}')}
[ -z "$INFRA_CHAN" ] && INFRA_CHAN=44
SEQ=$(INFRA=$INFRA_CHAN S5=${SOCIAL5:-44} S2=${SOCIAL2:-6} python3 -c "
import os,struct
inf=int(os.environ['INFRA']); s5=int(os.environ['S5']); s2=int(os.environ['S2'])
cs=lambda c:(0xC000 if c>14 else 0)|0x1000|c
slots=[inf]*16
slots[2]=s5; slots[8]=s2; slots[10]=s5
print((bytes([15,2,0,3])+b'\xff\xff'+b''.join(struct.pack('>H',cs(c)) for c in slots)).hex())")
./brcmiovar.py -i $IF -b $CFG set awdl_chan_seq $SEQ >/dev/null
./brcmiovar.py -i $IF -b $CFG set awdl_extcounts 03030303 >/dev/null
./brcmiovar.py -i $IF -b $CFG setint awdl_presencemode 4 >/dev/null
./brcmiovar.py -i $IF -b $CFG setint awdl_aftxmode 0 >/dev/null
./brcmiovar.py -i $IF -b $CFG setint awdl_config 115 >/dev/null      # value Apple's driver uses
./brcmiovar.py -i $IF -b $CFG setint awdl_af_rssi -90 >/dev/null     # Apple uses -60
./brcmiovar.py -i $IF -b $CFG setint awdl 1 >/dev/null
# election tree. MEASURED: writing ANY non-zero self_metric here (even 400, well below
# the ~540 a nearby iPad advertises) makes this firmware elect ITSELF master -- role goes
# to 2, we stop following the peer's TSF, and action-frame RX drops from ~12-16/s to
# ~4/s. Since slot alignment (and therefore the whole data path) depends on staying
# synced to the peer, leave the metric at 0 by default. ELECT_METRIC=1200 to experiment.
if [ "${ELECT_METRIC:-0}" != 0 ]; then
python3 - "$IF" $CFG ${ELECT_METRIC} ${ELECT_ID:-0x4c4e} <<'PY'
import socket, struct, sys
from brcmiovar import GenlSock
g = GenlSock(); g.bsscfg = int(sys.argv[2]); idx = socket.if_nametoindex(sys.argv[1])
b = bytearray(g.get_var(idx, "awdl_election_tree", 256)[:42])
struct.pack_into("<H", b, 1, int(sys.argv[4], 0))
struct.pack_into("<I", b, 3, int(sys.argv[3]))
g.set_var(idx, "awdl_election_tree", bytes(b))
PY
fi
echo "AWDL enabled on awdl0 (bsscfg $CFG, master channel $MASTER_CHAN); state: $(./brcmiovar.py -i $IF -b $CFG getint awdl)"
