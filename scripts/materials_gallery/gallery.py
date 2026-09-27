#!/usr/bin/env python3
"""Build the materials gallery page from render.py's output (#500).

    python3 scripts/materials_gallery/gallery.py /tmp/materials-gallery

Writes index.html (one grid per representation x background x ray-tracing
mode) and metrics.json. Needs Pillow and numpy for the metrics; without them
the page is still built, with file sizes only.

The metrics are STRUCTURAL on purpose. A material is a claim about shading,
and a mean colour barely moves when shading dies: deleting jelly's whole shader
dispatch moved the mean by 0.07 while the PNG shrank from 522 KB to 13 KB. So
each image reports, against the `default` image of the same cell:

  changed   share of subject pixels differing by more than 8/255
  hf        mean |Laplacian| of luminance over the subject (texture, highlights)
  bytes     PNG size, which tracks detail better than any mean

and a cell whose material changed less than 0.5% of the subject from `default`
is flagged -- that is how a build that silently resolves every material to
`default` shows up (it happened once, #487).

The lock check pans an orthoscopic camera and isolates each material's
TEXTURE as (material - default) at both camera positions. A pattern locked to
the object matches its panned twin once shifted by the silhouette's own shift;
a pattern that swims matches better unshifted. `locked` means the shifted
residual is under half the unshifted one -- a ratio, so the sub-pixel
resampling of a fine grain (rubber) does not read as swimming.

A cell is not flagged when the manifest's `degrades_to_default` says the
material draws as `default` on that representation (clear and frosted glass
on spheres); its caption says so instead.
"""
import html
import json
import os
import sys

try:
    import numpy as np
    from PIL import Image
except ImportError:   # page without metrics
    np = None


def load(path):
    return np.asarray(Image.open(path).convert('RGB')).astype(float)


def subject(img, bg):
    return np.abs(img - np.array(bg) * 255.0).sum(axis=2) > 12


def hf(img, mask):
    lum = img.mean(axis=2)
    lap = np.abs(4 * lum[1:-1, 1:-1] - lum[:-2, 1:-1] - lum[2:, 1:-1]
                 - lum[1:-1, :-2] - lum[1:-1, 2:])
    m = mask[1:-1, 1:-1]
    return float(lap[m].mean()) if m.any() else 0.0


def cell_metrics(out, tag, default_tag, bg):
    img = load(os.path.join(out, tag + '.png'))
    ref = load(os.path.join(out, default_tag + '.png'))
    mask = subject(ref, bg) | subject(img, bg)
    diff = np.abs(img - ref).max(axis=2)
    return {'changed': float((diff[mask] > 8).mean()) if mask.any() else 0.0,
            'hf': hf(img, subject(img, bg))}


def best_shift(a, b, span=120):
    """Horizontal pixel shift of b relative to a, by the silhouettes."""
    ma = (np.abs(a - a[0, 0]).sum(axis=2) > 12).astype(float)
    mb = (np.abs(b - b[0, 0]).sum(axis=2) > 12).astype(float)
    best, best_s = None, 0
    for s in range(-span, span + 1):
        if s >= 0:
            d = np.abs(ma[:, s:] - mb[:, :mb.shape[1] - s]).mean()
        else:
            d = np.abs(ma[:, :s] - mb[:, -s:]).mean()
        if best is None or d < best:
            best, best_s = d, s
    return best_s


def _crop(img, s):
    return img[:, s:] if s >= 0 else img[:, :s]


def _crop_other(img, s):
    return img[:, :img.shape[1] - s] if s >= 0 else img[:, -s:]


