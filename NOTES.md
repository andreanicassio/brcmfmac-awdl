# AWDL on Linux via the Broadcom firmware's built-in AWDL (BCM4364, MacBookPro16,2)

Goal: make AirDrop-compatible AWDL work on this T2 MacBook by driving the AWDL
engine that already lives in the Apple-supplied Broadcom firmware, instead of
reimplementing AWDL in software (OWL) which needs monitor/injection that
brcmfmac cannot provide.

## Hardware / software state (2026-09-11)
- Chip: BCM4364 rev 4 (PCI 14e4:4464), driver brcmfmac, kernel 7.2.4-1-t2-noble.
- Firmware loaded: brcm/brcmfmac4364b3-pcie (Apple "bali/borneo/kahana/kure/hanauma/trinidad"
  variants are one identical 820013-byte file), version 9.30.503.0.32.5.92, FWID 01-c06f991b,
  built 2023-07-10, "4364b3-roml/config_pcie_release_sdb_udm".
- "roml" = most code is in on-chip ROM; the .bin is only the RAM patch layer. That is why
  `strings` on the .bin shows only 6 awdl symbols (awdl_doiovar_patch, wlc_awdl_attach,
  wlc_awdl_aw_set, awdl_psf_dwell...). The AWDL module is there, in ROM, patched by RAM.
- brcmfmac has no debug build (CONFIG_BRCMDBG unset) but CONFIG_BRCM_TRACING=y.
- No macOS partition on the disk, so no local kext to mine.

## How to talk to the firmware from userspace
brcmfmac exposes a raw dcmd/iovar channel via the nl80211 vendor command
(OUI 0x001018, subcmd 1, BRCMF_VNDR_CMDS_DCMD). `brcmiovar.py` implements it in pure
Python (genetlink by hand). Needs CAP_NET_ADMIN:

    sudo ./brcmiovar.py getstr ver
    sudo ./brcmiovar.py getstr cap 2048
    sudo ./brcmiovar.py probefile iovars-awdl.txt      # or ./run-probe.sh

Kernel maps every firmware error to -EBADE, so the tool reads back `bcmerror` /
`bcmerrorstr` after a failure to distinguish UNSUPPORTED (iovar absent) from
BADARG/NOTUP (iovar present, wrong args or state).

## What Apple's driver does (from the decompiled iOS 26 AppleBCMWLAN dext, ref/ios26-AppleBCMWLAN-dext)
Split of work:
- Firmware: AW (availability window) timing, channel hopping, TSF sync, election tree
  bookkeeping, sending PSF/MIF action frames at the right time, peer table, power save.
- Host (IO80211Family / AppleBCMWLANProximityInterface): parses received action frames
  (delivered as events), maintains the AWDL state machine, decides the channel sequence,
  election params, and pushes them down with iovars. Service discovery (mDNS) and the
  AirDrop HTTPS stack are pure userspace on top of the awdl0 netdev.
So a Linux port = (a) brcmfmac plumbing + (b) an OWL-like userspace daemon that no longer
needs raw frames.

### Bring-up sequence observed (createChipInterface / bringupLink / setInterfaceEnable)
1. `awdl_if` (SET on the primary interface, 20 bytes = wl_awdl_if2_t):
   int32 cfg_idx; int32 up(=1); ether_addr bssid; ether_addr if_addr.
   Firmware creates a new bsscfg and answers with a WLC_E_IF event (54) carrying
   role WLC_E_IF_ROLE_AWDL = 7 (bsscfg idx + ifidx); Apple waits for that event.
2. Subsequent iovars are "virtual" = issued on the new AWDL bsscfg (bsscfg-indexed
   iovar "bsscfg:<name>" style, or ifidx of the new interface).
   - `awdl_config`      4 bytes      (iOS: uint32; old awdl_config_params_t was larger)
   - `awdl_af_hdr`      10 bytes     (action frame header: ether_addr dst + oui?)
   - `awdl_af_rssi`     4 bytes
   - `awdl_sync_params` 36 bytes     (awdl_sync_params_t: aw_period, guard, master chan, ...)
   - `awdl_chan_seq`    variable     (awdl_channel_sequence_t: seq len/enc/step + channels)
   - `awdl_election_tree` 42 bytes   (election tree info / metric / rssi thresholds)
   - `awdl_opmode`      28 bytes     (mode auto/fixed, role, master addr)
   - `awdl_extcounts`   4 bytes      (awdl_extcount_t)
   - `awdl_presencemode` 4 bytes
   - `awdl_aftxmode`    4 bytes      (AWDL_AFTXMODE_*: where to send AFs outside AW)
   - `awdl_psf_dwell`   8 bytes
   - `awdl_dfsp_cfg`    20 bytes, `awdl_dfsp_ucsa` 12 bytes (DFS proxy)
   - `awdl_osoc_chan`   4 bytes, `awdl_min_rate` 4, `awdl_phycal_period` 4, `awdl_maxpeers` 4
   - `awdl` = 1         4 bytes      -> enable. Then setAfTxMode.
