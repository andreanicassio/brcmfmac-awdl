#!/usr/bin/env python3
"""AirDrop mDNS responder for awdl0 (root). Captures OpenDrop's own _airdrop._tcp
announcement, then (a) re-multicasts it every INTERVAL s from UDP port 5353 (RFC 6762:
Apple ignores responses from other ports) and (b) watches every incoming mDNS query on the
interface: any query from another device that mentions _airdrop is answered immediately
with the full announcement, UNICAST to the querier's link-local address AND multicast.
Unicast to the peer goes through the firmware's per-peer path, unlike multicast."""
import argparse, socket, struct, sys, time, select
sys.path.insert(0, __import__("os").path.dirname(__file__))
from mdnsbeacon import find_announcement, MDNS6, ETH_P_ALL

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-i", "--iface", default="awdl0"); ap.add_argument("-n", "--interval", type=float, default=1.5)
    ap.add_argument("-w", "--wait", type=float, default=30); ap.add_argument("-d", "--duration", type=float, default=0)
    a = ap.parse_args()
    dns = find_announcement(a.iface, a.wait)
    if not dns: print("responder: no announcement seen"); return 2
    idx = socket.if_nametoindex(a.iface)
    ours = bytes.fromhex(open("/sys/class/net/%s/address" % a.iface).read().strip().replace(":", ""))
    tx = socket.socket(socket.AF_INET6, socket.SOCK_DGRAM)
    tx.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_MULTICAST_IF, idx)
    tx.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_MULTICAST_HOPS, 255)
    tx.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_UNICAST_HOPS, 255)
    tx.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_MULTICAST_LOOP, 0)
    tx.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try: tx.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
    except OSError: pass
    try: tx.bind(("::", 5353)); port = 5353
    except OSError as e: tx.bind(("::", 0)); port = tx.getsockname()[1]; print("responder: WARNING bound to %d not 5353 (%s)" % (port, e))
    sn = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(ETH_P_ALL)); sn.bind((a.iface, 0)); sn.setblocking(False)
    print("responder: %d-byte announcement, source port %d, multicast every %gs + unicast on query" % (len(dns), port, a.interval), flush=True)
    end = time.time() + a.duration if a.duration else None; last = 0; nmc = nuc = 0; seen = {}
    while end is None or time.time() < end:
        now = time.time()
        if now - last >= a.interval:
            try: tx.sendto(dns, (MDNS6, 5353, 0, idx)); nmc += 1
            except OSError as e: print("responder: mcast send failed: %s" % e, flush=True)
            last = now
        r, _, _ = select.select([sn], [], [], 0.2)
        if not r: continue
        try: pkt = sn.recv(4096)
        except OSError: continue
        if len(pkt) < 62 or pkt[6:12] == ours: continue
        i = pkt.find(b"\x86\xdd", 12)
        if i < 0 or i > 40: continue
        ip6 = pkt[i + 2:]
        if ip6[6] != 17: continue
        src = socket.inet_ntop(socket.AF_INET6, ip6[8:24]); udp = ip6[40:]
        if struct.unpack_from(">H", udp, 2)[0] != 5353: continue
        q = udp[8:]
        if len(q) < 12 or (struct.unpack_from(">H", q, 2)[0] & 0x8000): continue   # queries only
        if b"_airdrop" not in q and b"andrea-ubuntu-mac" not in q: continue
        sport = struct.unpack_from(">H", udp, 0)[0]
        # legacy-unicast query (source port != 5353) gets a plain DNS response; else mDNS response
        resp = dns if sport == 5353 else struct.pack(">H", struct.unpack_from(">H", q, 0)[0]) + dns[2:]
        try:
            tx.sendto(resp, (src, sport, 0, idx)); tx.sendto(dns, (MDNS6, 5353, 0, idx)); nuc += 1
            k = src
            if seen.get(k, 0) + 5 < now:
                seen[k] = now; print("%s responder: query from %s (sport %d) -> unicast+mcast answer" % (time.strftime("%H:%M:%S"), src, sport), flush=True)
        except OSError as e: print("responder: unicast send to %s failed: %s" % (src, e), flush=True)
    print("responder: sent %d multicast, %d query-triggered answers" % (nmc, nuc)); return 0

if __name__ == "__main__": sys.exit(main())
