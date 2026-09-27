#!/usr/bin/env python3
"""
Turn a USB capture of Audient's iD app (Wireshark + USBPcap on Windows, .pcapng or .pcap)
into a list of the audio-control commands it sent — the information needed to add safe
support for a model to iDVolume.

    python3 tools/analyse_capture.py capture.pcapng            # timeline + summary
    python3 tools/analyse_capture.py capture.pcapng --csv out.csv

Only USB Audio class control requests are shown (SET/GET CUR, RANGE, MEM). Gaps of more
than 1.5 s are marked, so each block lines up with a step of docs/CAPTURE.md.
"""
import argparse, csv, struct, sys
from collections import defaultdict

REQ = {0x01: "CUR", 0x02: "RANGE", 0x03: "MEM"}
STAGE_SETUP, STAGE_DATA, STAGE_STATUS, STAGE_COMPLETE = 0, 1, 2, 3


def packets(path):
    """Yield (timestamp_seconds, linktype, bytes) from pcapng or classic pcap."""
    data = open(path, "rb").read()
    if data[:4] in (b"\xd4\xc3\xb2\xa1", b"\xa1\xb2\xc3\xd4", b"\x4d\x3c\xb2\xa1", b"\xa1\xb2\x3c\x4d"):
        le = data[:4] in (b"\xd4\xc3\xb2\xa1", b"\x4d\x3c\xb2\xa1")
        nano = data[:4] in (b"\x4d\x3c\xb2\xa1", b"\xa1\xb2\x3c\x4d")
        e = "<" if le else ">"
        link = struct.unpack(e + "I", data[20:24])[0]
        off = 24
        while off + 16 <= len(data):
            sec, frac, incl, _ = struct.unpack(e + "IIII", data[off:off + 16])
            yield sec + frac / (1e9 if nano else 1e6), link, data[off + 16:off + 16 + incl]
            off += 16 + incl
        return
    off, e, ifaces = 0, "<", []
    while off + 12 <= len(data):
        btype = struct.unpack(e + "I", data[off:off + 4])[0]
        if btype == 0x0A0D0D0A:                                  # section header
            e = "<" if data[off + 8:off + 12] == b"\x4d\x3c\x2b\x1a" else ">"
            ifaces = []
        blen = struct.unpack(e + "I", data[off + 4:off + 8])[0]
        if blen < 12:
            break
        body = data[off + 8:off + blen - 4]
        if btype == 1:                                           # interface description
            link = struct.unpack(e + "H", body[:2])[0]
            res = 6                                              # default: microseconds
            o = 8
            while o + 4 <= len(body):
                code, ln = struct.unpack(e + "HH", body[o:o + 4])
                if code == 0:
                    break
                if code == 9 and ln >= 1:
                    res = body[o + 4]
                o += 4 + ((ln + 3) & ~3)
            ifaces.append((link, res))
        elif btype == 6 and ifaces:                              # enhanced packet
            iid, hi, lo, cap, _ = struct.unpack(e + "IIIII", body[:20])
            link, res = ifaces[iid] if iid < len(ifaces) else ifaces[0]
            ticks = (hi << 32) | lo
            scale = 2 ** -(res & 0x7F) if res & 0x80 else 10 ** -res
            yield ticks * scale, link, body[20:20 + cap]
        off += blen


def usbpcap(pkt):
    """Parse a USBPcap (linktype 249) header. Returns a dict or None."""
    if len(pkt) < 27:
        return None
    hlen, irp, status, func, info, bus, dev, ep, xfer, dlen = struct.unpack("<HQIHBHHBBI", pkt[:27])
    stage = pkt[27] if xfer == 2 and hlen >= 28 else None
    return dict(irp=irp, status=status, from_device=bool(info & 1), bus=bus, dev=dev, ep=ep,
                xfer=xfer, stage=stage, data=pkt[hlen:hlen + dlen])


