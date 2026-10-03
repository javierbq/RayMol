'''
PROTOTYPE: studio lights for the Metal renderer.

A quick hack to see what photographic lighting looks like on molecules before
designing it properly. A rig is up to six spot lights. Each light has a
position, a beam (cone) angle with a soft edge, a colour and an intensity, and
gives a coloured highlight. Up to three lights with shadow=1 each cast their
own shadow (a perspective map from the lamp, applied to that light only).

Two kinds of placement:
  * camera rig (az/el/dist): placed around whatever is visible in CAMERA
    space, so the rig turns with the view, like PyMOL's own lights;
  * world-anchored, fixed to the molecule once placed:
      target=<sele>     aim at a selection, from az/el (as seen right now);
      highlight=<sele>  put the light where its highlight lands on <sele>;
      click=sx/sy       the same for the surface under a screen point
                        (-1..1, as a mouse click would give).
    These fit the beam to the target (beam=fit) unless beam= is given.

cue=1 draws a light's beam outline on the geometry; `studio gizmo` adds a
CGO object (studio_rig) showing the lights, their cones and the camera.

The rig is packed into the global `studio_lights` setting (17 floats per
light) which layer1/SceneRender.cpp turns into eye-space lights each frame.
Only the Metal renderer reads it: `ray` and OpenGL ignore it.

    studio three_point          # a preset (see `studio list`)
    studio key int=1.6 beam=25  # tweak one light of the current rig
    studio key: az=-40 el=35 kelvin=3200 | rim: az=160 el=30 color=cyan int=2
    studio key: target=ligand az=-30 el=40 cue=1
    studio pin: click=0.1/0.2 focus=8 cue=1
    studio off                  # restore the lighting from before `studio`
'''

import math

from pymol import cmd as _cmd

_DEFAULTS = dict(az=0.0, el=30.0, dist=4.0, beam=45.0, soft=0.4,
                 r=1.0, g=1.0, b=1.0, int=1.0, spec=0.5, falloff=2.0,
                 aimx=0.0, aimy=0.0, aimz=0.0, shadow=0.0, cue=0.0,
                 focus=10.0, fit=0.0, aspect=0.0, rim=0.0)

# String fields that make a light world-anchored (resolved by _resolve).
_PLACEMENT = ('target', 'highlight', 'click')

_GIZMO = 'studio_rig'

_MAX_LIGHTS = 6

# Lighting settings a preset may change; saved on the first `studio` so that
# `studio off` puts them back.
_BASE_SETTINGS = ('ambient', 'direct', 'reflect', 'specular', 'metal_shadows')

_state = {'rig': [], 'saved': None, 'preset': ''}

# Atmosphere (Metal post pass): haze in the air and dust motes, both lit only
# by the beams. Packed into `studio_atmosphere` in this order.
_ATMO_KEYS = ('haze', 'dust', 'dust_size', 'scatter', 'seed', 'dust_speed')
_ATMO_DEFAULTS = dict(haze=0.0, dust=0.0, dust_size=0.35, scatter=0.55,
                      seed=0.0, dust_speed=1.0)
_atmo = dict(_ATMO_DEFAULTS)


def _write_atmo(self):
    on = _atmo['haze'] > 0 or _atmo['dust'] > 0
    self.set('studio_atmosphere',
             ' '.join('%g' % _atmo[k] for k in _ATMO_KEYS) if on else '')


def kelvin_rgb(k):
    '''Colour of a black body at k kelvin (Tanner Helland's fit), max channel 1.'''
    t = max(1000.0, min(40000.0, float(k))) / 100.0
    if t <= 66:
        r = 255.0
        g = 99.4708025861 * math.log(t) - 161.1195681661
        b = 0.0 if t <= 19 else 138.5177312231 * math.log(t - 10) - 305.0447927307
    else:
        r = 329.698727446 * (t - 60) ** -0.1332047592
        g = 288.1221695283 * (t - 60) ** -0.0755148492
        b = 255.0
    rgb = [max(0.0, min(255.0, c)) / 255.0 for c in (r, g, b)]
    m = max(rgb) or 1.0
    return [c / m for c in rgb]


