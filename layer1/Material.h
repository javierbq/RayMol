/*
 * Materials (#503): the named material table.
 *
 * A material says what a representation is MADE OF, the way colour says what
 * it IS. Ids — not names — are what `cartoon_material`, `surface_material`,
 * `stick_material`, `sphere_material` and `material_default` store, so the
 * values round-trip through `.pse` and through builds that predate a given
 * material. Id 0 is `default`: today's shading, byte for byte.
 *
 * Names live here, on the C side, so `get`, the `Setting: ... set to ...`
 * feedback line, the Settings panel and `.pml` logs all show `marble` rather
 * than `7` — and `set` takes those same names back (the Python side maps them
 * through `_cmd.get_material_names`), so `get` never reports something `set`
 * would refuse. An id with no row is not renamed and resolves to `default` at
 * draw time; a NAME never falls back, it is an error at set time.
 */

#pragma once

struct PyMOLGlobals;
struct CSetting;
struct CoordSet;
namespace pymol { class CObject; }

/* The function-constant axis the Metal pipelines are specialised on. Family 0
   compiles to today's code, so a `default` draw is byte for byte unchanged. */
enum {
  cMaterialFamily_default = 0,
  cMaterialFamily_procedural,
  cMaterialFamily_reflective,
  cMaterialFamily_glass,
  cMaterialFamily_count
};

/* Material ids. Append only: these are written into .pse files. */
enum {
  cMaterial_default = 0,
  cMaterial_matte,
  cMaterial_plastic,
  cMaterial_metallic,
  cMaterial_glass,
  cMaterial_frosted_glass,
  cMaterial_jelly,
  cMaterial_marble,
  cMaterial_clay,
  cMaterial_rubber,
  cMaterial_count
};

/**
 * What a material resolves to for one draw. A pure function of the material id
 * and the representation: it writes no setting and never touches colour.
 *
 * `family` is the function-constant axis the pipelines are specialised on
 * (default / procedural / reflective / glass); family 0 compiles to today's
 * code. `mode` selects within a family. `p` carries the per-material knobs
 * (grain, frequency, vein sharpness, ...). `wantsPeel` asks the scene loop to
 * keep only this object's nearest transparent layer.
 *
 * Mirrored field for field by `MaterialU` on the Metal side, which appends the
 * object's inverse modelview. Floats and ints only.
 */
struct MaterialParams {
  int family = 0;
  int mode = 0;
  float reflect = 0.0f;
  float tint = 0.0f;
  float rough = 0.0f;
  float p[6] = {0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f};
  int wantsPeel = 0;
};

/**
 * The material setting a representation reads, or 0 for the representations
 * that keep default shading in v1 (ribbon, mesh, dots, lines, labels).
 *
 * `stick_ball` spheres are emitted by the STICK rep, so they arrive here as
 * cRepCyl and take `stick_material`, not `sphere_material`.
 */
int MaterialSettingForRep(int repType);

/**
 * The layer whose material SETTINGS a draw of `repType` reads: its own, except
 * that side chains follow the cartoon.
 *
 * A stick or sphere layer with no material of its own -- `stick_material` /
 * `sphere_material` set on neither the state nor the object, and `default`
 * globally -- returns cRepCartoon while the object shows a cartoon on any
 * POLYMER atom (`show cartoon` also marks ligands, which draw none), so it
 * draws with the cartoon's material AND its Custom knobs. Picking a
 * material for the layer, `default` included, makes it independent again.
 * Every other rep, and every object that is not a molecule, returns `repType`.
 *
 * Per object, not per atom: a ligand shown as sticks in the same object follows
 * too. Surfaces never follow. Only the SETTING is borrowed -- the degradations
 * of MaterialResolve stay keyed on the rep that draws (glass on sphere
 * impostors), so pass the real rep to it.
 *
 * With every material at `default` this changes nothing that is drawn: the
 * cartoon then resolves to `material_default`, which is what the layer would
 * have resolved to itself.
 *
 * @param obj the object, so its shown reps can be consulted; may be null
 */
int MaterialSourceRep(PyMOLGlobals* G, const CSetting* set1,
    const CSetting* set2, int repType, const pymol::CObject* obj);

/**
 * Does the layer have a material of its OWN -- the half of MaterialSourceRep
 * that does not depend on what is shown? True for a rep that takes no
 * material at all.
 */
bool MaterialLayerHasOwnMaterial(PyMOLGlobals* G, const CSetting* set1,
    const CSetting* set2, int repType);

