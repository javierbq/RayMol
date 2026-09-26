"""Metal shader source hygiene: cross-library helper visibility and raw-string
termination in RendererMetal.mm.

RendererMetal.mm compiles its post-processing library (kPostSrc) and its
ray-tracing library (kRTSrc) from separate MSL string literals with
newLibraryWithSource:, each with the shared kEyeReconSrc block prepended. Metal
does no cross-library linking, so a helper defined only in kPostSrc is an
undeclared identifier in kRTSrc. That is a RUNTIME shader-compile failure no
C++ build catches: the RT pipelines are never created and metal_raytrace
silently does nothing (PR #100 fixed exactly that after the #83/#87 shadow work
moved post_eye_* into kPostSrc). rt_composite's depth-aware AO blur now calls
post_linear_depth as well, so that helper has to live in the shared block too.

The literals are Objective-C raw strings, @R"(...)", which end at the FIRST
')"'. A ')"' anywhere in the shader text -- a quoted expression in a comment
is enough -- truncates the literal and breaks the C++ compile.

Pure source parsing: no GPU and no Metal toolchain, so it runs everywhere.

    pymol -ckqy testing/testing.py --run tests/raymol/metal_shader_sources.py
"""
import os
import re

from pymol import testing

SOURCE = os.path.join('layerGraphics', 'metal', 'RendererMetal.mm')

_LITERAL = re.compile(r'static NSString\* const (k\w+) = @R"\((.*?)\)"(.)', re.S)
# Hand-written helpers in these literals are post_* / rt_* / mat_*; everything
# else that looks like a call is an MSL builtin (smoothstep, sample_compare...).
_DEF = re.compile(
    r'^\s*(?:static\s+|fragment\s+|vertex\s+)?[\w:<>]+\s+((?:post|rt|mat)_\w+)\s*\(',
    re.M)
_CALL = re.compile(r'\b((?:post|rt|mat)_\w+)\s*\(')

# Which shared block(s) each library is compiled with. Mirrors the
# newLibraryWithSource: call sites in RendererMetal.mm; a library that gained a
# helper from a block it is NOT built with would fail only at runtime, with
# nothing but an NSLog.
_PREPENDED = {
    'kPostSrc': ('kEyeReconSrc',),
    'kRTSrc': ('kEyeReconSrc',),
    'kVBOSrc': ('kMaterialSrc',),
    'kSphereImpostorSrc': ('kMaterialSrc', 'kMaterialImpostorSrc'),
    'kCylinderImpostorSrc': ('kMaterialSrc', 'kMaterialImpostorSrc'),
}


def _strip_comments(text):
    """MSL // comments removed, so a commented-out branch does not satisfy a
    substring check.

    Block comments would need the same treatment; no literal uses one today and
    testNoBlockCommentsInTheShaderLiterals keeps it that way, because a `/* */`
    around a dispatch would slip past every check in this file.
    """
    return re.sub(r'//[^\n]*', '', text)


def _function_body(literal, name):
    """The body of `name`, from its signature to the matching closing brace.

    Slicing from the name to the end of the literal -- which this test did at
    first -- is not the function: it is every later function too, so a check
    for "does this function dispatch jelly" passed when the dispatch had moved
    somewhere else entirely.

    Comments are stripped BEFORE the braces are counted, not after. These
    literals already contain braces inside comments elsewhere (kVBOSrc has
    `// {0,0,1})`, kRTSrc has a `{`...`}` pair spanning two comment lines), so
    counting the raw text would end the slice early on a stray `}` or run it
    into the next function on a stray `{` -- reintroducing the defect this
    helper exists to remove.
    """
    literal = _strip_comments(literal)
    start = literal.index(name)
    open_brace = literal.index('{', start)
    depth = 0
    for i in range(open_brace, len(literal)):
        if literal[i] == '{':
            depth += 1
        elif literal[i] == '}':
            depth -= 1
            if depth == 0:
                return literal[start:i + 1]
    raise AssertionError('unbalanced braces after %s' % name)


def shader_literals(source):
    """{name: body} for every @R"(...)" literal in `source`.

    Raises AssertionError when a literal is cut short by a ')"' inside the
    shader text, which is what the C++ compiler would see too.
    """
    literals = {}
    for match in _LITERAL.finditer(source):
        name, body, after = match.groups()
        if after != ';':
            raise AssertionError(
                '%s: raw string terminated early by \')"\' in the shader text, '
                'near %r' % (name, body[-60:]))
        literals[name] = body
    return literals


def undefined_helpers(body):
    """post_/rt_ helpers that `body` calls but does not define."""
    return set(_CALL.findall(body)) - set(_DEF.findall(body))


