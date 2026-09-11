#!/usr/bin/env python3
"""Decode AWDL action frames logged by awdlevents.py (events.log)."""
import re, struct, sys
TLV = {0:"SSTH_REQ",1:"SERVICE_REQ",2:"SERVICE_RESP",4:"SYNC_PARAMS",5:"ELECTION_PARAMS",6:"SERVICE_PARAMS",
       7:"EDR_CAPS",8:"EDR_OP",9:"INFRA",10:"INVITE",11:"DBG_STRING",12:"DATA_PATH_STATE",13:"ENCAP_IP",
       16:"ARPA",17:"IEEE80211_CNTNR",18:"CHAN_SEQ",20:"SYNC_TREE",21:"VERSION",22:"BLOOM",23:"NAN_SYNC",24:"ELECTION_V2"}
DEVCLASS = {1:"macOS", 2:"iOS", 8:"tvOS/watchOS?"}
def mac(b): return ":".join("%02x" % x for x in b)
def dns_name(v, off):
    labels = []
    while off < len(v):
        n = v[off]; off += 1
        if n == 0: break
        if n & 0xC0 == 0xC0:
            labels.append("local" if v[off] == 0x0c else "ptr%02x" % v[off]); off += 1; break
        labels.append(v[off:off+n].decode(errors="replace")); off += n
    return ".".join(labels), off
def decode(frame):
    if frame[:4] != b"\x7f\x00\x17\xf2" or frame[4] != 8: return None
    ver, sub = frame[5], frame[6]
    out = {"subtype": {0:"PSF",3:"MIF"}.get(sub, sub), "version": "%d.%d" % (ver >> 4, ver & 15)}
    off = 16
    while off + 3 <= len(frame):
        t, l = frame[off], struct.unpack_from("<H", frame, off+1)[0]; v = frame[off+3:off+3+l]; off += 3 + l
        name = TLV.get(t, "tlv%d" % t)
        if t == 4 and len(v) >= 40:
            out["sync"] = dict(tx_chan=v[0], tx_counter=struct.unpack_from("<H", v, 1)[0], master_chan=v[3],
                               aw_period=struct.unpack_from("<H", v, 5)[0], af_period=struct.unpack_from("<H", v, 7)[0],
                               flags="0x%04x" % struct.unpack_from("<H", v, 9)[0], master=mac(v[21:27]),
                               presence_mode=v[27], aw_seq=struct.unpack_from("<H", v, 29)[0])
            if len(v) >= 39 + 16:
                seqlen = v[37]+1 if len(v) > 37 else 0
        elif t == 5 and len(v) >= 21:
            out["election"] = dict(flags=v[0], id=struct.unpack_from("<H", v, 1)[0], dist=v[3],
                                   master=mac(v[5:11]), master_metric=struct.unpack_from("<I", v, 11)[0],
                                   self_metric=struct.unpack_from("<I", v, 15)[0])
        elif t == 24 and len(v) >= 40:
            out["election_v2"] = dict(master=mac(v[0:6]), sync_master=mac(v[6:12]),
                                      master_counter=struct.unpack_from("<I", v, 12)[0], dist=struct.unpack_from("<I", v, 16)[0],
                                      master_metric=struct.unpack_from("<I", v, 20)[0], self_metric=struct.unpack_from("<I", v, 24)[0],
                                      self_counter=struct.unpack_from("<I", v, 32)[0])
        elif t == 16 and len(v) >= 2:
            out["hostname"], _ = dns_name(v, 1)
        elif t == 21 and len(v) >= 2:
            out["awdl_version"] = "%d.%d %s" % (v[0] >> 4, v[0] & 15, DEVCLASS.get(v[1], "class%d" % v[1]))
        elif t == 12 and len(v) >= 2:
            out["datapath_flags"] = "0x%04x" % struct.unpack_from("<H", v, 0)[0]
            if len(v) >= 8: out["datapath_addr"] = mac(v[2:8])
        elif t == 6:
            out["service_params_len"] = len(v)
        elif t == 2 and len(v) >= 4:
            out.setdefault("services", []).append(v.hex()[:40])
        out.setdefault("tlvs", []).append(name)
    return out
if __name__ == "__main__":
    seen = {}
    for line in open(sys.argv[1] if len(sys.argv) > 1 else "events.log"):
        m = re.search(r"ACTION_FRAME_RX .* (\S+) len=\d+ chanspec=0x(\w+) rssi=(-?\d+) frame\[\d+\]=([0-9a-f]+)", line)
        if not m: continue
        src, chspec, rssi, hx = m.group(1), m.group(2), int(m.group(3)), bytes.fromhex(m.group(4))
        d = decode(hx)
        if not d: continue
        key = (src, d["subtype"])
        seen.setdefault(key, [0, None, []])
        seen[key][0] += 1; seen[key][1] = d; seen[key][2].append((chspec, rssi))
    for (src, sub), (n, d, chans) in seen.items():
        print("== %s %s x%d  (chanspec/rssi samples: %s)" % (src, sub, n, sorted(set(chans))[:6]))
        for k, v in d.items():
            if k != "tlvs": print("   %-18s %s" % (k, v))
        print("   tlvs: %s" % " ".join(d["tlvs"]))