def _L(name, **kw):
    light = dict(_DEFAULTS)
    light.update(name=name, mode=0, beam_set=False, target=None,
                 highlight=None, click=None, _S=None)
    for key, value in kw.items():
        _set_field(light, key, value)
    return light


# Each preset: (description, ambient, lights). direct/reflect go to 0 so the
# rig alone lights the scene (`keep_base=1` keeps PyMOL's two lights too).
PRESETS = {
    'three_point': ('Classic portrait: warm key with shadow, cool fill, white rim',
        0.10, lambda: [
            _L('key', az=-45, el=35, beam=55, soft=0.5, kelvin=4500, int=1.15,
               spec=0.6, shadow=1),
            _L('fill', az=55, el=5, beam=80, soft=0.8, kelvin=8000, int=0.35,
               spec=0.1),
            _L('rim', az=165, el=40, beam=40, soft=0.4, int=1.6, spec=1.0),
        ]),
    'softbox': ('Product shot: two big soft white boxes, gentle top light',
        0.16, lambda: [
            _L('left', az=-60, el=20, beam=120, soft=1.0, int=0.75, spec=0.25,
               shadow=1),
            _L('right', az=60, el=20, beam=120, soft=1.0, int=0.55, spec=0.25),
            _L('top', az=0, el=80, beam=110, soft=1.0, int=0.35, spec=0.15),
        ]),
    'spotlight': ('Theatre: one narrow beam from above, the rest falls off',
        0.05, lambda: [
            _L('spot', az=-15, el=50, dist=3, beam=18, soft=0.3, kelvin=5200,
               int=1.8, spec=0.9, aim='-0.25/0.15/0', shadow=1),
            _L('bounce', az=20, el=-30, beam=90, soft=1.0, kelvin=7500,
               int=0.12, spec=0.0),
        ]),
    'rembrandt': ('Dramatic: one hard warm key high to the side, almost no fill',
        0.04, lambda: [
            _L('key', az=-70, el=45, dist=3, beam=60, soft=0.3, kelvin=3400,
               int=1.5, spec=0.7, falloff=2.5, shadow=1),
            _L('kicker', az=150, el=10, beam=30, soft=0.4, kelvin=6500,
               int=0.6, spec=0.6),
        ]),
    'neon': ('Coloured rims: magenta and cyan from behind, dim violet front',
        0.06, lambda: [
            _L('magenta', az=-125, el=20, beam=55, soft=0.5, color='magenta',
               int=1.6, spec=1.0, shadow=1),
            _L('cyan', az=125, el=20, beam=55, soft=0.5, color='cyan',
               int=1.6, spec=1.0),
            _L('front', az=0, el=0, beam=90, soft=1.0, color='slate', int=0.25,
               spec=0.1),
        ]),
    'sunset': ('Low orange sun from one side, blue sky fill from the other',
        0.08, lambda: [
            _L('sun', az=-75, el=12, beam=70, soft=0.5, kelvin=2400, int=1.4,
               spec=0.8, shadow=1),
            _L('sky', az=60, el=50, beam=110, soft=1.0, kelvin=14000, int=0.45,
               spec=0.1),
        ]),
    'underlight': ('Horror-film: green-tinted key from below, red rim',
        0.04, lambda: [
            _L('under', az=0, el=-55, beam=60, soft=0.5, rgb=(0.6, 1.0, 0.55),
               int=1.3, spec=0.6, shadow=1),
            _L('rim', az=170, el=25, beam=40, soft=0.4, color='red', int=1.4,
               spec=0.8),
        ]),
}


