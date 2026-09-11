#!/usr/bin/env python3
"""Talk to Broadcom brcmfmac firmware from userspace via the nl80211 vendor
command (BRCMF_VNDR_CMDS_DCMD). Pure Python, no dependencies. Needs
CAP_NET_ADMIN (run with sudo).

Usage:
  brcmiovar.py [-i IFACE] [-b BSSCFGIDX] get NAME [LEN]   # WLC_GET_VAR
  brcmiovar.py [-i IFACE] getint NAME             # WLC_GET_VAR, decode int32
  brcmiovar.py [-i IFACE] getstr NAME [LEN]       # WLC_GET_VAR, decode C string
  brcmiovar.py [-i IFACE] setint NAME VALUE       # WLC_SET_VAR with int32
  brcmiovar.py [-i IFACE] set NAME HEXBYTES       # WLC_SET_VAR with raw bytes
  brcmiovar.py [-i IFACE] ioctl CMD [LEN] [HEX]   # raw dcmd (set if HEX given)
  brcmiovar.py [-i IFACE] probe NAME...           # test which iovars exist
  brcmiovar.py [-i IFACE] probefile FILE          # probe every name in FILE
"""
import os, socket, struct, sys, errno

# ---- netlink / genetlink constants ----
NETLINK_GENERIC = 16
NLMSG_ERROR = 2
NLMSG_DONE = 3
NLM_F_REQUEST = 1
NLM_F_ACK = 4
GENL_ID_CTRL = 0x10
CTRL_CMD_GETFAMILY = 3
CTRL_ATTR_FAMILY_ID = 1
CTRL_ATTR_FAMILY_NAME = 2

# nl80211 (from /usr/include/linux/nl80211.h)
NL80211_CMD_GET_INTERFACE = 5
NL80211_CMD_VENDOR = 103
NL80211_ATTR_IFINDEX = 3
NL80211_ATTR_IFNAME = 4
NL80211_ATTR_MAC = 6
NL80211_ATTR_VENDOR_ID = 195
NL80211_ATTR_VENDOR_SUBCMD = 196
NL80211_ATTR_VENDOR_DATA = 197

# brcmfmac vendor.h
BROADCOM_OUI = 0x001018
BRCMF_VNDR_CMDS_DCMD = 1
BRCMF_NLATTR_LEN = 1
BRCMF_NLATTR_DATA = 2
BRCMF_DCMD_MAXLEN = 8192  # BRCMF_DCMD_MEDLEN..MAXLEN; keep requests <= this

# Broadcom dcmd numbers (brcmu_wifi.h / fwil.h)
WLC_GET_VAR = 262
WLC_SET_VAR = 263
WLC_UP = 2
WLC_DOWN = 3
WLC_GET_MAGIC = 0
WLC_GET_VERSION = 1

BCME_STRS = {
    0: "OK", -1: "ERROR", -2: "BADARG", -3: "BADOPTION", -4: "NOTUP", -5: "NOTDOWN",
    -6: "NOTAP", -7: "NOTSTA", -8: "BADKEYIDX", -9: "RADIOOFF", -10: "NOTBANDLOCKED",
    -11: "NOCLK", -12: "BADRATESET", -13: "BADBAND", -14: "BUFTOOSHORT", -15: "BUFTOOLONG",
    -16: "BUSY", -17: "NOTASSOCIATED", -18: "BADSSIDLEN", -19: "OUTOFRANGECHAN",
    -20: "BADCHAN", -21: "BADADDR", -22: "NORESOURCE", -23: "UNSUPPORTED", -24: "BADLEN",
    -25: "NOTREADY", -26: "EPERM", -27: "NOMEM", -28: "ASSOCIATED", -29: "RANGE",
    -30: "NOTFOUND", -31: "WME_NOT_ENABLED", -32: "TSPEC_NOTFOUND", -33: "ACM_NOTSUPPORTED",
    -34: "NOT_WME_ASSOCIATION", -35: "SDIO_ERROR", -36: "DONGLE_DOWN", -37: "VERSION",
    -38: "TXFAIL", -39: "RXFAIL", -40: "NODEVICE", -41: "NMODE_DISABLED", -42: "NONRESIDENT",
    -43: "SCANREJECT", -44: "USAGE_ERROR", -45: "IOCTL_ERROR", -46: "SERIAL_PORT_ERR",
    -47: "DISABLED", -48: "DECERR", -49: "ENCERR", -50: "MICERR", -51: "REPLAY",
    -52: "IE_NOTFOUND", -53: "DATA_NOTFOUND", -54: "NOT_GC", -55: "PRS_REQ_FAILED",
    -56: "NO_P2P_SE", -57: "NOA_PND", -58: "FRAG_Q_FAIL", -59: "GET_AF_FAILED",
    -60: "MSCH_NOTREADY", -61: "IOV_LAST_CMD", -62: "MINIPMU_CAL_FAIL", -63: "RCAL_FAIL",
    -64: "LPO_CAL_FAIL", -65: "SET_INVALID_LPO", -66: "RANGECHAN_INVALID",
    -67: "SCAN_ROAM_ERROR", -68: "ASSOC_ERROR", -69: "FAIL_TO_UPDATE_ROAM",
    -70: "RXCHAIN_INVALID", -71: "HTC_ERROR", -72: "DBGMGR_INVALID",
}


