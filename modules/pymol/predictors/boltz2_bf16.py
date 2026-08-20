"""Boltz-2 with dense bfloat16 weights instead of the affine-int8 pack.

Same model, same Swift runtime, same inputs -- only the weight representation
differs, so everything but the bundle is inherited from Boltz2Predictor. The Swift
side branches on the artifact manifest (a dense pack declares no quantization
block), which is why one runtime serves both.

The trade is unfavourable on every axis measured so far, and this predictor exists
to let that be re-measured rather than argued about. On an M3 Pro at 117 tokens,
recycling 3 / 200 steps, dense bfloat16 against the int8 pack:

    pack on disk   507 MB  ->  996 MB
    wall clock    14.50 s  ->  17.76 s   (quantizedMM beats a dense fp16 matmul
                                          on these memory-bound shapes)
    peak RSS      620 MiB  ->  1012 MiB

and the structures the two produce differ by less than the model's own
seed-to-seed spread (3.1 A between packs at one seed; 4.9-7.0 A across seeds
within the int8 pack alone), so no accuracy claim in either direction is
supported yet.

NOTE ALSO: the Boltz-2 checkpoint is float32 throughout -- there are no original
bfloat16 weights to load. This pack is a narrowing of that float32, and float16
would be a strictly closer one at identical size. Both are exportable
(`boltz-mlx export-model --precision`); bfloat16 is offered because it is the
width Boltz was trained in.
"""
import sys

from .boltz2 import Boltz2Predictor
from .errors import PredictorUnavailable
from .weights import WeightBundle


class Boltz2BF16Predictor(Boltz2Predictor):

    id = 'boltz2-bf16'
    name = 'Boltz-2 (MLX, bfloat16)'

    # sha256 and size are of the zip's bytes. Unlike the int8 pack these ARE
    # reproducible from the checkpoint -- a dense export is a pure narrowing with no
    # Metal-side quantization -- but the published asset must still be re-hashed after
    # upload, because what matters is the bytes GitHub serves back.
    weight_bundle = WeightBundle(
        id='boltz2-mlx-bf16',
        version='v1',
        url='https://github.com/javierbq/boltz-mlx/releases/download/weights-bf16-v1/'
            'boltz2-mlx-bf16-v1.zip',
        sha256='9d33ba489407f0066fc3e7421e4c7b2db9f528774f28c345df9fe242087f5128',
        size=1_044_050_191,
        members=('config.json', 'manifest.json', 'model.safetensors'),
    )

    def check_available(self):
        """Available wherever Boltz is -- EXCEPT iOS.

        Not a capability limit: the bf16 runtime is the same Swift `boltz` runtime the
        int8 pack uses, so this method would load and run on a phone. It is refused
        because the iOS memory guard cannot honestly admit it.

        `PredictSizeGuard.decide` takes tokens, MSA depth and available bytes -- it does
        NOT take a predictor, so there is one fitted curve for all Boltz packs, and that
        curve was fitted to MEASURED int8 peak `phys_footprint` on an iPhone 15 Pro. The
        dense pack needs materially more than int8 at the same token count (bigger
        resident weights: 1.04 GB against 529 MB, plus wider activations). Feeding it
        through the int8 curve therefore produces an estimate BELOW the real cost, which
        is the one direction this guard must never err in: the failure mode is a jetsam
        SIGKILL that no Swift handler can catch and that takes the unsaved session with
        it. The guard's own doc comment records it having been wrong optimistically twice.

        The rule that follows from that is "never let a fit sit below a measurement", and
        no bf16 run has been measured on device. So the pack is refused rather than
        guessed at. Lifting this needs a device sweep of bf16 peak footprints and a
        predictor-aware `decide`, not a scaled-up int8 number.

        macOS is unaffected: `availableBytes` there is real physical memory with a desktop
        headroom budget, and the desktop has no jetsam.
        """
        super().check_available()
        if sys.platform == 'ios':
            raise PredictorUnavailable(
                '%s is not available on iOS: the dense bfloat16 pack needs more memory '
                'than the int8 pack the on-device size guard is calibrated against, and '
                'no bfloat16 run has been measured on device. Use boltz2 (int8).'
                % self.id
            )
