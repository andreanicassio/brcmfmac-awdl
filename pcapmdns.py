#!/usr/bin/env python3
"""Summarise mDNS traffic in a pcap of awdl0 (handles raw AWDL LLC/SNAP or Ethernet II)."""
import struct, sys, re
def names(dns):
    out=[]; i=12
    def rd(i):
        labs=[]
        while i < len(dns):
            n=dns[i]
            if n==0: return ".".join(labs), i+1
            if n&0xc0==0xc0:
                ptr=struct.unpack_from(">H",dns,i)[0]&0x3fff; sub,_=rd(ptr); labs.append(sub); return ".".join(labs), i+2
            labs.append(dns[i+1:i+1+n].decode("latin1")); i+=1+n
        return ".".join(labs), i
    qd,an,ns,ar=struct.unpack_from(">HHHH",dns,4)
    try:
        for _ in range(qd):
            n,i=rd(i); t=struct.unpack_from(">H",dns,i)[0]; i+=4; out.append("Q %s/%d"%(n,t))
        for _ in range(an+ns+ar):
            n,i=rd(i); t,cl,ttl,rl=struct.unpack_from(">HHIH",dns,i); i+=10
            extra=""
            if t==12: extra=" -> "+rd(i)[0]
            if t==33: extra=" -> port %d %s"%(struct.unpack_from(">H",dns,i+4)[0], rd(i+6)[0])
            if t==16: extra=" "+dns[i:i+rl][:80].decode("latin1")
            out.append("A %s/%d%s"%(n,t,extra)); i+=rl
    except Exception as e: out.append("(parse err %s)"%e)
    return out
f=open(sys.argv[1],"rb"); g=f.read(); off=24; ours=sys.argv[2] if len(sys.argv)>2 else ""
cnt={}
while off+16<=len(g):
    ts,us,cl,ol=struct.unpack_from("<IIII",g,off); off+=16; pkt=g[off:off+cl]; off+=cl
    src=pkt[6:12].hex(":")
    if src==ours: continue
    i=pkt.find(b"\x86\xdd",12)
    if i<0 or i>40: continue
    ip6=pkt[i+2:]
    if ip6[6]!=17: continue
    udp=ip6[40:]; dport=struct.unpack_from(">H",udp,2)[0]
    if dport!=5353: continue
    dns=udp[8:]; flags=struct.unpack_from(">H",dns,2)[0]
    key=(src,"RESP" if flags&0x8000 else "QUERY","\n     ".join(names(dns)[:10]))
    cnt[key]=cnt.get(key,0)+1
for (src,kind,body),n in cnt.items(): print("%dx from %s %s:\n     %s"%(n,src,kind,body))