def _parse_color(value, self):
    value = str(value).strip()
    if '/' in value:
        parts = [float(x) for x in value.split('/')]
        if max(parts) > 1.0:
            parts = [x / 255.0 for x in parts]
        return parts[:3]
    return list(self.get_color_tuple(value))


def _set_field(light, key, value, self=_cmd):
    key = key.strip().lower()
    alias = {'intensity': 'int', 'angle': 'beam', 'cone': 'beam',
             'distance': 'dist', 'softness': 'soft', 'k': 'kelvin'}
    key = alias.get(key, key)
    if key == 'kelvin':
        light['r'], light['g'], light['b'] = kelvin_rgb(float(value))
    elif key in ('color', 'colour'):
        light['r'], light['g'], light['b'] = _parse_color(value, self)
    elif key == 'rgb':
        if isinstance(value, (tuple, list)):
            light['r'], light['g'], light['b'] = [float(x) for x in value]
        else:
            light['r'], light['g'], light['b'] = _parse_color(value, self)
    elif key == 'aim':
        parts = [float(x) for x in str(value).split('/')] + [0.0, 0.0]
        light['aimx'], light['aimy'], light['aimz'] = parts[:3]
    elif key == 'beam':
        text = str(value).lower()
        if text.startswith('fit'):          # beam=fit or beam=fit1.5 (margin)
            light['fit'] = float(text[3:] or 1.15)
            light['beam_set'] = False
        else:
            light['beam'] = float(value)
            light['fit'] = 0.0
            light['beam_set'] = True
    elif key in _PLACEMENT:
        for other in _PLACEMENT:
            light[other] = None
        light[key] = str(value)
    elif key in ('cue', 'shadow') and str(value).lower() in ('on', 'off'):
        light[key] = 1.0 if str(value).lower() == 'on' else 0.0
    elif key in _DEFAULTS:
        light[key] = float(value)
    else:
        raise ValueError('unknown light field %r (fields: %s, kelvin, color, '
                         'rgb, aim, target, highlight, click)' % (
                             key, ', '.join(sorted(_DEFAULTS))))


def _parse_light(text, self, index):
    '''"name: key=value key=value" (the name is optional).'''
    name = 'light%d' % (index + 1)
    if ':' in text:
        name, text = text.split(':', 1)
        name = name.strip() or 'light%d' % (index + 1)
    light = _L(name)
    for token in text.split():
        if '=' not in token:
            raise ValueError('expected key=value, got %r' % token)
        key, value = token.split('=', 1)
        _set_field(light, key, value, self)
    return light


# ---- world-anchored placement ---------------------------------------------
#
# Plain Python on purpose: the native app bundles no numpy.
#
# get_view()[:9] is the rotation, column-major: read row-major as a 3x3 M it
# maps camera-space directions to model space (model = M @ eye); [9:12] is the
# rotation origin in camera space and [12:15] the same point in model space.

def _add(a, b): return [a[0] + b[0], a[1] + b[1], a[2] + b[2]]
def _sub(a, b): return [a[0] - b[0], a[1] - b[1], a[2] - b[2]]
def _mul(a, k): return [a[0] * k, a[1] * k, a[2] * k]
def _dot(a, b): return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
def _norm(a): return math.sqrt(_dot(a, a))


def _cross(a, b):
    return [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2],
            a[0] * b[1] - a[1] * b[0]]


def _unit(a):
    n = _norm(a)
    return _mul(a, 1.0 / n) if n > 1e-9 else list(a)


def _mv(M, v):          # M @ v
    return [_dot(M[0], v), _dot(M[1], v), _dot(M[2], v)]


def _mtv(M, v):         # M^T @ v
    return [M[0][0] * v[0] + M[1][0] * v[1] + M[2][0] * v[2],
            M[0][1] * v[0] + M[1][1] * v[1] + M[2][1] * v[2],
            M[0][2] * v[0] + M[1][2] * v[1] + M[2][2] * v[2]]


