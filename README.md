# brcmfmac-awdl — AWDL (AirDrop-compatible) on Linux using the Broadcom firmware's own engine

**Status: experimental research, working peer discovery, no file transfer yet.**

Intel-era and Apple-silicon Macs running Linux use Broadcom Wi-Fi chips (BCM4364, BCM4377,
BCM4378, ...) with Apple-supplied firmware. That firmware contains the complete
[AWDL](https://owlink.org) engine (the ad-hoc link under AirDrop, AirPlay, Sidecar): timing,
channel hopping, synchronisation frames, peer table. macOS and iOS drive it through private
Broadcom iovars. Linux's `brcmfmac` driver has never used any of it.

This repo does. On a MacBookPro16,2 (BCM4364, linux-t2 kernel 7.2.x) it:

- creates the firmware's AWDL interface and exposes it as a Linux netdev, **`awdl0`**
  (small `brcmfmac` patch);
- forwards the firmware's AWDL events (availability windows, role changes, action frames)
  to userspace as nl80211 vendor events;
- configures and enables AWDL the way Apple's driver does;
- **receives AWDL frames from nearby Apple devices and synchronises to them** — verified
  against an iPad in AirDrop "Everyone" mode: ~100 frames in 30 s, firmware switches to
  slave role, `awdlparse.py` decodes the iPad's hostname, version and service records.

This is the part that was believed impossible on these machines: the previous open
implementation ([OWL](https://github.com/seemoo-lab/owl)) needs monitor mode and frame
injection, which `brcmfmac` FullMAC firmware does not offer. Letting the firmware do AWDL
sidesteps that entirely.

## Not done yet
1. Announcing ourselves (our hostname / service records in our own sync frames) so Apple
   devices list the Linux machine.
2. The data path over `awdl0` (peer entries via `awdl_peer_op`, IPv6 link-local, mDNS).
3. The AirDrop application protocol on top — [OpenDrop](https://github.com/seemoo-lab/opendrop)
   already implements it and should sit on `awdl0`.

## Layout
| file | purpose |
|---|---|
| `brcmfmac-awdl.patch` | kernel patch (against 7.2.4, ISC like brcmfmac): AWDL interface role, `awdl0` netdev, vendor events |
| `build-install.sh` | fetches the brcm80211 tree for your kernel, applies the patch, builds, installs under `/lib/modules/$(uname -r)/updates/awdl` |
| `brcmiovar.py` | dependency-free Python: raw Broadcom iovars/dcmds via brcmfmac's nl80211 vendor command, incl. bsscfg-scoped (`-b N`) |
| `awdl-up.sh` / `awdl-down.sh` | create + configure + enable AWDL; disable |
| `awdlevents.py` | stream and decode the vendor events (AW windows, role, action frame TX/RX) |
| `awdlparse.py` | decode received AWDL action frames (sync/election params, ARPA hostname, version, services) |
| `iovars-awdl.txt`, `run-probe.sh` | probe which AWDL iovars a firmware has |
| `NOTES.md` | everything learned: iovar names and payload layouts, event codes, enable sequence, gotchas |

## Quick start (root, patched driver loaded)
```
sudo ./build-install.sh            # once; then reload brcmfmac (drops Wi-Fi ~10 s)
sudo ./awdl-up.sh                  # awdl0 appears, firmware starts AWDL
sudo ./awdlevents.py -v | tee events.log   # watch; put an iPhone/Mac with AirDrop "Everyone" nearby
python3 awdlparse.py events.log    # who did we hear?
sudo ./awdl-down.sh
```
**While AWDL is on, normal Wi-Fi throughput drops** — the radio time-shares between your
access point's channel and the AWDL social channels (6 and 44). Apple has the same trade-off.
A dense channel sequence can make Wi-Fi unusable; `awdl-up.sh` uses Apple's sparse pattern.

## How it was worked out
Iovar names, payload sizes and the enable sequence come from studying how Apple's own
Broadcom driver talks to the firmware, cross-checked against Broadcom struct definitions
that exist in vendor GPL source drops, and then probed live against the firmware
(`bcmerror`/`bcmerrorstr` tell you whether an iovar exists and what it disliked).
Protocol details follow Stute et al., *One Billion Apples' Secret Sauce* (MobiCom 2018)
and the OWL/OpenDrop projects. No Apple or Broadcom code is included here.

## Other Macs
Any Mac whose Wi-Fi is Broadcom + Apple firmware on `brcmfmac` should have the same
firmware features (check `sudo ./brcmiovar.py getstr cap 2048` for `awdl`). Apple-silicon
Macs on Asahi Linux use the same driver family; untested. Interface name (`-i`), bsscfg index
and channels are parameters of the scripts.

## License
ISC. The kernel patch modifies ISC-licensed brcmfmac sources and keeps that license.
AirDrop, AWDL and the device names are Apple trademarks; this project is not affiliated
with or endorsed by Apple or Broadcom.
