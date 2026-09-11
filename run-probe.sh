#!/bin/sh
# First contact with the firmware. Needs root (nl80211 vendor commands).
cd "$(dirname "$0")"
echo "== firmware version =="; ./brcmiovar.py getstr ver
echo "== capability string (look for 'awdl') =="; ./brcmiovar.py getstr cap 2048
echo "== probing AWDL iovars =="; ./brcmiovar.py probefile iovars-awdl.txt
