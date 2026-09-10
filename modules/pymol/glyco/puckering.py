"""Dependency-free Cremer-Pople descriptors for six-membered sugar rings."""

from __future__ import annotations

import math

from ._geometry import cross, dot, normalized, subtract


def cremer_pople_six(coordinates):
    """Return six-ring puckering amplitude and phase values.

    The result is intended as a structural-quality indicator, not a substitute
    for carbohydrate-aware refinement or validation.
    """
    if len(coordinates) != 6:
        return None
    center = tuple(sum(float(point[axis]) for point in coordinates) / 6.0
                   for axis in range(3))
    centered = [subtract(point, center) for point in coordinates]

    # Cremer-Pople's mean-ring-plane normal, derived from the first Fourier
    # components rather than from an arbitrary three-atom plane.
    sine_vector = tuple(sum(centered[index][axis] *
                            math.sin(2.0 * math.pi * index / 6.0)
                            for index in range(6)) for axis in range(3))
    cosine_vector = tuple(sum(centered[index][axis] *
                              math.cos(2.0 * math.pi * index / 6.0)
                              for index in range(6)) for axis in range(3))
    normal = normalized(cross(sine_vector, cosine_vector))
    if normal is None:
        return None

    z = [dot(point, normal) for point in centered]
    root_third = math.sqrt(1.0 / 3.0)
    q2_cos = root_third * sum(z[index] * math.cos(2.0 * math.pi * index / 3.0)
                              for index in range(6))
    q2_sin = -root_third * sum(z[index] * math.sin(2.0 * math.pi * index / 3.0)
                               for index in range(6))
    q3 = math.sqrt(1.0 / 6.0) * sum(((-1.0) ** index) * z[index]
                                    for index in range(6))
    q2 = math.hypot(q2_cos, q2_sin)
    amplitude = math.hypot(q2, q3)
    theta = math.degrees(math.atan2(q2, q3)) % 360.0 if amplitude > 1.0e-8 else 0.0
    phi = math.degrees(math.atan2(q2_sin, q2_cos)) % 360.0 if q2 > 1.0e-8 else 0.0
    if amplitude < 0.08:
        conformation = "nearly planar"
    elif theta < 30.0 or theta > 330.0 or 150.0 < theta < 210.0:
        conformation = "chair-like"
    elif 60.0 < theta < 120.0 or 240.0 < theta < 300.0:
        conformation = "boat/skew-like"
    else:
        conformation = "envelope/half-chair-like"
    return {
        "Q": round(amplitude, 3),
        "theta": round(theta, 1),
        "phi": round(phi, 1),
        "conformation": conformation,
        "advisory": True,
    }
