"""
tube_cartoon.py — build a smooth cubic-Bezier spline through a protein backbone
and load it as a CGO of CGO_BEZIER ops.

On the SwiftUI+Metal renderer these Bezier patches are GPU-tessellated into a
smooth tube (see RendererMetal bezier-tube pipeline). On desktop GL they render
as the (yellow) Bezier curve via the tessellation-shader path — useful to
validate the control points.

Usage (in PyMOL):
    run /Users/jcastellanos/repos/pymol-open-source/swiftui/tube_cartoon.py
    tube_cartoon polymer, tube        # selection, output object name

The spline is C1-continuous Catmull-Rom converted to cubic Bezier segments
through the CA atoms of each chain.
"""

from pymol import cmd, cgo


def tube_cartoon(selection='polymer', name='tube', _self=cmd):
    # Gather CA atoms grouped by chain, preserving model order.
    model = _self.get_model('(%s) and name CA and polymer' % selection)
    chains = {}
    order = []
    for at in model.atom:
        key = (at.segi, at.chain)
        if key not in chains:
            chains[key] = []
            order.append(key)
        chains[key].append(at.coord)

    obj = []
    nseg = 0
    for key in order:
        pts = chains[key]
        n = len(pts)
        if n < 2:
            continue

        def P(i):
            return pts[max(0, min(n - 1, i))]

        for i in range(n - 1):
            p0, p1 = P(i), P(i + 1)
            pm1, p2 = P(i - 1), P(i + 2)
            # Catmull-Rom -> Bezier control points (tension 1/6).
            b1 = [p0[k] + (p1[k] - pm1[k]) / 6.0 for k in range(3)]
            b2 = [p1[k] - (p2[k] - p0[k]) / 6.0 for k in range(3)]
            obj += [cgo.BEZIER,
                    p0[0], p0[1], p0[2],
                    b1[0], b1[1], b1[2],
                    b2[0], b2[1], b2[2],
                    p1[0], p1[1], p1[2]]
            nseg += 1

    if not obj:
        print('tube_cartoon: no CA atoms in selection "%s"' % selection)
        return
    _self.load_cgo(obj, name)
    print('tube_cartoon: %d Bezier segments -> object "%s"' % (nseg, name))


cmd.extend('tube_cartoon', tube_cartoon)
