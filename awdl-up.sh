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
MASTER_CHAN=${MASTER_CHAN:-44}     # 5 GHz social channel (6 on 2.4 GHz)
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
# sync params (36 B): master_chan@6, aw_period@8, af_period@10, aw_ext_len@14, aw_cmn_len@16
SYNC=$(python3 -c "
import struct;b=bytearray(36);b[6]=$MASTER_CHAN
struct.pack_into('<HH',b,8,16,110);struct.pack_into('<HH',b,14,16,16);print(b.hex())")
./brcmiovar.py -i $IF -b $CFG set awdl_sync_params $SYNC >/dev/null
# channel sequence: count-1, enc=0 (1-byte channel numbers), dup=0, step=3, fill=0xffff, 16 slots.
# A slot of 0 = "stay on the infrastructure channel". Apple typically uses only 3-4 AWDL slots
# out of 16 (e.g. [44 0 0 0 0 0 0 0 6 44 44 0 0 0 0 0]); filling all 16 (as first tried) keeps
# the radio off the AP's channel almost continuously and effectively kills the Wi-Fi link.
SEQ=$(python3 -c "
m=$MASTER_CHAN; o=6 if m>14 else 44
seq=[m,0,0,0,0,0,0,0,o,m,m,0,0,0,0,0]
print((bytes([15,0,0,3])+b'\xff\xff'+bytes(seq)).hex())")
./brcmiovar.py -i $IF -b $CFG set awdl_chan_seq $SEQ >/dev/null
./brcmiovar.py -i $IF -b $CFG set awdl_extcounts 03030303 >/dev/null
./brcmiovar.py -i $IF -b $CFG setint awdl_presencemode 4 >/dev/null
./brcmiovar.py -i $IF -b $CFG setint awdl_aftxmode 0 >/dev/null
./brcmiovar.py -i $IF -b $CFG setint awdl_config 115 >/dev/null      # value Apple's driver uses
./brcmiovar.py -i $IF -b $CFG setint awdl_af_rssi -90 >/dev/null     # Apple uses -60
./brcmiovar.py -i $IF -b $CFG setint awdl 1 >/dev/null
echo "AWDL enabled on awdl0 (bsscfg $CFG, master channel $MASTER_CHAN); state: $(./brcmiovar.py -i $IF -b $CFG getint awdl)"
