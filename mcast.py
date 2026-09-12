#!/usr/bin/env python3
"""Make sure the mDNS multicast groups are in the AWDL bsscfg's firmware multicast
filter. Apple's driver does exactly this: setMulticastList() appends a hardcoded
'awdl_bonjour_addr' to the list it programs on the AWDL virtual interface (and turns
allmulti off). brcmfmac only programs the groups the netdev has joined, so if nothing
on awdl0 has joined ff02::fb yet the firmware filters the peer's mDNS away. Root."""
import socket, struct, sys
from brcmiovar import GenlSock

EXTRA = ["33:33:00:00:00:fb",  # IPv6 mDNS  (ff02::fb)
         "01:00:5e:00:00:fb",  # IPv4 mDNS  (224.0.0.251)
         "33:33:00:00:00:02"]  # all-routers, harmless, keeps parity with Apple's list


def main(iface="wlp229s0", cfg=2):
    g = GenlSock(); g.bsscfg = cfg
    idx = socket.if_nametoindex(iface)
    cur = g.get_var(idx, "mcast_list", 1024)
    n = struct.unpack_from("<I", cur, 0)[0]
    addrs = [cur[4 + 6 * i:10 + 6 * i] for i in range(min(n, 32))]
    for e in EXTRA:
        b = bytes.fromhex(e.replace(":", ""))
        if b not in addrs:
            addrs.append(b)
    blob = struct.pack("<I", len(addrs)) + b"".join(addrs)
    g.set_var(idx, "mcast_list", blob)
    g.set_var(idx, "allmulti", struct.pack("<I", 1))
    print("mcast_list: %d groups (%s)" % (len(addrs), " ".join(a.hex(":") for a in addrs)))


if __name__ == "__main__":
    main(*sys.argv[1:])
