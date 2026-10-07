#!/usr/bin/env python3
"""The studio lights gallery (#627): every section of docs/lighting.md's
pictures, rendered headless with a built RayMol.app through the lighting
harness (scripts/lighting/render.py, unmodified).

Seven sections, each a list of harness tags from one scene file:

    rigs       PyMOL's own lights, then each preset          scenes/gallery.json
    light      one light field at a time                     scenes/gallery.json
    place      target=, highlight= and rim=, camera vs pin   scenes/gallery.json
    shadows    per-light coloured shadows, raster and traced scenes/gallery.json
    air        haze, dust and shafts; the pinned dust clock  scenes/gallery.json
    exposure   HDR roll-off, exposure and the 8-bit knee     scenes/lighting_624.json
    materials  every material under three_point              scenes/lighting_615_gallery.json

SECTIONS below is the one table: per section its title, the caption (the
commands it shows), the scene file, the tags in sheet order, the sheet's
columns, the reference pairs its difference checks compare (tag, reference)
and the per-pair overrides of those checks, each with its reason.

Names never contain 'preset' (it holds 'reset', a word the harness refuses
in any path, #646): the presets section is `rigs`.
"""
import collections
import importlib.util
import os

HERE = os.path.dirname(os.path.abspath(__file__))
SCENES_DIR = os.path.join(HERE, 'scenes')

Section = collections.namedtuple('Section', (
    'name',       # section name: the sheet is <out>/<name>.png
    'title',      # the sheet's heading
    'caption',    # the commands the section shows
    'scenes',     # scene file, relative to scripts/lighting/scenes
    'tags',       # harness tags, in sheet order
    'cols',       # sheet columns
    'refs',       # ((tag, reference tag), ...): the pair must differ
    'overrides',  # {(tag, reference tag): {'level': n, 'share': f, 'reason': text}}
))

PRESET_NAMES = ('three_point', 'softbox', 'spotlight', 'rembrandt', 'neon',
                'sunset', 'underlight')
MATERIALS = ('default', 'matte', 'plastic', 'metallic', 'glass',
             'frosted_glass', 'jelly', 'marble', 'clay', 'rubber')


def _rows(*rows):
    """Consecutive pairs within each row: (b, a), (c, b), ..."""
    return tuple((row[i], row[i - 1]) for row in rows for i in range(1, len(row)))


_LIGHT_ROWS = (
    ('light_beam_8', 'light_beam_15', 'light_beam_28'),
    ('light_soft_0', 'light_soft_0p5', 'light_soft_1'),
    ('light_warm_2200', 'light_warm_6500', 'light_warm_12000'),
    ('light_colour_white', 'light_colour_orange', 'light_colour_hotpink'),
)

SECTIONS = [
    Section(
        'rigs', 'Presets',
        "lights <preset>: PyMOL's own lights (no rig), then three_point, "
        'softbox, spotlight, rembrandt, neon, sunset and underlight',
        'gallery.json',
        ('rig_none',) + tuple('rig_' + p for p in PRESET_NAMES),
        4,
        tuple(('rig_' + p, 'rig_none') for p in PRESET_NAMES),
        {}),
    Section(
        'light', 'One light, one field at a time',
        'lights add, key, orbit=-25, pitch=35, radius=3, intensity=1.5, '
        'shadow=1 and, by row: beam=8/15/28 (softness=0.3); softness=0/0.5/1 '
        '(beam=15); warmth=2200/6500/12000; color=white/orange/hotpink with '
        'a white/skyblue/cyan rim at orbit=160',
        'gallery.json',
        sum(_LIGHT_ROWS, ()),
        3,
        _rows(*_LIGHT_ROWS),
        {}),
    Section(
        'place', 'Placing a light',
        'lights add, key, target=<sele> (outline=1, then 0); '
        'lights add, key, highlight=<sele> (then rim=145); '
        "a camera light vs pin=1, then turn y, 90",
        'gallery.json',
        ('place_target', 'place_target_final', 'place_highlight',
         'place_highlight_rim', 'place_camera_turned', 'place_pinned_turned'),
        2,
        (('place_target_final', 'place_target'),
         ('place_highlight_rim', 'place_highlight'),
         ('place_pinned_turned', 'place_camera_turned')),
        {}),
    Section(
        'shadows', 'Per-light shadows',
        'red and blue lights from either side: no shadows, shadow=1 on red, '
        'on both, four lights with three shadowed (the cap), both with '
        'metal_raytrace 1',
        'gallery.json',
        ('shadow_none', 'shadow_red', 'shadow_both', 'shadow_cap',
         'shadow_both_rt1'),
        3,
        (('shadow_red', 'shadow_none'), ('shadow_both', 'shadow_red')),
        {}),
    Section(
        'air', 'Haze and dust',
        'atmosphere haze=0.6, then dust=0.6 (metal_raytrace 0 and 1 side by '
        'side); a backlit haze; crossing red and blue beams; dust alone at '
        'metal_light_air_time 0, 1 and 2',
        'gallery.json',
        ('air_none', 'air_haze', 'air_backlit',
         'air_dust', 'air_dust_rt1', 'air_crossing',
         'air_dust_t0', 'air_dust_t1', 'air_dust_t2'),
        3,
        (('air_haze', 'air_none'), ('air_dust', 'air_haze'),
         ('air_dust_t1', 'air_dust_t0'), ('air_dust_t2', 'air_dust_t1')),
        {}),
    Section(
        'exposure', 'Exposure and HDR',
        'a spot at intensity 3.5, then metal_exposure 0.5; an orange key and '
        'cyan rim at 2.5x with HDR, then metal_light_hdr 2 (the 8-bit knee); '
        'three_point (its rim behind the molecule) with haze 0.35 and dust '
        '0.6 at metal_exposure 1, then 0.5 (#683)',
        'lighting_624.json',
        ('sweep_3p5_rt0', 'sweep_3p5_e05_rt0', 'hue_x2p5_rt0',
         'hue_x2p5_knee_rt0', 'haze683_e1_rt0', 'haze683_e05_rt0'),
        2,
        (('sweep_3p5_e05_rt0', 'sweep_3p5_rt0'),
         ('hue_x2p5_knee_rt0', 'hue_x2p5_rt0'),
         ('haze683_e05_rt0', 'haze683_e1_rt0')),
        {}),
    Section(
        'materials', 'Materials under three_point',
        'lights three_point over set surface_material, <material> for each '
        'of the ten materials',
        'lighting_615_gallery.json',
        tuple('g%02d_%s__c1_three_point' % (n, m) for n, m in enumerate(MATERIALS)),
        5,
        tuple(('g%02d_%s__c1_three_point' % (n, m), 'g00_default__c1_three_point')
              for n, m in enumerate(MATERIALS) if n),
        {}),
]


def load_render():
    """scripts/lighting/render.py, the frozen harness beside this file."""
    spec = importlib.util.spec_from_file_location(
        'lighting_render', os.path.join(HERE, 'render.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module