def lock_metrics(out, manifest):
    """Is each procedural pattern locked to the object?

    The TEXTURE is isolated as (material - default) at each camera position,
    which removes the shading both share. A locked pattern moves with the
    silhouette, so its texture matches the panned twin once shifted by the
    silhouette's shift; a swimming one matches better WITHOUT the shift. The
    ratio is scale-free, so a fine grain's sub-pixel resampling (which leaves
    a residual even when locked) does not read as swimming."""
    lc = manifest['lock_check']
    res = {}
    for rep in lc['reps']:
        path = lambda m, i: os.path.join(out, 'lock_%s_%s_%d.png' % (rep, m, i))
        absent = ['lock_%s_%s_%d' % (rep, m, i)
                  for m in lc['materials'] for i in (0, 1)
                  if not os.path.exists(path(m, i))]
        if absent:
            # reported by the caller as missing, never silently dropped
            res.setdefault('_missing', []).extend(absent)
            continue
        d0, d1 = load(path('default', 0)), load(path('default', 1))
        s = best_shift(d0, d1)
        m0 = subject(d0, d0[0, 0] / 255.0)
        m1 = subject(d1, d1[0, 0] / 255.0)
        both = _crop(m0, s) & _crop_other(m1, s)
        same = m0 & m1
        for mat in lc['materials']:
            if mat == 'default':
                continue
            t0 = load(path(mat, 0)) - d0
            t1 = load(path(mat, 1)) - d1
            shifted = float(np.abs(_crop(t0, s) - _crop_other(t1, s))
                            .max(axis=2)[both].mean())
            unshifted = float(np.abs(t0 - t1).max(axis=2)[same].mean())
            res['%s_%s' % (rep, mat)] = {
                'shift_px': s, 'texture_residual_shifted': shifted,
                'texture_residual_unshifted': unshifted,
                'locked': shifted < 0.5 * unshifted}
    return res