def _mean(points):
    n = float(len(points))
    return [sum(p[0] for p in points) / n, sum(p[1] for p in points) / n,
            sum(p[2] for p in points) / n]


def _view(self):
    v = [float(x) for x in self.get_view()]
    return [v[0:3], v[3:6], v[6:9]], v[9:12], v[12:15]


def _coords(sele, self):
    return [list(a.coord) for a in self.get_model(sele).atom]


def _scene_radius(self):
    mn, mx = self.get_extent('not solvent')
    return max(0.5 * _norm(_sub(mx, mn)), 1.0)


def _ortho(self):
    # cmd.get returns booleans as 'on' / 'off'
    return str(self.get('orthoscopic')).lower() in ('on', '1', 'true')


def _aspect(light, self):
    if light['aspect'] > 0:
        return light['aspect']
    w, h = self.get_viewport()[:2]
    return float(w) / max(float(h), 1.0)


def _outward_normal(point, atoms, view=None, sigma=4.0):
    '''Smooth surface normal at point: minus the gradient of a Gaussian atom
    density (the normal of a Gaussian molecular surface).

    A stand-in for the normal a real click would read from the depth buffer.
    With `view` (unit vector toward the camera) it is kept facing the
    camera, as the normal of any visible surface is; in deep grooves the
    density gradient alone can tip past that.'''
    g = [0.0, 0.0, 0.0]
    cut = (4.0 * sigma) ** 2
    for a in atoms:
        d = _sub(point, a)
        r2 = _dot(d, d)
        if r2 < cut:
            g = _add(g, _mul(d, math.exp(-r2 / (2.0 * sigma * sigma))))
    n = _unit(g) if _norm(g) > 1e-9 else _unit(_sub(point, _mean(atoms)))
    if view is not None and _dot(n, view) < 0.05:
        n = _unit(_add(n, _mul(view, 0.05 - _dot(n, view))))
    return n


def _pick(sx, sy, aspect, self):
    '''The surface point under screen point (sx, sy) in -1..1, in model space.

    Ray-casts the camera ray against heavy atoms as 1.9 A spheres, i.e. what
    clicking the viewport would hit.'''
    M, pos, org = _view(self)
    atoms = _coords('polymer and not hydro', self)
    if not atoms:
        raise ValueError('click= needs a polymer to hit')
    t = math.tan(math.radians(float(self.get('field_of_view')) / 2.0))
    if _ortho(self):
        h = abs(pos[2]) * t
        ro, d = [sx * h * aspect, sy * h, 0.0], [0.0, 0.0, -1.0]
    else:
        ro, d = [0.0, 0.0, 0.0], _unit([sx * t * aspect, sy * t, -1.0])
    best, closest = None, None
    for a in atoms:
        oc = _sub(_add(_mtv(M, _sub(a, org)), pos), ro)   # atom in eye space
        b = _dot(oc, d)
        c = _dot(oc, oc)
        disc = b * b - (c - 1.9 ** 2)
        if disc >= 0 and b > 0:
            depth = b - math.sqrt(disc)
            if best is None or depth < best:
                best = depth
        miss = c - b * b
        if closest is None or miss < closest[0]:
            closest = (miss, b)
    depth = best if best is not None else closest[1]   # missed: nearest atom
    point = _add(_mv(M, _sub(_add(ro, _mul(d, depth)), pos)), org)
    toward_camera = _unit(_mv(M, _mul(d, -1.0)))
    return point, _outward_normal(point, atoms, toward_camera)