3. Runtime:
   - TX action frame: `awdl_oob_af` (awdl_oob_af_params_t, flags to let fw fill TSF /
     sync / election params), `awdl_oob_af_auto` (46 bytes) for periodic ones.
   - RX action frames arrive as firmware events (WLC_E_ACTION_FRAME_RX = 75 ->
     handleActionFrame_rx; WLC_E_ACTION_FRAME_COMPLETE = 60 -> tx status).
     brcmfmac ALREADY turns event 75 into cfg80211 mgmt-rx for P2P; that path may be
     reusable to hand AWDL PSF/MIF frames to userspace via nl80211.
   - Peers: `awdl_peer_op` (add/del/info/upd, AWDL_PEER_OP_*), `awdl_advertisers` (get, 1000 B).
   - Events: WLC_E_AWDL_AW 96 (AW start, awdl_aws_event_data_t), WLC_E_AWDL_ROLE 97,
     WLC_E_AWDL_EVENT 98 (subtypes: RX_ACT_FRAME 1, OOB_AF_STATUS 5, PEER_STATE 7,
     INTERFACE_STATE 8, ...), 111-120 AW_EXT_END/START, AW_START, PEER_STATE,
     SYNC_STATE_CHANGED, ... (see ref/bcmevent_*.h).
   - Data path: normal 802.3 frames on the AWDL bsscfg's ifidx (msgbuf flowrings),
     firmware queues them for the peer's next AW. Apple uses LLC/SNAP + Apple OUI
     for AWDL data (OWL knows the format).

## What brcmfmac lacks (the actual porting work)
1. Event 54 (WLC_E_IF) with role 7: brcmfmac only knows roles 0-4; it creates an ifp for
   an unsolicited IF_ADD but hands it to cfg80211's vif-add path, so no netdev appears.
   Need: recognise ROLE_AWDL, create a netdev (e.g. as NL80211_IFTYPE_OCB or a vendor
   type) and attach it (brcmf_net_attach).
2. Forward AWDL events (96-98, 111-120) to userspace (vendor events via nl80211).
3. Let userspace issue bsscfg-scoped iovars: vendor dcmd already takes the wdev/netdev,
   so once the awdl netdev exists, `brcmiovar.py -i awdl0 ...` should hit the right bsscfg.
4. RX action frames: reuse brcmf_p2p_notify_action_frame_rx -> cfg80211_rx_mgmt on the
   awdl netdev, gated by mgmt frame registration.
5. Firmware may refuse `awdl_if` unless the interface is up and possibly needs the
   Apple-specific "apple,..." NVRAM (already loaded). Unknown until probed.

## Results so far (2026-09-11 evening)
- `cap` lists `awdl`. Nearly every AWDL iovar from the iOS driver exists (probe list in
  iovars-awdl.txt); absent: awdl_oob_af, awdl_oob_af_auto, awdl_ranging*, awdl_aes_key,
  awdl_peer_stats, awdl_extcount (old name), membytes.
- `awdl_if` (20 B, cfg_idx=2, up=1, bssid 00:25:00:ff:94:73, if_addr) -> firmware emits
  WLC_E_IF ADD role 7 + IF_CHANGE. Patched brcmfmac (brcmfmac-awdl.patch, installed in
  /lib/modules/$(uname -r)/updates/awdl/) creates **awdl0** (iftype OCB) and it comes UP.
- Bsscfg-scoped iovars work from the primary netdev with the "bsscfg:" prefix (brcmiovar.py -b 2).
- Accepted formats (this firmware, 9.30.503.0.32.5.92):
  - awdl_sync_params 36 B: only master_chan@6, aw_period@8 (16), af_period@10 (110),
    aw_ext_len@14 (16), aw_cmn_len@16 (16) matter; firmware fills flags 0x3800 itself.
  - awdl_chan_seq: header {count-1, enc, dup, step, fill u16} + 16 slots. enc=0 -> 1-byte
    channel numbers (0 = stay on infra channel); enc=2 -> big-endian D11AC chanspecs
    (5 GHz 20 MHz ch44 = 0xd02c, 2.4 GHz ch6 = 0x1006). enc 1/3/4/5 rejected.
  - awdl_config = 115 (u32), awdl_af_rssi = -60 (Apple) — `awdl 1` returns BADOPTION until
    awdl_config is set. awdl_af_hdr already defaults to ff.. / 0x7f / 00:17:f2.
  - `awdl 1` then succeeds: AWDL_ROLE event (status 2 = master), AWDL_AW events every
    availability window (~40/s), ACTION_FRAME_COMPLETE status 5 (no-ack, broadcast PSF/MIF)
    -> the firmware is transmitting sync frames on its own.
