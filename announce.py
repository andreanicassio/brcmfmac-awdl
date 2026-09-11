#!/usr/bin/env python3
"""Build the host TLV blob (data path state, ARPA hostname, version) and hand it to the
firmware's sync-frame template iovar (awdl_payload = u16 len + TLVs). Root."""
import socket, struct, subprocess, sys
from brcmiovar import GenlSock

def tlv(t, v): return bytes([t]) + struct.pack("<H", len(v)) + v

def build(name, awdl_mac, master_chan=44, version=0x10, devclass=1):
    # data path state (OWL layout): flags, country, social channels, awdl addr, ext flags
    social = 0x0002 if master_chan == 44 else 0x0001   # bit1 = ch44, bit0 = ch6 (OWL enum)
    dps = struct.pack("<H", 0x8f24) + b"X0\0" + struct.pack("<H", social) + awdl_mac + struct.pack("<H", 0)
    arpa = bytes([3, len(name)]) + name.encode() + b"\xc0\x0c"
    ver = bytes([version, devclass])
    return tlv(12, dps) + tlv(16, arpa) + tlv(21, ver)

if __name__ == "__main__":
    iface, cfg = "wlp229s0", 2
    name = sys.argv[1] if len(sys.argv) > 1 else socket.gethostname()
    awdl_mac = bytes.fromhex(open("/sys/class/net/awdl0/address").read().strip().replace(":", ""))
    blob = build(name, awdl_mac)
    g = GenlSock(); g.bsscfg = cfg
    ifindex = socket.if_nametoindex(iface)
    payload = struct.pack("<H", len(blob)) + blob
    g.set_var(ifindex, "awdl_payload", payload)
    print("awdl_payload set: %d bytes (%s)" % (len(blob), blob.hex()))
