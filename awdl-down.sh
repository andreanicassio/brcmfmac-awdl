#!/bin/sh
# Disable AWDL and remove awdl0 (root).
cd "$(dirname "$0")"
IF=${IF:-wlp229s0}; CFG=${CFG:-2}
./brcmiovar.py -i $IF -b $CFG setint awdl 0 2>/dev/null
ip link set awdl0 down 2>/dev/null
./brcmiovar.py -i $IF -b $CFG set interface_remove "" 2>/dev/null || true
sleep 0.5; ip link show awdl0 >/dev/null 2>&1 && echo "awdl0 still present (interface_remove unsupported?)" || echo "awdl0 removed"