def _resolve(light, self):
    '''Turn target= / highlight= / click= into a world position and aim.'''
    if not any(light.get(k) for k in _PLACEMENT):
        light['mode'] = 0
        return
    M, pos, org = _view(self)
    camera = _sub(org, _mv(M, pos))
    dist = light['dist'] * _scene_radius(self)
    light['_S'] = None
    if light['target']:
        atoms = _coords(light['target'], self)
        if not atoms:
            raise ValueError('target %r selects no atoms' % light['target'])
        aim = _mean(atoms)
        fit_radius = max(_norm(_sub(a, aim)) for a in atoms) + 1.5
        az, el = math.radians(light['az']), math.radians(light['el'])
        toward = _mv(M, [math.sin(az) * math.cos(el), math.sin(el),
                         math.cos(az) * math.cos(el)])
    else:
        if light['click']:
            sx, sy = (float(x) for x in light['click'].split('/'))
            aim, normal = _pick(sx, sy, _aspect(light, self), self)
        else:
            atoms = _coords(light['highlight'], self)
            if not atoms:
                raise ValueError('highlight %r selects no atoms'
                                 % light['highlight'])
            centre = _mean(atoms)
            normal = _outward_normal(
                centre, _coords('polymer and not hydro', self))
            aim = _add(centre, _mul(normal, 1.9))
        if _ortho(self):
            view = _unit(_mv(M, [0.0, 0.0, 1.0]))
        else:
            view = _unit(_sub(camera, aim))
        if light['rim'] > 0:
            # Rim: behind the molecule at `rim` degrees from the camera, on
            # the clicked side. The mirror rule cannot do this: at the very
            # silhouette it puts the light straight behind, aimed at the
            # camera, which lights nothing the camera sees.
            side = _unit(_sub(normal, _mul(view, _dot(normal, view))))
            a = math.radians(light['rim'])
            toward = _add(_mul(view, math.cos(a)), _mul(side, math.sin(a)))
        else:
            # Mirror the view ray about the normal: a light along that
            # direction puts its highlight exactly at `aim`.
            toward = _sub(_mul(normal, 2.0 * _dot(normal, view)), view)
        fit_radius = light['focus']
        light['_S'], light['_N'] = aim, normal
    position = _add(aim, _mul(_unit(toward), dist))
    light.update(mode=1, px=position[0], py=position[1], pz=position[2],
                 tx=aim[0], ty=aim[1], tz=aim[2])
    if light['fit'] or not light['beam_set']:
        margin = light['fit'] or 1.15
        light['beam'] = 2.0 * math.degrees(math.atan(margin * fit_radius / dist))
    _state['camera'] = (camera, M, abs(pos[2]),
                        float(self.get('field_of_view')), _aspect(light, self))


def _pack(rig):
    # Must match SceneStudioLightsUpdate in layer1/SceneRender.cpp.
    out = []
    for l in rig:
        if l.get('mode') == 1:
            p, q = (l['px'], l['py'], l['pz']), (l['tx'], l['ty'], l['tz'])
        else:
            p, q = (l['az'], l['el'], l['dist']), (l['aimx'], l['aimy'], l['aimz'])
        out += [l.get('mode', 0)] + list(p) + list(q) + [
            l['beam'], l['soft'], l['r'], l['g'], l['b'], l['int'], l['spec'],
            l['falloff'], l['shadow'], l['cue']]
    return ' '.join('%.6g' % float(v) for v in out)


