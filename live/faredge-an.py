#!/usr/bin/env python3
"""an.py <fe output>...: per file, per motion kind (show/hide): the browser's far edge per window-server frame after the
press (inward = toward the sidebar's side, i.e. in), the first-movement latency and the time to the last change, flashes."""
import re, sys, statistics as st
def med(x): return st.median(x) if x else float('nan')
for path in sys.argv[1:]:
    lines = open(path).read().splitlines()
    hdr = lines[0]; side = re.search(r'side=(\w+)', hdr).group(1)
    blocks = []; cur = None
    for l in lines[1:]:
        m = re.match(r'-- (show|hide) (\d+)', l)
        if m: cur = {'kind': m.group(1), 'n': int(m.group(2)), 'press': None, 'fr': [], 'pv': []}; blocks.append(cur); continue
        if cur is None: continue
        if l.startswith('PRESS'): cur['press'] = float(l.split()[1]); continue
        if l.startswith('SKIPPED'): cur['skipped'] = True; continue
        if l.startswith('PV '): cur['pv'].append(l); continue
        m = re.match(r'\s*([\d.]+) pid (\d+) win (\d+) (-?\d+),(-?\d+) (\d+)x(\d+)', l)
        if m:
            t, pid, win, x, y, w, h = float(m.group(1)), int(m.group(2)), int(m.group(3)), *map(int, m.group(4, 5, 6, 7))
            if w > 500: cur['fr'].append((t, x, y, w, h))
    res = {'show': [], 'hide': []}
    for b in blocks:
        if b['press'] is None or not b['fr']: continue
        before = [f for f in b['fr'] if f[0] <= b['press']]
        after = [f for f in b['fr'] if f[0] > b['press']]
        if not before or not after: continue
        f0 = before[-1]
        far = (lambda f: f[1] + f[3]) if side == 'left' else (lambda f: f[1])
        sign = 1 if side == 'left' else -1   # inward: far edge toward the sidebar
        inward = [sign * (far(f0) - far(f)) for f in after]
        # how long each frame stayed (to the next change, or 0 for the last)
        dur = [after[i + 1][0] - after[i][0] for i in range(len(after) - 1)] + [0]
        flash = False
        if b['kind'] == 'hide':
            seen0 = False
            for l in b['pv']:
                m = re.search(r'visible cols (\d+)', l)
                if not m: continue
                c = int(m.group(1))
                if c == 0: seen0 = True
                elif seen0: flash = True
        res[b['kind']].append({'n': b['n'], 'in': max(inward), 'out': -min(inward), 'bad': sum(1 for v in inward if v > 0.5),
                               'badms': sum(d for v, d in zip(inward, dur) if v > 0.5), 'drift2': sum(1 for v in inward if abs(v) > 2),
                               'first': after[0][0] - b['press'], 'last': after[-1][0] - b['press'], 'frames': len(after),
                               'end': far(after[-1]) - far(f0), 'flash': flash})
    print(f"== {path}: {hdr}")
    for k, r in res.items():
        if not r: print(f"  {k}: no data"); continue
        ins = [x['in'] for x in r]
        print(f"  {k} n={len(r)}: far edge IN max {max(ins):.0f} median {med(ins):.0f}; motions with any frame in >0.5pt {sum(1 for x in r if x['bad'])}/{len(r)}"
              f" (frames in {sum(x['bad'] for x in r)}, {sum(x['badms'] for x in r):.0f} ms total); OUT max {max(x['out'] for x in r):.0f};"
              f" frames |drift|>2 {sum(x['drift2'] for x in r)}; first move median {med([x['first'] for x in r]):.1f} ms (max {max(x['first'] for x in r):.1f});"
              f" last change median {med([x['last'] for x in r]):.0f} ms (max {max(x['last'] for x in r):.0f}); frames median {med([x['frames'] for x in r]):.0f};"
              f" end off {max(abs(x['end']) for x in r):.0f}; flashes {sum(x['flash'] for x in r)}")
