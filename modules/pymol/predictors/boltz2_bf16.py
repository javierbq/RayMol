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
from .boltz2 import Boltz2Predictor
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