def nla(t, payload):
    """netlink attribute, 4-byte aligned"""
    ln = 4 + len(payload)
    return struct.pack("=HH", ln, t) + payload + b"\0" * ((4 - ln % 4) % 4)


def parse_nlas(buf):
    out = {}
    off = 0
    while off + 4 <= len(buf):
        ln, t = struct.unpack_from("=HH", buf, off)
        if ln < 4:
            break
        out.setdefault(t & 0x3FFF, []).append(buf[off + 4: off + ln])
        off += (ln + 3) & ~3
    return out


class GenlSock:
    def __init__(self):
        self.s = socket.socket(socket.AF_NETLINK, socket.SOCK_RAW, NETLINK_GENERIC)
        self.s.bind((0, 0))
        self.seq = 1
        self.pid = self.s.getsockname()[0]
        self.nl80211 = self.resolve(b"nl80211")

    def _send(self, family, cmd, attrs, flags=NLM_F_REQUEST | NLM_F_ACK):
        self.seq += 1
        payload = struct.pack("=BBH", cmd, 1, 0) + attrs
        hdr = struct.pack("=IHHII", 16 + len(payload), family, flags, self.seq, self.pid)
        self.s.send(hdr + payload)
        return self.seq

    def _recv(self, seq):
        """collect genl payloads until ACK/ERROR for seq. returns (err, [payloads])"""
        payloads = []
        while True:
            data = self.s.recv(65536)
            off = 0
            while off + 16 <= len(data):
                ln, typ, flags, s, p = struct.unpack_from("=IHHII", data, off)
                body = data[off + 16: off + ln]
                if s == seq:
                    if typ == NLMSG_ERROR:
                        err = struct.unpack_from("=i", body)[0]
                        return err, payloads
                    if typ == NLMSG_DONE:
                        return 0, payloads
                    payloads.append(body)
                off += (ln + 3) & ~3

    def resolve(self, name):
        seq = self._send(GENL_ID_CTRL, CTRL_CMD_GETFAMILY,
                         nla(CTRL_ATTR_FAMILY_NAME, name + b"\0"))
        err, pl = self._recv(seq)
        if err:
            raise OSError(-err, "resolve %s: %s" % (name, os.strerror(-err)))
        attrs = parse_nlas(pl[0][4:])
        return struct.unpack("=H", attrs[CTRL_ATTR_FAMILY_ID][0][:2])[0]

    def get_interface(self, ifindex):
        seq = self._send(self.nl80211, NL80211_CMD_GET_INTERFACE,
                         nla(NL80211_ATTR_IFINDEX, struct.pack("=I", ifindex)))
        err, pl = self._recv(seq)
        if err:
            raise OSError(-err, os.strerror(-err))
        attrs = parse_nlas(pl[0][4:])
        return attrs[NL80211_ATTR_IFNAME][0].rstrip(b"\0").decode(), attrs[NL80211_ATTR_MAC][0]

    def dcmd(self, ifindex, cmd, data=b"", retlen=None, set_=False):
        """Issue a Broadcom dcmd. For GET, retlen is the size of the buffer the
        firmware writes into (must be >= len(data)). Returns bytes."""
        if retlen is None:
            retlen = len(data)
        if retlen > BRCMF_DCMD_MAXLEN or len(data) > BRCMF_DCMD_MAXLEN:
            raise ValueError("buffer too large")
        # struct brcmf_vndr_dcmd_hdr { uint cmd; int len; uint offset; uint set; uint magic; }
        hdr = struct.pack("=IiIII", cmd, retlen, 20, 1 if set_ else 0, 0)
        vdata = hdr + data
        attrs = (nla(NL80211_ATTR_IFINDEX, struct.pack("=I", ifindex))
                 + nla(NL80211_ATTR_VENDOR_ID, struct.pack("=I", BROADCOM_OUI))
                 + nla(NL80211_ATTR_VENDOR_SUBCMD, struct.pack("=I", BRCMF_VNDR_CMDS_DCMD))
                 + nla(NL80211_ATTR_VENDOR_DATA, vdata))
        seq = self._send(self.nl80211, NL80211_CMD_VENDOR, attrs)
        err, pl = self._recv(seq)
        out = b""
        for body in pl:
            attrs = parse_nlas(body[4:])
            for vd in attrs.get(NL80211_ATTR_VENDOR_DATA, []):
                sub = parse_nlas(vd)
                for chunk in sub.get(BRCMF_NLATTR_DATA, []):
                    out += chunk
        if err:
            raise OSError(-err, os.strerror(-err))
        return out

    # ---- iovar helpers ----
    bsscfg = None  # if set, scope iovars to this bsscfg index ("bsscfg:" prefix)

    def _iovar_buf(self, name, value=b""):
        name = name.encode() if isinstance(name, str) else name
        if self.bsscfg is None:
            return name + b"\0" + value
        # brcmf_create_bsscfg(): "bsscfg:<name>\0" + u32 idx + data
        return b"bsscfg:" + name + b"\0" + struct.pack("<I", self.bsscfg) + value

    def get_var(self, ifindex, name, retlen=256):
        buf = self._iovar_buf(name)
        return self.dcmd(ifindex, WLC_GET_VAR, buf, max(retlen, len(buf)))

    def set_var(self, ifindex, name, value):
        buf = self._iovar_buf(name, value)
        return self.dcmd(ifindex, WLC_SET_VAR, buf, len(buf), set_=True)

    def get_int(self, ifindex, name):
        return struct.unpack("<i", self.get_var(ifindex, name, 4)[:4])[0]

    def set_int(self, ifindex, name, v):
        return self.set_var(ifindex, name, struct.pack("<i", v))

    def bcmerror(self, ifindex):
        """last firmware error code + string (firmware records it)"""
        try:
            code = self.get_int(ifindex, "bcmerror")
        except OSError:
            code = None
        try:
            s = self.get_var(ifindex, "bcmerrorstr", 64).split(b"\0")[0].decode(errors="replace")
        except OSError:
            s = None
        return code, s