class TestMetalShaderSources(testing.PyMOLTestCase):

    def source(self):
        root = os.path.join(os.path.dirname(__file__), os.pardir, os.pardir,
                            os.pardir)
        path = os.path.normpath(os.path.join(root, SOURCE))
        if not os.path.isfile(path):
            # Skipped, not passed: a source-reading test that cannot find its
            # source has checked nothing. Only reached outside a repo checkout.
            self.skipTest('%s not present; not a repo checkout' % SOURCE)
        with open(path) as handle:
            return handle.read()

    def testRawStringsEndWhereIntended(self):
        literals = shader_literals(self.source())
        for name in ('kEyeReconSrc', 'kPostSrc', 'kRTSrc', 'kMaterialSrc',
                     'kMaterialImpostorSrc', 'kVBOSrc', 'kSphereImpostorSrc',
                     'kCylinderImpostorSrc'):
            self.assertIn(name, literals)

    def testEachLibraryIsSelfContained(self):
        """Every helper a library calls is visible in shared + that library."""
        literals = shader_literals(self.source())
        for lib, shared_names in sorted(_PREPENDED.items()):
            shared = ''.join(literals[n] for n in shared_names)
            missing = undefined_helpers(shared + literals[lib])
            self.assertFalse(
                missing, '%s calls helpers it cannot see at runtime: %s'
                % (lib, sorted(missing)))

    def testTheMaterialBlockReachesEveryLitLibrary(self):
        """kMaterialSrc is what stops the three lit libraries drifting apart --
        the prototype hand-copied its noise into each and they diverged (the
        cylinder lost a grain octave, marble never reached the impostors)."""
        source = self.source()
        for lib in ('kVBOSrc', 'kSphereImpostorSrc', 'kCylinderImpostorSrc'):
            self.assertIn(
                'stringByAppendingString:%s]' % lib, source,
                '%s must be compiled with the shared material block' % lib)
        # ...and the noise lives in ONE place.
        literals = shader_literals(source)
        for lib in ('kVBOSrc', 'kSphereImpostorSrc', 'kCylinderImpostorSrc'):
            self.assertNotIn('float mat_noise(', literals[lib],
                             '%s re-declares the shared noise' % lib)

    def testTheFamilyConstantMatchesTheCEnum(self):
        """`kMatProcedural` hard-codes the procedural family's id. If the C enum
        ever gains a family before it, every procedural material would be
        shaded as whatever moved into slot 1 -- with the pipelines still
        specialised correctly, so nothing else would notice."""
        import os
        literals = shader_literals(self.source())
        msl = literals['kMaterialSrc']
        root = os.path.join(os.path.dirname(__file__), os.pardir, os.pardir,
                            os.pardir)
        header = os.path.normpath(os.path.join(root, 'layer1', 'Material.h'))
        if not os.path.isfile(header):
            self.skipTest('layer1/Material.h not found (not a repo checkout)')
        with open(header) as handle:
            enum = handle.read()
        families = [line.strip().rstrip(',').split(' ')[0]
                    .replace('cMaterialFamily_', '')
                    for line in enum[enum.index('enum {'):].splitlines()[1:]
                    if line.strip().startswith('cMaterialFamily_')]
        self.assertIn('procedural', families)
        declared = re.search(r'constant bool kMatProcedural\s*=\s*\(kMatFamily == (\d+)\);',
                             msl)
        self.assertIsNotNone(declared, 'kMatProcedural not found in kMaterialSrc')
        self.assertEqual(int(declared.group(1)), families.index('procedural'),
                         'kMatProcedural disagrees with layer1/Material.h')

    def testTheMaterialModeConstantsMatchTheCTable(self):
        """The MSL dispatch compares against literal ids. If Material.h ever
        renumbers a material, the shader would silently shade the wrong one."""
        import os
        literals = shader_literals(self.source())
        root = os.path.join(os.path.dirname(__file__), os.pardir, os.pardir,
                            os.pardir)
        header = os.path.normpath(os.path.join(root, 'layer1', 'Material.h'))
        if not os.path.isfile(header):
            self.skipTest('layer1/Material.h not found (not a repo checkout)')
        with open(header) as handle:
            enum = handle.read()
        order = [line.strip().rstrip(',').replace('cMaterial_', '')
                 for line in enum[enum.index('enum {', enum.index('Material ids')):]
                                 .splitlines()[1:]
                 if line.strip().startswith('cMaterial_')]
        ids = {name: i for i, name in enumerate(order)}
        # EVERY kMatMode_* the shader declares, not a hand-written list. The
        # list this was -- matte, marble, clay, rubber -- had not grown since
        # #487, so kMatMode_frosted_glass (#495) and kMatMode_jelly (#496) were
        # both unchecked: renumber the C enum and the glass-family pipeline
        # dispatches on a stale literal, which does not fail to draw, it draws
        # the wrong material. That is this epic's signature bug.
        # Every LITERAL too, not just the shared block. Restricting the scan
        # to kMaterialSrc would generalise over names and not over files --
        # the same shape as the hardcoded list it replaced, and it would go
        # stale the same way the moment a material declares its mode beside
        # its own helper.
        declared = {}
        for body in literals.values():
            declared.update(re.findall(
                r'constant int kMatMode_(\w+)\s*=\s*(\d+);', body))
        self.assertTrue(declared, 'no kMatMode_* constants found in the MSL')
        for name, value in declared.items():
            self.assertIn(name, ids,
                          'kMatMode_%s names no material in layer1/Material.h' % name)
            self.assertEqual(int(value), ids[name],
                             'kMatMode_%s disagrees with layer1/Material.h' % name)
        # ...and the four the procedural dispatch has always needed are still
        # among them, so deleting a constant cannot make the loop above vacuous.
        for name in ('matte', 'marble', 'clay', 'rubber'):
            self.assertIn(name, declared)

    def testNoBlockCommentsInTheShaderLiterals(self):
        """_strip_comments only understands `//`, and the dispatch checks below
        are substring searches over the stripped text. A `/* */` around a
        material's dispatch would satisfy every one of them while the branch
        never compiles, so the assumption is enforced rather than stated."""
        for name, body in shader_literals(self.source()).items():
            self.assertNotIn('/*', body,
                             '%s uses a block comment; _strip_comments only '
                             'removes // comments' % name)

    def testEveryGlassFamilyMaterialIsDispatchedInBothShadingPaths(self):
        """The glass family shares ONE pipeline and is told apart by `mode`, in
        two places: vbo_material_shade (cartoons and surfaces) and
        mat_impostor_composite (the sphere and cylinder impostors).

        Nothing else in the repo can see these branches. Delete the jelly
        dispatch from either site and every C-side test still passes -- the
        table row, the built transparency and the peel are all unchanged --
        while jelly ships shading as clear glass on half its representations.
        A source-level check is not a render, but it is the difference between
        that failure being caught and being shipped."""
        msl = shader_literals(self.source())
        shared = msl['kMaterialSrc']
        # vbo_material_shade lives in kVBOSrc (it needs LightU and vbo_shade);
        # mat_impostor_composite in kMaterialImpostorSrc. Both are compiled
        # with kMaterialSrc prepended -- see _PREPENDED above -- which is what
        # makes mat_jelly_shade visible to them.
        for site, body in (('vbo_material_shade', msl['kVBOSrc']),
                           ('mat_impostor_composite', msl['kMaterialImpostorSrc'])):
            self.assertIn(site, body)
            # _function_body strips comments before brace-matching, so the
            # slice is the function's CODE. The first version of this test
            # searched the raw text from the function's NAME to the end of the
            # library, so a dispatch that had been commented out -- or moved
            # into a later function entirely -- still matched.
            code = _function_body(body, site)
            self.assertIn('kMatMode_jelly', code,
                          '%s does not dispatch jelly' % site)
            self.assertIn('mat_jelly_shade', code,
                          '%s does not call mat_jelly_shade' % site)
            self.assertIn('kMatMode_frosted_glass', code,
                          '%s does not dispatch frosted_glass' % site)
            # ...and REACHABLE. Both sites end with an unconditional glass
            # fallback; a jelly branch after it is dead code that still
            # contains every string above.
            self.assertLess(code.index('kMatMode_jelly'),
                            code.index('mat_glass_shade'),
                            '%s dispatches jelly after the unconditional '
                            'mat_glass_shade fallback, so it never runs' % site)
        # The helper itself must be declared before the MaterialU it takes by
        # reference: the libraries are concatenated and compiled at RUNTIME, so
        # a bad order is a silent NSLog and a material that does nothing.
        self.assertLess(shared.index('struct MaterialU {'),
                        shared.index('float3 mat_jelly_shade('))

    def testRTBlurUsesTheSharedOrthoAwareDepth(self):
        """rt_composite's bilateral AO blur must reconstruct the neighbour depth
        with the same ortho-aware inverse as the centre sample (#139), not the
        perspective-only formula it inlined before."""
        rt = shader_literals(self.source())['kRTSrc']
        composite = rt[rt.index('fragment float4 rt_composite('):]
        self.assertIn('post_linear_depth(dn, u.projA, u.projB, u.projOrtho)',
                      composite)
        self.assertNotIn('-u.projB / ((2.0 * dn - 1.0) + u.projA)', composite)
