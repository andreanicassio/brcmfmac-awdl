#!/bin/bash
# Build the AWDL-patched brcmfmac against the running kernel and install it under
# /lib/modules/$(uname -r)/updates/awdl (takes precedence over the stock module).
# Experimental. Undo: sudo rm -r /lib/modules/$(uname -r)/updates/awdl && sudo depmod -a
set -euo pipefail
cd "$(dirname "$0")"
KVER=$(uname -r); KMAJ=${KVER%%-*}
B=/lib/modules/$KVER/build
[ -d "$B" ] || { echo "kernel headers for $KVER missing (apt install linux-headers-$KVER)"; exit 1; }
W=${WORKDIR:-$PWD/kernel}; mkdir -p "$W"; cd "$W"
if [ ! -d brcm80211 ]; then
    echo "fetching linux-$KMAJ sources (only the brcm80211 tree is kept)..."
    curl -fL -o linux.tar.xz "https://cdn.kernel.org/pub/linux/kernel/v${KMAJ%%.*}.x/linux-$KMAJ.tar.xz"
    tar -xJf linux.tar.xz --wildcards "linux-$KMAJ/drivers/net/wireless/broadcom/brcm80211/*"
    mv "linux-$KMAJ/drivers/net/wireless/broadcom/brcm80211" . && rm -rf "linux-$KMAJ" linux.tar.xz
    (cd brcm80211/brcmfmac && patch -p7 < "$OLDPWD/brcmfmac-awdl.patch")
fi
make -C "$B" M="$W/brcm80211/brcmfmac" modules -j"$(nproc)"
U=/lib/modules/$KVER/updates/awdl
sudo mkdir -p "$U"
sudo cp brcm80211/brcmfmac/brcmfmac.ko brcm80211/brcmfmac/wcc/brcmfmac-wcc.ko \
        brcm80211/brcmfmac/cyw/brcmfmac-cyw.ko brcm80211/brcmfmac/bca/brcmfmac-bca.ko "$U/"
sudo depmod -a
echo "installed: $(modinfo -F filename brcmfmac). Reload (drops Wi-Fi ~10 s):"
echo "  sudo modprobe -r brcmfmac_wcc brcmfmac && sudo modprobe brcmfmac"