def hexdump(b):
    for i in range(0, len(b), 16):
        chunk = b[i:i + 16]
        print("%04x  %-48s %s" % (i, " ".join("%02x" % c for c in chunk),
                                  "".join(chr(c) if 32 <= c < 127 else "." for c in chunk)))


def main(argv):
    iface = "wlp229s0"
    bsscfg = None
    while len(argv) > 2 and argv[1] in ("-i", "-b"):
        if argv[1] == "-i":
            iface = argv[2]
        else:
            bsscfg = int(argv[2], 0)
        argv = argv[:1] + argv[3:]
    if len(argv) < 2:
        print(__doc__)
        return 1
    ifindex = socket.if_nametoindex(iface)
    g = GenlSock()
    g.bsscfg = bsscfg
    op, args = argv[1], argv[2:]

    def fail(e):
        code, s = g.bcmerror(ifindex)
        print("error: %s (kernel %s); firmware bcmerror=%s %s" %
              (os.strerror(e.errno), e.errno, code, BCME_STRS.get(code, s)))

    try:
        if op == "get":
            hexdump(g.get_var(ifindex, args[0], int(args[1]) if len(args) > 1 else 256))
        elif op == "getint":
            print(g.get_int(ifindex, args[0]))
        elif op == "getstr":
            print(g.get_var(ifindex, args[0], int(args[1]) if len(args) > 1 else 1024)
                  .split(b"\0")[0].decode(errors="replace"))
        elif op == "setint":
            g.set_int(ifindex, args[0], int(args[1], 0)); print("ok")
        elif op == "set":
            g.set_var(ifindex, args[0], bytes.fromhex(args[1])); print("ok")
        elif op == "ioctl":
            cmd = int(args[0], 0)
            ln = int(args[1], 0) if len(args) > 1 else 4
            data = bytes.fromhex(args[2]) if len(args) > 2 else b""
            hexdump(g.dcmd(ifindex, cmd, data, max(ln, len(data)), set_=bool(data)))
        elif op in ("probe", "probefile"):
            names = args if op == "probe" else [l.strip() for l in open(args[0]) if l.strip() and not l.startswith("#")]
            for n in names:
                try:
                    r = g.get_var(ifindex, n, 64)
                    print("%-32s EXISTS  %s" % (n, r[:16].hex()))
                except OSError as e:
                    code, s = g.bcmerror(ifindex)
                    tag = BCME_STRS.get(code, s)
                    # UNSUPPORTED = no such iovar. Anything else means the
                    # name was recognised but args/state were wrong.
                    print("%-32s %s  (bcmerror %s)" % (n, "absent " if tag == "UNSUPPORTED" else "EXISTS?", tag))
        else:
            print(__doc__); return 1
    except OSError as e:
        fail(e); return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