def _gizmo(self):
    '''CGO lines for the world-anchored lights: a lamp and its aim line for
    every light; the cone, beam edges and aim cross for lights with cue=1;
    for highlight/click lights the view ray and surface normal; and the
    camera the rig was placed from. The camera is drawn along its true
    direction but pulled in to the lights' distance (not to scale), or it
    would dwarf everything else.'''
    from pymol import cgo
    segs = []   # (rgb, a, b)

    def ring(c, r, u, v, k):
        a = 2 * math.pi * k
        return _add(c, _add(_mul(u, r * math.cos(a)), _mul(v, r * math.sin(a))))

    def circle(c, r, u, v, rgb, dashed=False, n=72):
        for k in range(n):
            if not (dashed and k % 2):
                segs.append((rgb, ring(c, r, u, v, k / float(n)),
                             ring(c, r, u, v, (k + 1) / float(n))))

    def dashed_line(a, b, rgb, n=24):
        for k in range(0, n, 2):
            segs.append((rgb, _add(a, _mul(_sub(b, a), k / float(n))),
                         _add(a, _mul(_sub(b, a), (k + 1) / float(n)))))

    for l in _state['rig']:
        if l.get('mode') != 1:
            continue
        P = [l['px'], l['py'], l['pz']]
        T = [l['tx'], l['ty'], l['tz']]
        D = _norm(_sub(T, P))
        axis = _unit(_sub(T, P))
        u = _unit(_cross(axis, [0, 1, 0] if abs(axis[1]) < 0.9 else [1, 0, 0]))
        v = _cross(axis, u)
        half = math.radians(l['beam'] / 2.0)
        r_out = D * math.tan(half)
        r_in = D * math.tan(half * (1.0 - l['soft']))
        top = max(l['r'], l['g'], l['b'], 1e-6)
        rgb = tuple(0.65 * c / top + 0.35 for c in (l['r'], l['g'], l['b']))
        segs.append((rgb, P, T))
        if l['cue'] > 0.5:
            circle(T, r_out, u, v, rgb)
            circle(T, r_in, u, v, rgb, dashed=True)
            for k in range(12):
                segs.append((rgb, P, ring(T, r_out, u, v, k / 12.0)))
        lamp = 0.05 * D          # a small can pointing along the beam
        back = _sub(P, _mul(axis, 1.6 * lamp))
        circle(P, lamp, u, v, rgb, n=24)
        circle(back, 0.6 * lamp, u, v, rgb, n=24)
        for k in range(4):
            segs.append((rgb, ring(P, lamp, u, v, k / 4.0),
                         ring(back, 0.6 * lamp, u, v, k / 4.0)))
        for w in (u, v, axis):   # aim cross
            segs.append((rgb, _sub(T, _mul(w, 0.03 * D)),
                         _add(T, _mul(w, 0.03 * D))))
    world = [l for l in _state['rig'] if l.get('mode') == 1]
    C = None
    if 'camera' in _state and world:
        C, M, cam_dist, fov, aspect = _state['camera']
        far = max(_norm(_sub([l['px'], l['py'], l['pz']],
                             [l['tx'], l['ty'], l['tz']])) for l in world)
        centre = _mean([[l['tx'], l['ty'], l['tz']] for l in world])
        if _norm(_sub(C, centre)) > 1.2 * far:   # pull in, keep direction
            C = _add(centre, _mul(_unit(_sub(C, centre)), 1.2 * far))
    for l in world:
        if l['_S'] is not None and C is not None:
            S, N = l['_S'], l['_N']
            D = _norm(_sub([l['px'], l['py'], l['pz']], S))
            dashed_line(C, S, (0.85, 0.85, 0.85))                    # view ray
            segs.append(((0.4, 1.0, 0.4), S, _add(S, _mul(N, 0.25 * D))))
    if C is not None:
        fwd, up, right = _mv(M, [0, 0, -1.0]), _mv(M, [0, 1.0, 0]), _mv(M, [1.0, 0, 0])
        depth = 0.2 * far
        hh = depth * math.tan(math.radians(fov / 2.0))
        hw = hh * aspect
        centre = _add(C, _mul(fwd, depth))
        corners = [_add(centre, _add(_mul(right, x * hw), _mul(up, y * hh)))
                   for x, y in ((-1, -1), (1, -1), (1, 1), (-1, 1))]
        grey = (0.85, 0.85, 0.85)
        for k in range(4):
            segs.append((grey, C, corners[k]))
            segs.append((grey, corners[k], corners[(k + 1) % 4]))
        tick = _add(centre, _mul(up, hh * 1.5))      # "up" tick on the frustum
        segs.append((grey, corners[2], tick))
        segs.append((grey, corners[3], tick))
    obj = [cgo.LINEWIDTH, 3.0, cgo.BEGIN, cgo.LINES]
    for rgb, a, b in segs:
        obj += [cgo.COLOR] + [float(x) for x in rgb]
        obj += [cgo.VERTEX] + [float(x) for x in a]
        obj += [cgo.VERTEX] + [float(x) for x in b]
    obj.append(cgo.END)
    self.delete(_GIZMO)
    self.load_cgo(obj, _GIZMO)