/**
 * Resolve the material id for one draw: the rep's OBJECT-level value (or
 * object-state), then the rep's global value, then `material_default`.
 *
 * An object-level value wins outright even when it is `default` — that is how
 * a user turns a global material off for one object. A global rep value only
 * loses to `material_default` when it is itself `default`, since a global has
 * no "undefined" state to distinguish.
 *
 * @param set1 coordinate-set (object-state) settings, may be null
 * @param set2 object settings, may be null
 */
int MaterialResolveSettingId(
    PyMOLGlobals* G, const CSetting* set1, const CSetting* set2, int repType);

/**
 * True when at least one IMPLEMENTED material belongs to this family, so the
 * renderer knows which specialised pipelines are worth building. The default
 * family is always in use. As later waves flip `implemented` flags this grows;
 * a family nothing can draw costs no pipeline.
 */
bool MaterialFamilyIsImplemented(int family);

/**
 * Number of rows in the material table.
 */
int MaterialTableSize();

/**
 * True when a material can actually draw today. The names API hides the rest,
 * so the Inspector dropdown grows wave by wave instead of offering looks that
 * would silently render as `default`. Setting one by name still works: it is a
 * real material id, it just has no shader yet.
 */
bool MaterialIsImplemented(int id);

/**
 * The ALPHA -- opacity, where 1 is fully solid -- that a glass-family material
 * implies, or 0 when it implies none. Clear `glass` is 0.15, i.e. mostly
 * see-through. Callers that want a TRANSPARENCY must use 1 - alpha;
 * MaterialEffectiveTransparency is the one place that conversion lives.
 *
 * Consulted at REP-BUILD time in layer2, beside the rep's own transparency
 * setting, and only when that setting is 0 -- the user's transparency slider
 * still wins. It is never written back as a setting: a `.pse` opened in an
 * older build renders an opaque surface, visible and wrong, never invisible.
 */
float MaterialImpliedAlpha(int id);

/**
 * The transparency a representation should build with (#495).
 *
 * `transparency` is the rep's own setting, already resolved. When it is 0 and
 * the rep's material implies an opacity -- the glass family does -- the implied
 * value is used instead. The user's slider always wins: a non-zero setting is
 * returned untouched, so turning glass down to opaque stays possible.
 *
 * Implied alpha is a rep-BUILD input, never written back as a setting. A .pse
 * opened in a build that does not know the material then renders an opaque
 * surface -- visible and wrong -- rather than an invisible one.
 *
 * @param set1 coordinate-set settings, may be null
 * @param set2 object settings, may be null
 * @param repType the cRep_t whose material to consult
 * @param transparency the rep's own resolved transparency (0 = opaque)
 * @param cs the coordinate set, so ATOM-level overrides of `stick_ball` are
 *        seen; without it only the object-level value is consulted
 */
float MaterialEffectiveTransparency(PyMOLGlobals* G, const CSetting* set1,
    const CSetting* set2, int repType, float transparency,
    const CoordSet* cs = nullptr);

/**
 * The parameters a material id renders with on a given representation.
 *
 * Also where a material that cannot draw on a representation degrades to
 * `default` (glass on sphere impostors, for one) rather than glitching.
 *
 * The table behind this arrives with the material table itself (#486); today
 * every id resolves to `default`, so declaring a material changes nothing that
 * is drawn.
 */
MaterialParams MaterialResolve(int id, int repType);

/**
 * The parameters a representation actually DRAWS with: the resolved material id
 * put through MaterialResolve, plus the degradation rules that depend on a
 * SETTING rather than on the rep alone (glass on `stick_ball` sticks).
 *
 * The single definition of "what this rep is made of". Shading and implied
 * alpha both go through it, because they have to agree: a rep that shades as
 * `default` but still builds transparent is not rendering `default`.
 */
MaterialParams MaterialResolveForDraw(PyMOLGlobals* G, const CSetting* set1,
    const CSetting* set2, int repType, const CoordSet* cs = nullptr);

/* The knobs of the Custom material (#568). A slot is one of the overridable
   MaterialParams fields; the per-rep override settings are ordered the same
   way (`<rep>_material_reflect`, `_tint`, `_rough`, `_knob1`..`_knob6`). */
enum MaterialKnobSlot {
  kKnob_reflect = 0,
  kKnob_tint,
  kKnob_rough,
  kKnob_p0,   // knob1
  kKnob_p1,
  kKnob_p2,
  kKnob_p3,
  kKnob_p4,
  kKnob_p5,   // knob6
  kMaterialKnobSlotCount
};

struct MaterialKnob {
  int slot;            // MaterialKnobSlot
  const char* label;   // what it does, for the Inspector
  // A sensible slider range (the core clamps nothing); for a toggle, the off
  // and on values the Inspector writes.
  float min, max;
  // Shown as an on/off switch (min off, max on) rather than a slider. The
  // value is still an amount: the shader scales by it, so the command line
  // can set anything between.
  bool toggle = false;
};

