#!/usr/bin/env python3
"""Print the firmware's AWDL counters (awdl_stats / awdl_uct_stats) by name. Root."""
import socket, struct, sys
from brcmiovar import GenlSock

STATS = ["afrx","aftx","datatx","datarx","txdrop","rxdrop","monrx","lostmaster","misalign",
         "aws","aw_dur","debug","txsupr","afrxdrop","awdrop","noawchansw","rx80211","peeropdrop"]
UCT = ["aw_proc_in_aw_sched","aw_upd_in_pre_aw_proc","pre_aw_proc_in_aw_set","ignore_pre_aw_proc",
       "miss_pre_aw_intr","aw_dur_zero","aw_sched","aw_proc","pre_aw_proc","not_init","null_awdl"]

def read(iface="wlp229s0", cfg=2):
    g = GenlSock(); g.bsscfg = cfg
    idx = socket.if_nametoindex(iface)
    out = {}
    b = g.get_var(idx, "awdl_stats", 256)
    for i, n in enumerate(STATS):
        out[n] = struct.unpack_from("<I", b, 4 * i)[0]
    out["chancal"], out["nopreawint"] = struct.unpack_from("<HH", b, 72)
    b = g.get_var(idx, "awdl_uct_stats", 256)
    for i, n in enumerate(UCT):
        out["uct_" + n] = struct.unpack_from("<I", b, 4 * i)[0]
    return out

if __name__ == "__main__":
    s = read()
    print(" ".join("%s=%d" % (k, v) for k, v in s.items() if v or k in ("datarx","datatx","rxdrop","txdrop","peeropdrop","afrxdrop")))
