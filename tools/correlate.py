#!/usr/bin/env python3
"""
correlate.py - locate fan registers in an ITE EC's SRAM.

This is the instrument that found the register map documented in README.md. Use
it to port this tool to a different board or firmware revision, where the
offsets will differ.

Method: capture full SRAM dumps across an idle -> stress -> cooldown cycle while
recording CPU temperature, then rank every byte by how strongly it correlates
with temperature. Bytes with r = 1.000 are temperature mirrors (your anchor
point). The fan duty register shows a strong positive r, steps up as the CPU
heats, and visibly lags on cooldown. Blocks with strong *negative* r are
usually ADC channels reading thermistors.

  # capture 28 samples: 5 idle, 13 under load, 10 cooling down
  sudo ./correlate.py capture --out run1

  # rank bytes against temperature
  ./correlate.py analyze --dir run1
"""

import argparse
import glob
import os
import subprocess
import sys
import time

HWMON_GLOB = "/sys/class/hwmon/hwmon*/name"


def find_cpu_temp():
    """Return a path to a temp*_input for the CPU package sensor."""
    for name_file in sorted(glob.glob(HWMON_GLOB)):
        try:
            with open(name_file) as fh:
                name = fh.read().strip()
        except OSError:
            continue
        if name in ("k10temp", "coretemp", "zenpower"):
            cand = os.path.join(os.path.dirname(name_file), "temp1_input")
            if os.path.exists(cand):
                return cand
    sys.exit("could not find a k10temp/coretemp hwmon sensor")


def read_temp(path):
    with open(path) as fh:
        return int(fh.read().strip()) // 1000


def cmd_capture(args):
    if os.geteuid() != 0:
        sys.exit("must run as root")
    fanctl = args.fanctl
    temp_path = find_cpu_temp()
    os.makedirs(args.out, exist_ok=True)
    log = open(os.path.join(args.out, "temps.txt"), "w")

    def snap(index):
        path = os.path.join(args.out, "dump_%03d.bin" % index)
        with open(path, "wb") as fh:
            subprocess.run([fanctl, "dump", "-o", "-"], stdout=fh, check=True)
        temp = read_temp(temp_path)
        log.write("%d %d\n" % (index, temp))
        log.flush()
        print("  sample %3d  %d C" % (index, temp))

    index = 0
    print("phase 1: idle (%d samples)" % args.idle)
    for _ in range(args.idle):
        index += 1
        snap(index)
        time.sleep(args.interval)

    print("phase 2: load (%d samples)" % args.load)
    workers = [
        subprocess.Popen(["sh", "-c", "while :; do :; done"],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(os.cpu_count() or 4)
    ]
    try:
        for _ in range(args.load):
            time.sleep(args.interval)
            index += 1
            snap(index)
    finally:
        for w in workers:
            w.kill()
        for w in workers:
            w.wait()

    print("phase 3: cooldown (%d samples)" % args.cool)
    for _ in range(args.cool):
        time.sleep(args.interval + 1)
        index += 1
        snap(index)

    log.close()
    print("captured %d samples into %s" % (index, args.out))


def pearson(xs, ys):
    n = len(xs)
    mx = sum(xs) / n
    my = sum(ys) / n
    num = sum((a - mx) * (b - my) for a, b in zip(xs, ys))
    dx = sum((a - mx) ** 2 for a in xs) ** 0.5
    dy = sum((b - my) ** 2 for b in ys) ** 0.5
    return num / (dx * dy) if dx and dy else 0.0


def cmd_analyze(args):
    temps = {}
    with open(os.path.join(args.dir, "temps.txt")) as fh:
        for line in fh:
            idx, temp = line.split()
            temps[int(idx)] = int(temp)

    order = sorted(temps)
    series = [temps[i] for i in order]
    dumps = []
    for i in order:
        with open(os.path.join(args.dir, "dump_%03d.bin" % i), "rb") as fh:
            dumps.append(fh.read())

    size = min(len(d) for d in dumps)
    print("%d samples, temperature %d..%d C, %d bytes each\n"
          % (len(series), min(series), max(series), size))

    ranked = []
    for addr in range(size):
        vals = [d[addr] for d in dumps]
        if len(set(vals)) < 2:
            continue
        ranked.append((abs(pearson(vals, series)), pearson(vals, series), addr, vals))
    ranked.sort(reverse=True)

    print("=== top %d bytes by |correlation| with CPU temperature ===" % args.top)
    for _, r, addr, vals in ranked[:args.top]:
        note = ""
        if 0x400 <= addr < 0x500:
            note = "  [ACPI EC 0x%02X]" % (addr - 0x400)
        print("r=%+.3f  0x%04X%s  min=%d max=%d" % (r, addr, note, min(vals), max(vals)))
        print("            %s" % vals)

    print()
    print("Hints:")
    print("  r ~ +1.000 and range == temperature range -> temperature mirror (anchor)")
    print("  strong +r, steps upward, lags on cooldown -> fan duty register")
    print("  strong -r in a contiguous block          -> ADC / thermistor channels")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("capture", help="record SRAM dumps across a thermal cycle")
    p.add_argument("--out", default="run1", help="output directory")
    p.add_argument("--fanctl", default="./gmktec-fanctl",
                   help="path to gmktec-fanctl (used for its dump command)")
    p.add_argument("--interval", type=float, default=3.0)
    p.add_argument("--idle", type=int, default=5)
    p.add_argument("--load", type=int, default=13)
    p.add_argument("--cool", type=int, default=10)

    p = sub.add_parser("analyze", help="rank bytes by correlation with temperature")
    p.add_argument("--dir", default="run1")
    p.add_argument("--top", type=int, default=25)

    args = ap.parse_args()
    {"capture": cmd_capture, "analyze": cmd_analyze}[args.cmd](args)


if __name__ == "__main__":
    main()