def decode_value(data):
    if len(data) == 2:
        v = struct.unpack("<h", data)[0]
        return f"{v} ({v / 256:+.2f} dB)" if v != -32768 else "-32768 (silent)"
    if len(data) == 1:
        return str(data[0])
    return data.hex(" ")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("capture")
    ap.add_argument("--csv", help="also write the command list to this CSV file")
    ap.add_argument("--device", type=int, help="only this USB device address (default: the one with most audio commands)")
    a = ap.parse_args()

    pending, done, t0 = {}, [], None
    for ts, link, pkt in packets(a.capture):
        if link != 249:
            continue
        p = usbpcap(pkt)
        if not p or p["xfer"] != 2:
            continue
        t0 = ts if t0 is None else t0
        key = (p["bus"], p["dev"], p["irp"])
        if not p["from_device"] and p["stage"] in (STAGE_SETUP, None) and len(p["data"]) >= 8:
            bm, req, wv, wi, wl = struct.unpack("<BBHHH", p["data"][:8])
            pending[key] = dict(t=ts - t0, dev=p["dev"], bm=bm, req=req, wv=wv, wi=wi, wl=wl,
                                out=p["data"][8:], inp=b"", status=None)
        elif key in pending:
            c = pending[key]
            if not p["from_device"] and p["stage"] == STAGE_DATA:
                c["out"] += p["data"]
            elif p["from_device"]:
                if p["data"]:
                    c["inp"] += p["data"]
                if p["stage"] in (STAGE_COMPLETE, STAGE_STATUS, None):
                    c["status"] = p["status"]
                    done.append(pending.pop(key))
    done.extend(pending.values())

    # USB Audio class requests to an interface only (bmRequestType 0x21 / 0xA1).
    cmds = [c for c in done if (c["bm"] & 0x7F) == 0x21 and c["req"] in REQ]
    if not cmds:
        sys.exit("No USB Audio control requests found. Check the capture used the iD's USBPcap interface.")
    per_dev = defaultdict(int)
    for c in cmds:
        per_dev[c["dev"]] += 1
    dev = a.device if a.device is not None else max(per_dev, key=per_dev.get)
    cmds = sorted((c for c in cmds if c["dev"] == dev), key=lambda c: c["t"])

    print(f"Device address {dev}: {len(cmds)} audio control requests\n")
    print(f"{'time':>8}  {'op':<9} {'entity':>6} {'iface':>5} {'CS':>4} {'CN':>3} {'len':>3}  value / data")
    rows, last = [], None
    for c in cmds:
        if last is not None and c["t"] - last > 1.5:
            print(f"{'':>8}  — pause {c['t'] - last:.1f} s —")
        last = c["t"]
        op = ("GET " if c["bm"] & 0x80 else "SET ") + REQ[c["req"]]
        payload = c["inp"] if c["bm"] & 0x80 else c["out"]
        ent, iface, cs, cn = c["wi"] >> 8, c["wi"] & 0xFF, c["wv"] >> 8, c["wv"] & 0xFF
        ok = "" if not c["status"] else f"  ✗ status 0x{c['status']:08x}"
        print(f"{c['t']:8.3f}  {op:<9} 0x{ent:02x}   {iface:>5} 0x{cs:02x} {cn:>3} {c['wl']:>3}  {decode_value(payload)}{ok}")
        rows.append([f"{c['t']:.3f}", op, f"0x{ent:02x}", iface, f"0x{cs:02x}", cn, c["wl"], payload.hex(), c["status"] or 0])

    print("\nSummary: each distinct control")
    groups = defaultdict(list)
    for c in cmds:
        groups[(("GET" if c["bm"] & 0x80 else "SET"), REQ[c["req"]], c["wi"] >> 8, c["wi"] & 0xFF, c["wv"] >> 8, c["wv"] & 0xFF)].append(c)
    for (d, r, ent, iface, cs, cn), cs_ in sorted(groups.items(), key=lambda kv: (kv[0][2], kv[0][4], kv[0][5], kv[0][0])):
        values = sorted({(c["inp"] if d == "GET" else c["out"]).hex() for c in cs_})
        shown = ", ".join(values[:6]) + (" …" if len(values) > 6 else "")
        print(f"  {d} {r:<5} entity 0x{ent:02x} iface {iface} CS 0x{cs:02x} CN {cn}: {len(cs_)}×  values {shown}")
    ifaces = sorted({c["wi"] & 0xFF for c in cmds})
    print(f"\nInterfaces addressed: {', '.join(map(str, ifaces))}")

    if a.csv:
        with open(a.csv, "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(["time_s", "op", "entity", "interface", "cs", "cn", "length", "data_hex", "status"])
            w.writerows(rows)
        print(f"Wrote {a.csv}")


if __name__ == "__main__":
    main()