def _save_base(self):
    if _state['saved'] is None:
        _state['saved'] = {s: self.get(s) for s in _BASE_SETTINGS}


def _apply(rig, ambient, keep_base, self):
    _save_base(self)
    _state['rig'] = rig[:_MAX_LIGHTS]
    for light in _state['rig']:
        _resolve(light, self)
    if ambient is not None:
        self.set('ambient', ambient)
    if not keep_base:
        # specular too: PyMOL's key-light highlight is not scaled by reflect,
        # so with reflect=0 it would still sparkle white over the rig.
        self.set('direct', 0.0)
        self.set('reflect', 0.0)
        self.set('specular', 0.0)
    # The rig owns the shadow: without a shadow=1 light, the default shadow
    # would still fall from PyMOL's old key-light direction.
    self.set('metal_shadows',
             1 if any(l['shadow'] > 0.5 for l in _state['rig']) else 0)
    self.set('studio_lights', _pack(_state['rig']))


def _describe(self):
    if not _state['rig']:
        print(' studio: off')
        return
    print(' studio: %s (%d lights, ambient %s)' % (
        _state['preset'] or 'custom', len(_state['rig']), self.get('ambient')))
    if _atmo['haze'] > 0 or _atmo['dust'] > 0:
        print('   air: ' + ' '.join('%s=%g' % (k, _atmo[k]) for k in _ATMO_KEYS))
    for l in _state['rig']:
        where = next(('%s=%s' % (k, l[k]) for k in _PLACEMENT if l.get(k)),
                     'camera rig')
        print('   %-8s az=%-5g el=%-4g dist=%-3g beam=%-4.3g soft=%-4g '
              'rgb=%.2f/%.2f/%.2f int=%-4g spec=%-4g falloff=%g  [%s]%s%s' % (
                  l['name'], l['az'], l['el'], l['dist'], l['beam'], l['soft'],
                  l['r'], l['g'], l['b'], l['int'], l['spec'], l['falloff'],
                  where, '  shadow' if l['shadow'] > 0.5 else '',
                  '  cue' if l['cue'] > 0.5 else ''))