/**
 * The knobs material `id` has -- the slots its shader actually reads -- in
 * display order. Returns their count (0 for `default` and unimplemented ids)
 * and points `*knobs` at them. An override of any other slot is ignored.
 */
int MaterialKnobs(int id, const MaterialKnob** knobs);

/**
 * The FINAL parameters a draw uses: MaterialResolveForDraw, with reflect / tint /
 * rough zeroed for every family that does not own them (all but reflective and
 * glass), then the layer's Custom overrides of the knobs its material has
 * (MaterialKnobs, #568).
 *
 * The draw site is a thin caller of this, so the rules stay in one place and
 * can be asserted from Python without a Metal context.
 */
MaterialParams MaterialDrawParams(PyMOLGlobals* G, const CSetting* set1,
    const CSetting* set2, int repType, const CoordSet* cs = nullptr);

/**
 * MaterialDrawParams for the DRAW path, taking the `stick_ball` answer that the
 * rep cached at build time (Rep::emitsStickBalls) instead of rescanning atoms.
 *
 * metalApplyRepMaterial runs per draw op, per pass, per frame; the scan is
 * O(atoms) and its worst case -- a full scan, no early out -- is exactly the
 * configuration the rule targets, glass sticks with no balls.
 */
MaterialParams MaterialDrawParamsCached(PyMOLGlobals* G, const CSetting* set1,
    const CSetting* set2, int repType, bool emitsStickBalls,
    const pymol::CObject* obj = nullptr);

/**
 * Does this stick rep emit any `stick_ball` sphere? Atom-level, so this scans.
 * Call once at rep-build time and cache on the rep.
 */
bool MaterialRepEmitsStickBalls(PyMOLGlobals* G, const CoordSet* cs,
    const CSetting* set1, const CSetting* set2);

/**
 * What the CPU ray tracer (`ray`) does with a material (#499).
 *
 * `ray` has none of the Metal shaders, so a material reaches it as the few
 * knobs its lighting model already has, best effort:
 *
 *   - `wobble` is a `ray_texture` mode -- the bump textures `ray` has had all
 *     along. marble -> 2 (Swirl 1), clay -> 1 (Matte 1), rubber -> 4 (Matte 2),
 *     frosted_glass -> 1 (Matte 1, on top of its implied transparency).
 *     Only the MODE comes from the material. The texture's knobs stay the
 *     user's `ray_texture_settings`, because CRay holds ONE WobbleParam triple
 *     per render: a material that brought its own would be overwritten by the
 *     next representation's, silently. So a marble surface renders exactly as
 *     the same surface under `ray_texture 2`, which is what makes the mapping
 *     testable.
 *   - `specular`, `diffuse` and `specTint` shape the highlight per PRIMITIVE:
 *     the highlight is scaled by `specular`, the lit diffuse term by `diffuse`,
 *     and `specTint` mixes the highlight from white (0) toward the primitive's
 *     own colour (1). The base colour itself is never changed.
 *
 * Limits, all of them `ray`'s own rather than the table's: the positional
 * textures (Swirl 1, Matte 2) are evaluated in camera space, so they slide as
 * the camera moves, and Matte 1 is per-sample noise with no pattern to lock
 * (see MaterialRayParamsFor); the tint applies to the lit surface's highlight,
 * not to the `ray_transparency_specular` highlight carried through a
 * transparent layer, which stays white; and the scene EXPORTS read neither the
 * texture nor these knobs -- a metallic object exports with the default
 * finish. Of the implied transparency, .dae and .gltf carry it on every
 * primitive; .pov carries it on triangles only; .idtf exports ONLY triangles
 * (spheres and sticks are left out of the file), and carries it on those;
 * .wrl and .obj carry none.
 *
 * `default` is {0, 1, 1, 0}: no texture and today's lighting, byte for byte.
 * So are glass and jelly -- the glass family reaches `ray` through the
 * transparency it implies at rep-build time (MaterialEffectiveTransparency),
 * and only frosted_glass adds a texture on top.
 */
struct MaterialRayParams {
  int wobble = 0;
  float specular = 1.0f;
  float diffuse = 1.0f;
  float specTint = 0.0f;
};

/**
 * MaterialRayParams for a material id. An id with no row, or one not
 * implemented, gets `default`'s.
 */
MaterialRayParams MaterialRayParamsFor(int id);