def main():
    out = sys.argv[1]
    manifest = json.load(open(os.path.join(out, 'manifest.json')))
    metrics, flagged, missing, twins, not_default = {}, [], [], [], []
    rows = []
    for rep in manifest['reps']:
        for bg, bg_rgb in manifest['backgrounds'].items():
            for rtname in manifest['raytrace']:
                cells = []
                default_tag = '%s_%s_%s_default' % (rep, bg, rtname)
                for mat in manifest['materials']:
                    tag = '%s_%s_%s_%s' % (rep, bg, rtname, mat)
                    png = os.path.join(out, tag + '.png')
                    if not os.path.exists(png):
                        missing.append(tag)   # reported, never silently dropped
                        continue
                    m = {'bytes': os.path.getsize(png)}
                    if np is not None and os.path.exists(
                            os.path.join(out, default_tag + '.png')):
                        m.update(cell_metrics(out, tag, default_tag, bg_rgb))
                        expected = mat in manifest.get(
                            'degrades_to_default', {}).get(rep, [])
                        m['expected_default'] = expected
                        if (mat != 'default' and not expected
                                and m['changed'] < 0.005):
                            flagged.append(tag)
                        # ...and a cell declared to degrade must actually BE
                        # default, or the label hides a half-drawn material.
                        if expected and m['changed'] >= 0.005:
                            not_default.append(tag)
                    metrics[tag] = m
                    cells.append((mat, tag, m))
                # Two DIFFERENT non-default materials that render alike are a
                # failure the against-default test cannot see: plastic and
                # metallic collapsed onto each other once (#540) while each
                # still differed from default.
                if np is not None:
                    live = [(mat, tag) for mat, tag, m in cells
                            if mat != 'default' and not m.get('expected_default')]
                    imgs = {tag: load(os.path.join(out, tag + '.png'))
                            for _mat, tag in live}
                    for i, (ma, ta) in enumerate(live):
                        for mb, tb in live[i + 1:]:
                            d = np.abs(imgs[ta] - imgs[tb]).max(axis=2)
                            mask = subject(imgs[ta], bg_rgb) | subject(imgs[tb], bg_rgb)
                            if mask.any() and float((d[mask] > 8).mean()) < 0.005:
                                if not any(sorted(e['materials']) == sorted([ma, mb])
                                           and e['background'] == bg
                                           and e['raytrace'] == rtname
                                           for e in manifest.get(
                                               'expected_identical_pairs', [])):
                                    twins.append('%s = %s' % (ta, tb))
                if cells:
                    rows.append(('%s &middot; %s background &middot; %s' % (
                        rep, bg, 'Metal ray tracing on' if rtname == 'rt1'
                        else 'ray tracing off'), cells))
    # Ray-tracing invariance, stated rather than silent: a material whose
    # rt0 and rt1 images are identical is either expected (the manifest's
    # rt_invariant list -- transparent geometry is not in the ray-traced
    # scene while metal_rt_transparent is off, #532) or a sign ray tracing
    # never reached it.
    rt_same, rt_expected = [], manifest.get('rt_invariant', {}).get('materials', [])
    if np is not None and set(manifest['raytrace']) == {'rt0', 'rt1'}:
        for rep in manifest['reps']:
            for bg in manifest['backgrounds']:
                for mat in manifest['materials']:
                    a = os.path.join(out, '%s_%s_rt0_%s.png' % (rep, bg, mat))
                    b = os.path.join(out, '%s_%s_rt1_%s.png' % (rep, bg, mat))
                    if (os.path.exists(a) and os.path.exists(b)
                            and np.array_equal(load(a), load(b))
                            and mat not in rt_expected):
                        rt_same.append('%s_%s_%s' % (rep, bg, mat))
    locks = lock_metrics(out, manifest) if np is not None else {}
    # render.py writes lock_check.reps = [] when --lock-check was not given,
    # so "not run" is exactly "nothing was asked for". When the check WAS
    # asked for, every absent lock image is missing -- all of them included.
    lock_missing = locks.pop('_missing', [])
    lock_not_run = not manifest['lock_check']['reps']
    if not lock_not_run:
        missing.extend(lock_missing)
    swims = [k for k, v in locks.items() if not v['locked']]
    json.dump({'cells': metrics, 'flagged_same_as_default': flagged,
               'identical_pairs': twins, 'missing': missing,
               'lock_check_run': not lock_not_run, 'swims': swims,
               'degraded_but_not_default': not_default,
               'identical_with_and_without_rt': rt_same,
               'lock_check': locks}, open(os.path.join(out, 'metrics.json'), 'w'),
              indent=1)

    parts = ['<!doctype html><meta charset="utf-8"><title>RayMol materials gallery</title>',
             '<style>body{font:13px -apple-system,sans-serif;background:#222;color:#ddd}'
             'h2{font-weight:500;margin:28px 0 6px}.g{display:flex;flex-wrap:wrap;gap:6px}'
             'figure{margin:0;width:280px}img{width:280px;display:block}'
             'figcaption{font-size:11px;color:#aaa}.bad{color:#f66}</style>',
             '<h1>RayMol materials</h1><p>Generated by scripts/materials_gallery. '
             'changed = share of the subject differing from <code>default</code> by more '
             'than 8/255; hf = mean |Laplacian| (texture and highlight detail).</p>']
    if lock_not_run:
        parts.append('<p>Pattern-lock check not run (render.py without --lock-check).</p>')
    for label, items in (('Indistinguishable from default', flagged),
                         ('Two materials render alike', twins),
                         ('Missing images', missing),
                         ('Identical with and without ray tracing', rt_same),
                         ('Declared to degrade to default but does not', not_default),
                         ('Pattern swims', swims)):
        if items:
            parts.append('<p class="bad">%s: %s</p>'
                         % (label, html.escape(', '.join(items))))
    for title, cells in rows:
        parts.append('<h2>%s</h2><div class="g">' % title)   # manifest-built, pre-escaped
        for mat, tag, m in cells:
            cap = '%s &middot; %d KB' % (html.escape(mat), m['bytes'] // 1024)
            if m.get('expected_default'):
                cap += ' &middot; degrades to default by design' 
            if 'changed' in m:
                cap += ' &middot; changed %.1f%% &middot; hf %.1f' % (
                    100 * m['changed'], m['hf'])
            parts.append('<figure><img src="%s.png" loading="lazy">'
                         '<figcaption>%s</figcaption></figure>' % (tag, cap))
        parts.append('</div>')
    if locks:
        parts.append('<h2>Pattern lock (orthoscopic pan)</h2><ul>')
        for key, v in sorted(locks.items()):
            parts.append('<li%s>%s: texture residual %.2f shifted vs %.2f unshifted '
                         '(shift %d px) &mdash; %s</li>'
                         % ('' if v['locked'] else ' class="bad"', key,
                            v['texture_residual_shifted'],
                            v['texture_residual_unshifted'], v['shift_px'],
                            'locked' if v['locked'] else 'SWIMS'))
        parts.append('</ul>')
    open(os.path.join(out, 'index.html'), 'w').write('\n'.join(parts))
    print('wrote %s (%d images, %d flagged, %d identical pairs, %d missing, '
          '%d unexpectedly RT-invariant, %d degraded-but-not-default, %s)' % (
              os.path.join(out, 'index.html'), len(metrics), len(flagged),
              len(twins), len(missing), len(rt_same), len(not_default),
              'lock check not run' if lock_not_run
              else '%d patterns swim' % len(swims)))
    if flagged or twins or missing or rt_same or not_default or swims:
        sys.exit(1)


if __name__ == '__main__':
    main()
