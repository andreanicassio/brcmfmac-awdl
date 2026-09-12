#!/usr/bin/env python3
"""Add an AWDL peer to the firmware peer table the way Apple's driver does.

Apple's AppleBCMWLANProximityInterface::setPEER_CACHE_CONTROL builds

    u8  version = 0
    u8  opcode  (0 = add, 1 = del)
    u8  addr[6]
    u8  mode    (bit0 = A-MPDU capable, bit2 = HE capable)
    <peer's HT (id 45) / VHT (id 191) / HE (id 255 ext 35) capability IEs, verbatim>
    <vendor IE: dd <len> 00 17 f2 08 12 <count-1> <enc> <dup> <step> ff ff <chanspecs>>

i.e. the firmware needs the peer's PHY capabilities *and* its channel sequence to
schedule traffic to it.  The capability IEs and the channel sequence both come
straight out of the peer's MIF/PSF action frame (TLV 17 = IEEE80211 container,
TLV 18 = channel sequence), which awdlevents.py logs for us.
"""
import re, socket, struct, sys
from brcmiovar import GenlSock

OPCLASS_2G = (81, 82, 83, 84)


def chanspec(chan, opclass):
    """D11AC chanspec for one channel-sequence slot (0 = slot not used)."""
    if not chan:
        return 0
    if opclass in OPCLASS_2G or chan <= 14:
        return 0x1000 | chan                      # 2 GHz, 20 MHz
    return 0xC000 | 0x1000 | chan                 # 5 GHz, 20 MHz (primary channel)


def parse_af(frame):
    """Return {tlv_type: value} of an AWDL action frame body."""
    if frame[:4] != b"\x7f\x00\x17\xf2" or frame[4] != 8:
        return None
    out, off = {}, 16
    while off + 3 <= len(frame):
        t, l = frame[off], struct.unpack_from("<H", frame, off + 1)[0]
        out.setdefault(t, frame[off + 3:off + 3 + l])
        off += 3 + l
    return out


def frames_from_log(path):
    """Newest action frame per (src, subtype) from an awdlevents.py log."""
    out = {}
    for line in open(path, errors="replace"):
        m = re.search(r"ACTION_FRAME_RX .* (\S+) len=\d+ chanspec=0x\w+ rssi=-?\d+ "
                      r"frame\[\d+\]=([0-9a-f]+)", line)
        if m:
            out[(m.group(1), bytes.fromhex(m.group(2))[6])] = bytes.fromhex(m.group(2))
    return out


def build(addr, tlvs, opcode=0, mode=None):
    caps = tlvs.get(17, b"")                       # HT/VHT/HE capability IEs verbatim
    if mode is None:
        # bit0 A-MPDU (HT/VHT peers do A-MPDU), bit2 HE (only if an HE cap IE is there)
        mode = (1 if caps else 0) | (4 if b"\xff" in caps[:1] else 0)
    buf = bytearray([0, opcode]) + bytearray(addr) + bytes([mode])
    if opcode != 0:
        return bytes(buf)
    buf += caps
    cs = tlvs.get(18)
    if cs and len(cs) >= 6:
        count, enc, dup, step = cs[0], cs[1], cs[2], cs[3]
        body = cs[6:]
        n = count + 1
        size = len(body) // n if n else 0
        chans = []
        for i in range(n):
            if size == 2:
                chans.append(chanspec(body[2 * i], body[2 * i + 1]))
            elif size == 1:
                chans.append(chanspec(body[i], 0))
        ie = bytearray([18, count, max(enc - 1, 0), dup, step, 0xff, 0xff])
        for c in chans:
            ie += struct.pack(">H", c)
        buf += bytes([0xdd, len(ie) + 4, 0x00, 0x17, 0xf2, 0x08]) + ie
    return bytes(buf)


def apply(iface, cfg, blob):
    g = GenlSock(); g.bsscfg = cfg
    g.set_var(socket.if_nametoindex(iface), "awdl_peer_op", blob)


if __name__ == "__main__":
    log = sys.argv[1] if len(sys.argv) > 1 else "events.log"
    iface, cfg = "wlp229s0", 2
    ours = open("/sys/class/net/awdl0/address").read().strip()
    frames = frames_from_log(log)
    peers = {}
    for (src, sub), f in frames.items():
        if src == ours:
            continue
        t = parse_af(f)
        if t:
            peers.setdefault(src, {}).update({k: v for k, v in t.items() if k not in peers.get(src, {})})
            if sub == 3:                            # MIF carries the richest TLV set
                peers[src].update(t)
    if not peers:
        print("no peer action frames in %s" % log); sys.exit(2)
    for src, tlvs in peers.items():
        addr = bytes.fromhex(src.replace(":", ""))
        blob = build(addr, tlvs)
        try:
            apply(iface, cfg, blob)
            print("peer %s added, %d bytes: %s" % (src, len(blob), blob.hex()))
        except OSError as e:
            print("peer %s FAILED (%s), %d bytes: %s" % (src, e, len(blob), blob.hex()))
            for variant, b in (("hdr+caps", blob[:9 + len(tlvs.get(17, b""))]),
                               ("hdr only", blob[:9])):
                try:
                    apply(iface, cfg, b)
                    print("   fallback %s accepted (%d bytes)" % (variant, len(b))); break
                except OSError as e2:
                    print("   fallback %s failed (%s)" % (variant, e2))
