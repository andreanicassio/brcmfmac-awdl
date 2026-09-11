#!/usr/bin/env python3
"""Listen for brcmfmac vendor events (raw AWDL firmware events) on the nl80211
'vendor' multicast group and decode them. Run as root (or with the group
readable). Usage: awdlevents.py [-v]"""
import os, socket, struct, sys, time
from brcmiovar import (nla, parse_nlas, GenlSock, NETLINK_GENERIC, GENL_ID_CTRL,
                       CTRL_CMD_GETFAMILY, CTRL_ATTR_FAMILY_NAME, NL80211_CMD_VENDOR,
                       NL80211_ATTR_VENDOR_ID, NL80211_ATTR_VENDOR_SUBCMD,
                       NL80211_ATTR_VENDOR_DATA, NL80211_ATTR_IFINDEX, BROADCOM_OUI)

CTRL_ATTR_MCAST_GROUPS = 7
CTRL_ATTR_MCAST_GRP_NAME = 1
CTRL_ATTR_MCAST_GRP_ID = 2
NETLINK_ADD_MEMBERSHIP = 1
BRCMF_NLATTR_FWEVENT_HDR = 3
BRCMF_NLATTR_FWEVENT_DATA = 4

EVNAMES = {0: "SET_SSID", 54: "IF", 59: "ACTION_FRAME", 60: "ACTION_FRAME_COMPLETE",
           70: "ACTION_FRAME_OFF_CHAN_COMPLETE", 75: "ACTION_FRAME_RX",
           96: "AWDL_AW", 97: "AWDL_ROLE", 98: "AWDL_EVENT", 111: "AWDL_AW_EXT_END",
           112: "AWDL_AW_EXT_START", 113: "AWDL_AW_START", 114: "AWDL_RADIO_OFF",
           115: "AWDL_PEER_STATE", 116: "AWDL_SYNC_STATE_CHANGED", 117: "AWDL_CHIP_RESET",
           118: "AWDL_INTERLEAVED_SCAN_START", 119: "AWDL_INTERLEAVED_SCAN_STOP",
           120: "AWDL_PEER_CACHE_CONTROL"}
AWDL_EVENT_SUB = {0: "SCAN_STATUS", 1: "RX_ACT_FRAME", 2: "RX_PRB_RESP", 3: "PHYCAL_STATUS",
                  4: "WOWL_NULLPKT", 5: "OOB_AF_STATUS", 7: "PEER_STATE", 8: "INTERFACE_STATE",
                  9: "UCAST_AF_TXSTATUS", 12: "SD_DISCOVERY_RESULT", 13: "SD_REPLIED",
                  14: "SD_TERMINATED", 15: "SD_RECEIVE", 16: "SD_VNDR_IE",
                  17: "SD_DEVICE_STATE_IE", 18: "DFSP_NOTIF", 19: "DFSP_SUSPECT", 20: "DFSP_RESUME"}


def mcast_group_id(g, family=b"nl80211", group=b"vendor"):
    seq = g._send(GENL_ID_CTRL, CTRL_CMD_GETFAMILY, nla(CTRL_ATTR_FAMILY_NAME, family + b"\0"))
    err, pl = g._recv(seq)
    attrs = parse_nlas(pl[0][4:])
    for grp in parse_nlas(attrs[CTRL_ATTR_MCAST_GROUPS][0]).values():
        for item in grp:
            a = parse_nlas(item)
            if a[CTRL_ATTR_MCAST_GRP_NAME][0].rstrip(b"\0") == group:
                return struct.unpack("=I", a[CTRL_ATTR_MCAST_GRP_ID][0])[0]
    raise RuntimeError("no %s group" % group)


def hexs(b, n=64):
    return b[:n].hex() + ("..." if len(b) > n else "")


def decode(hdr, data, verbose):
    code, status, reason, flags, ifidx, bsscfg = struct.unpack_from("<6I", hdr)
    addr = hdr[24:30]
    dlen = struct.unpack_from("<H", hdr, 30)[0]
    name = EVNAMES.get(code, str(code))
    extra = ""
    if code == 98 and len(data) >= 4:  # AWDL_EVENT: subtype in first u32? (guess)
        sub = struct.unpack_from("<I", data)[0]
        extra = " sub=%s" % AWDL_EVENT_SUB.get(sub, sub)
    if code == 75:
        # brcmf_rx_mgmt_data { u16 version; u16 chanspec; s32 rssi; u32 mactime; u32 rate; } then frame
        # struct brcmf_rx_mgmt_data { __be16 version; __be16 len; __be16 chanspec; __be32 rssi; __be32 mactime; __be32 rate; }
        ver, ln, chspec, rssi = struct.unpack_from(">HHHi", data)
        frame = data[16:]
        extra = " chanspec=0x%04x rssi=%d frame[%d]=%s" % (chspec, rssi, len(frame), frame.hex())
        data = b""
    print("%s %-26s st=%d rs=%d fl=0x%x if=%d cfg=%d %s len=%d%s%s" % (
        time.strftime("%H:%M:%S"), name, status, reason, flags, ifidx, bsscfg,
        addr.hex(":"), dlen, extra, (" data=" + hexs(data)) if data and (verbose or code != 96) else ""))


def main():
    verbose = "-v" in sys.argv
    g = GenlSock()
    gid = mcast_group_id(g)
    g.s.setsockopt(270, NETLINK_ADD_MEMBERSHIP, gid)  # SOL_NETLINK = 270
    print("listening on nl80211 vendor group %d (brcmfmac OUI %06x)" % (gid, BROADCOM_OUI), flush=True)
    while True:
        buf = g.s.recv(65536)
        off = 0
        while off + 16 <= len(buf):
            ln, typ, fl, seq, pid = struct.unpack_from("=IHHII", buf, off)
            body = buf[off + 16: off + ln]
            off += (ln + 3) & ~3
            if typ != g.nl80211 or body[0] != NL80211_CMD_VENDOR:
                continue
            attrs = parse_nlas(body[4:])
            if struct.unpack("=I", attrs[NL80211_ATTR_VENDOR_ID][0])[0] != BROADCOM_OUI:
                continue
            vd = parse_nlas(attrs[NL80211_ATTR_VENDOR_DATA][0])
            hdr = vd.get(BRCMF_NLATTR_FWEVENT_HDR, [b""])[0]
            data = vd.get(BRCMF_NLATTR_FWEVENT_DATA, [b""])[0]
            if len(hdr) >= 32:
                decode(hdr, data, verbose)
            sys.stdout.flush()


if __name__ == "__main__":
    main()