- **Wi-Fi caveat:** a channel sequence with all 16 slots on 44/6 while the AP is on ch 40
  kept the radio off the AP's channel almost continuously and made the Wi-Fi link unusable
  (user had to plug in Ethernet). awdl-up.sh now uses Apple's sparse pattern
  [44 0 0 0 0 0 0 0 6 44 44 0 0 0 0 0]; still expect reduced throughput while AWDL is on.
  awdl-down.sh disables it.
- **Peer discovery works (23:50):** with an iPad (iOS, AWDL v10.0) in AirDrop "Everyone" mode next to
  the laptop, the firmware delivered ~100 action frames in 30 s (ACTION_FRAME_RX events on awdl0,
  MIF + PSF, on channels 44/6/40), AWDL_ROLE went master(2) -> slave(1), i.e. the firmware
  synchronised to the iPad as master, and `awdl_advertisers` lists the iPad's AWDL MAC.
  `awdlparse.py events.log` decodes the TLVs: hostname (<uuid>.local), version/device class,
  sync + election params, service responses (device name, _airdrop-like services).

- **Host payload:** `awdl_payload` = u16 length + raw TLV blob (Apple calls it the sync frame
  template); the firmware appends it to its PSF/MIF. Accepted 47 B of {data path state,
  ARPA hostname, version} (announce.py). `awdl_afs_pload` is the on-demand secondary payload.
- **Peer table:** old-format `awdl_peer_op` {u8 version=0, u8 opcode (0 add/1 del/2 info/3 upd),
  ether_addr, u8 mode} is accepted (version=1 -> BADARG). The iOS driver sends a 0x1d0-byte
  cache-control blob instead.
- **What the iPad announces** (MIF): sync/election/chanseq (firmware-level), data path state
  (47 B extended layout, flags 0x9f23, infra channel 40), version 0xa0 = 10.0 iOS, ARPA
  <uuid>.local, service params, service responses only for `_applicationservicepairing` and
  `_appsvcprepair` (device name "<owner> iPad Mini"). **No `_airdrop._tcp` record in the
  frames**: AirDrop discovery is mDNS over the AWDL data path, so the data path is required.
- awdl0 data path: Linux side TX works (avahi + IPv6 ND go out, no errors); RX from the iPad
  not yet observed — first attempt ran after its 10-minute window expired. datapath-test.sh
  repeats the experiment (announce, add peer, ping6 link-local, mDNS query, capture).

## Scripts
- `sudo ./awdl-up.sh` / `sudo ./awdl-down.sh` — create/configure/enable, disable.
- `sudo ./awdlevents.py -v` — decoded stream of the vendor events (AW windows, role,
  action frame TX status/RX).
- `sudo ./brcmiovar.py [-b BSSCFG] get|getint|getstr|set|setint|probe ...` — raw iovars.
- Driver: `kernel/brcm80211/brcmfmac` (7.2.4 sources + patch), rebuild with
  `make -C /lib/modules/$(uname -r)/build M=$PWD modules`, install to
  /lib/modules/$(uname -r)/updates/awdl/ + `depmod -a`, reload `brcmfmac_wcc brcmfmac`
  (drops Wi-Fi for ~10 s). Remove the updates dir + depmod to go back to the stock driver.

## Next steps
1. Test with an iPhone/Mac with AirDrop set to "Everyone for 10 minutes" next to the laptop:
   expect ACTION_FRAME_RX events on awdl0 and entries in `awdl_advertisers`/`awdl_peer_op`.
2. Host side of the protocol: parse PSF/MIF TLVs (OWL's frame.c), add peers with
   awdl_peer_op, publish our own TLVs with awdl_payload / awdl_afs_pload
   (awdl_oob_af is absent here), keep election params via awdl_election_tree.
3. Data path: awdl0 is an Ethernet-like netdev; check flowring/peer handling in msgbuf for
   the OCB iftype, then mDNS (avahi on awdl0) and OpenDrop.

## References
- ref/ios26-AppleBCMWLAN-dext/   decompiled iOS 26.1 Broadcom DriverKit driver (GitHub
  EthanArbuckle/iPhone18-3_26.1_23B85_Restore) -- authoritative for current iovar names/sizes.
- ref/wlioctl_awdl_section.h    Broadcom struct definitions (FreshTomato router GPL drop).
- ref/bcmevent_*.h               firmware event codes incl. WLC_E_AWDL_*.
- ref/owl-paper-secret-sauce.txt Stute et al., MobiCom'18, AWDL protocol details.
- OWL (github.com/seemoo-lab/owl): userspace AWDL state machine to reuse; OpenDrop on top.
- brcmfmac vendor cmd: drivers/net/wireless/broadcom/brcm80211/brcmfmac/vendor.c