def studio(rig='', keep_base=0, quiet=0, _self=_cmd):
    '''
DESCRIPTION

    PROTOTYPE: light the scene with studio-style spot lights (Metal only).

USAGE

    studio [ preset | off | list | show ]
    studio <light> key=value ...
    studio name: key=value ... | name: key=value ...

    Light fields: az, el (degrees, camera space: az 0 = from the camera,
    90 = from the right, 180 = from behind; el 90 = from above), dist (scene
    radii, default 4), beam (full cone angle, degrees), soft (0..1 share of
    the cone that fades), int (intensity), kelvin=3200 / color=<name> /
    rgb=1/0.9/0.8, spec (highlight strength), falloff (distance exponent,
    2 = inverse square, 0 = none), aim=x/y/z (scene radii), shadow=1
    (up to three lights, each shadowing its own light),
    cue=1 (draw the beam outline on the geometry).

    World-anchored placement (fixed to the molecule once placed):
    target=<sele> aims at a selection from az/el; highlight=<sele> and
    click=sx/sy (screen -1..1) put the light where its highlight lands on
    that spot (focus=<A> sizes the beam); with rim=<deg> (e.g. 145) they
    put it behind the molecule at that angle from the camera instead, on
    the clicked side, for a rim on that edge. These fit the beam (beam=fit,
    or beam=fit1.5 for a wider margin) unless beam= is given.

    studio cue on|off      beam outlines for every light
    studio haze=0.4 dust=0.5 [dust_size=0.35 scatter=0.55 seed=0
                              dust_speed=1]
                           light scattering in the air, and dust motes that
                           glint only inside the beams (Metal post pass); the
                           dust drifts (dust_speed=0 freezes it and stops the
                           continuous redraw); `studio air off` clears them
    studio gizmo [off]     CGO object showing the lights, cones and camera

    The rig replaces PyMOL's headlight and key light (direct, reflect and
    specular are set to 0) unless keep_base=1. `studio off` restores what was there.
    '''
    self = _self
    text = (rig or '').strip()
    # LITERAL parsing hands the whole line over, keep_base included.
    if text.endswith('keep_base=1') or text.endswith('keep_base=0'):
        keep_base = int(text[-1])
        text = text[:-len('keep_base=1')].rstrip(' ,')
    keep_base = int(keep_base)
    # ambient=X, and the atmosphere's haze= dust= dust_size= scatter= seed=,
    # anywhere on the line apply to the whole scene, not to one light
    ambient = None
    atmo_changed = False
    tokens = text.split()
    for token in list(tokens):
        key = token.split('=', 1)[0].lower()
        if '=' in token and key == 'ambient':
            ambient = float(token.split('=', 1)[1])
            tokens.remove(token)
        elif '=' in token and key in _ATMO_KEYS:
            _atmo[key] = float(token.split('=', 1)[1])
            atmo_changed = True
            tokens.remove(token)
    text = ' '.join(tokens)
    if atmo_changed:
        _write_atmo(self)
    word = text.split()[0].lower() if text else (
        'show' if ambient is None and not atmo_changed else '')

    if word in ('show', 'status'):
        _describe(self)
        return
    if not word:   # only ambient= / atmosphere settings
        if ambient is not None:
            self.set('ambient', ambient)
        if not int(quiet):
            _describe(self)
        return
    if word == 'air' and text.split()[1:2] == ['off']:
        _atmo.update(_ATMO_DEFAULTS)
        _write_atmo(self)
        return
    if word == 'list':
        for name, (desc, _amb, _lights) in sorted(PRESETS.items()):
            print('   %-12s %s' % (name, desc))
        return
    if word == 'gizmo':
        if text.split()[1:2] == ['off']:
            self.delete(_GIZMO)
        else:
            _gizmo(self)
        return
    if word == 'cue':
        on = 0.0 if text.split()[1:2] == ['off'] else 1.0
        for light in _state['rig']:
            light['cue'] = on
        self.set('studio_lights', _pack(_state['rig']))
        return
    if word in ('off', 'none', '0'):
        self.delete(_GIZMO)
        self.set('studio_lights', '')
        _atmo.update(_ATMO_DEFAULTS)
        _write_atmo(self)
        if _state['saved'] is not None:
            for key, value in _state['saved'].items():
                self.set(key, value)
        _state.update(rig=[], saved=None, preset='')
        if not int(quiet):
            print(' studio: off (lighting restored)')
        return
    if word in PRESETS:
        _desc, preset_ambient, lights = PRESETS[word]
        _state['preset'] = word
        _apply(lights(), preset_ambient if ambient is None else ambient,
               keep_base, self)
    elif '=' in text and ':' not in text and '|' not in text and \
            word in [l['name'] for l in _state['rig']]:
        # tweak one light of the current rig
        light = next(l for l in _state['rig'] if l['name'] == word)
        for token in text.split()[1:]:
            key, value = token.split('=', 1)
            _set_field(light, key, value, self)
        _resolve(light, self)
        if ambient is not None:
            self.set('ambient', ambient)
        self.set('studio_lights', _pack(_state['rig']))
    else:
        lights = [_parse_light(part, self, i)
                  for i, part in enumerate(text.split('|')) if part.strip()]
        _state['preset'] = ''
        _apply(lights, ambient, keep_base, self)
    if not int(quiet):
        _describe(self)
