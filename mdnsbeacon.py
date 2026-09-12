#!/usr/bin/env python3
"""Repeat our own _airdrop._tcp mDNS announcement on awdl0 at a steady rate.

Why this exists: an Apple peer is only on our channel in a few of the 16 AWDL
availability-window slots, and it only listens while its AWDL data path is awake,
so a service announcement has to be *repeated* to be heard at all. python-zeroconf
(inside OpenDrop) announces three times in the first two seconds and then goes
quiet, which on AWDL is close to never.

Rather than rebuild the records by hand, this sniffs the announcement OpenDrop
actually sends (an mDNS response mentioning _airdrop._tcp) and re-multicasts the
exact same DNS payload to ff02::fb:5353 every INTERVAL seconds. Root.
"""
import argparse, socket, struct, sys, time

ETH_P_ALL = 3
MDNS6 = "ff02::fb"


def find_announcement(iface, timeout):
    """Sniff our own outgoing mDNS response that carries _airdrop._tcp."""
    s = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(ETH_P_ALL))
    s.bind((iface, 0))
    s.settimeout(1.0)
    ours = bytes.fromhex(open("/sys/class/net/%s/address" % iface).read().strip().replace(":", ""))
    end = time.time() + timeout
    while time.time() < end:
        try:
            pkt = s.recv(4096)
        except socket.timeout:
            continue
        if len(pkt) < 62 or pkt[6:12] != ours:
            continue
        i = pkt.find(b"\x86\xdd", 12)
        if i < 0 or i > 40:
            continue
        ip6 = pkt[i + 2:]
        if ip6[6] != 17:                       # UDP
            continue
        udp = ip6[40:]
        if struct.unpack_from(">H", udp, 2)[0] != 5353:
            continue
        dns = udp[8:8 + struct.unpack_from(">H", udp, 4)[0] - 8]
        if len(dns) < 12 or not (struct.unpack_from(">H", dns, 2)[0] & 0x8000):
            continue                            # want a response, not a query
        if b"_airdrop" in dns:
            return dns
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-i", "--iface", default="awdl0")
    ap.add_argument("-n", "--interval", type=float, default=1.5)
    ap.add_argument("-w", "--wait", type=float, default=30, help="seconds to wait for OpenDrop's announcement")
    ap.add_argument("-d", "--duration", type=float, default=0, help="0 = forever")
    a = ap.parse_args()

    dns = find_announcement(a.iface, a.wait)
    if not dns:
        print("mdnsbeacon: no _airdrop announcement seen on %s in %gs" % (a.iface, a.wait))
        return 2
    print("mdnsbeacon: replaying %d-byte announcement every %gs" % (len(dns), a.interval))

    idx = socket.if_nametoindex(a.iface)
    s = socket.socket(socket.AF_INET6, socket.SOCK_DGRAM)
    s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_MULTICAST_IF, idx)
    s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_MULTICAST_HOPS, 255)
    s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_MULTICAST_LOOP, 0)
    # RFC 6762 6: an mDNS response MUST come from UDP source port 5353. Apple's
    # mDNSResponder silently ignores multicast "responses" sent from an ephemeral
    # port, so share port 5353 with the zeroconf instance inside OpenDrop.
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
    except OSError:
        pass
    try:
        s.bind(("::", 5353))
    except OSError as e:
        print("mdnsbeacon: cannot bind port 5353 (%s); responses will be ignored by Apple peers" % e)
        s.bind(("::", 0))
    end = time.time() + a.duration if a.duration else None
    n = 0
    while end is None or time.time() < end:
        try:
            s.sendto(dns, (MDNS6, 5353, 0, idx))
            n += 1
        except OSError as e:
            print("mdnsbeacon: send failed: %s" % e)
        time.sleep(a.interval)
    print("mdnsbeacon: sent %d announcements" % n)
    return 0


if __name__ == "__main__":
    sys.exit(main())