/**
 * The material id `ray` stamps on a representation's primitives: the
 * representation's material after the draw-time degradations
 * (MaterialResolveForDraw), so `ray` and the viewport agree about what the
 * rep is made of. 0 for reps that take no material. Resolved ONCE per rep and
 * handed to MaterialRayWobble, because for a glass stick rep the resolve scans
 * every atom for `stick_ball`.
 */
int MaterialRayId(PyMOLGlobals* G, const CSetting* set1,
    const CSetting* set2, int repType, const CoordSet* cs = nullptr);

/**
 * The `ray_texture` mode a representation is traced with. An EXPLICIT
 * `ray_texture` wins outright over the material's:
 *
 *   - a value set on the object or its state, whatever it is -- 0 included,
 *     which is how a marble surface is traced without the swirl;
 *   - otherwise the global value, if non-zero. The global 0 is also the
 *     default, and cannot say whether it was chosen, so it is not explicit.
 *
 * Only when neither applies does the material's mode (MaterialRayParamsFor)
 * take effect. For `default`, whose mode is 0, this returns exactly the
 * resolved `ray_texture` the tracer always used.
 *
 * @param materialId from MaterialRayId
 */
int MaterialRayWobble(PyMOLGlobals* G, const CSetting* set1,
    const CSetting* set2, int materialId);

/**
 * Name of a material id, or nullptr when no row has that id.
 */
const char* MaterialGetName(int id);

/**
 * Shading family of a material id, or -1 when no row has that id.
 *
 * Exposed so a test can ask which family a material belongs to. Without it the
 * only Python-visible facts are the id, the name and whether it is implemented
 * -- so a test that means "no implemented material is reflective yet" cannot
 * express itself and quietly asserts something else instead. That happened
 * (#493's own guard), which is why this exists.
 */
int MaterialGetFamily(int id);

/**
 * The material id a representation EFFECTIVELY draws with, after the per-rep
 * degradation in MaterialResolve (glass on sphere impostors, for one, which
 * would otherwise float as near-invisible discs).
 *
 * Distinct from MaterialResolveSettingId, which answers what the SETTING says.
 * Both matter: the setting keeps the user's intent across a .pse, while this is
 * what actually reaches the shader. Exposed so the difference is testable.
 */
int MaterialEffectiveId(int id, int repType);

/**
 * True for the four PER-REPRESENTATION material settings.
 */
bool MaterialIsRepMaterialSetting(int index);

/**
 * The transparency setting a representation reads, or 0 when it has none.
 *
 * `transparency` for a surface, `cartoon_transparency` for a cartoon, and so
 * on. Returning 0 for the rest matters: mapping every unknown rep onto
 * `transparency` would report the SURFACE's value for a mesh or a ribbon.
 */
int MaterialTransparencySettingForRep(int repType);

/**
 * Whether an object's transparent geometry should be depth-PEELED (#488):
 * a colour-less depth pre-pass, then the object's transparent draws tested for
 * equality against it, so only the nearest surface per pixel contributes.
 * Without it a translucent ball-and-stick reads as dense mottle -- the front
 * and back of every stick, and every stick behind it, all accumulate.
 *
 * `transparency_peel` decides: 1 on, 0 off, and -1 (the default) means AUTO --
 * on when any of the object's four representations resolves to a material whose
 * row asks for it (`wantsPeel`, which the glass family sets). Auto is
 * deliberately not "any transparent object": peeling a plain translucent
 * surface changes a look users already rely on, and it costs a depth blit and
 * two encoder boundaries per object per grid cell.
 *
 * Auto also REFUSES when the object has another transparent representation
 * that did not ask to be peeled -- peeling is object-scoped, so turning it on
 * would erase that rep. Pass the object so the already-BUILT reps can be asked:
 * the four transparency settings are atom- and bond-level and are routinely
 * written through a selection, which leaves the object-level value at 0.
 *
 * @param set1 coordinate-set (object-state) settings, may be null
 * @param set2 object settings, may be null
 * @param obj the object, so its built reps can be consulted; may be null
 */
bool MaterialObjectWantsPeel(PyMOLGlobals* G, const CSetting* set1,
    const CSetting* set2, const pymol::CObject* obj = nullptr);

/**
 * True for every setting whose value is a material id (the four
 * per-representation ones plus `material_default`) — i.e. every setting whose
 * value `get` should render as a NAME rather than as a number.
 */
bool MaterialIsMaterialSetting(int index);

/**
 * True for the object-scoped settings a SELECTION-scoped `set` is refused for:
 * the four per-representation materials plus `transparency_peel`. They are
 * ints, so the generic selection path would write an atom-level value on every
 * matched atom that no draw path reads -- a success message and no change.
 */
bool MaterialIsSelectionRejectedSetting(int index);

