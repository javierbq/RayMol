"""Small dependency-free geometry helpers for glycan analysis."""

from __future__ import annotations

import math


def subtract(left, right):
    return tuple(float(left[index]) - float(right[index]) for index in range(3))


def dot(left, right):
    return sum(float(left[index]) * float(right[index]) for index in range(3))


def cross(left, right):
    return (
        left[1] * right[2] - left[2] * right[1],
        left[2] * right[0] - left[0] * right[2],
        left[0] * right[1] - left[1] * right[0],
    )


def norm(vector):
    return math.sqrt(dot(vector, vector))


def normalized(vector):
    length = norm(vector)
    if length <= 1.0e-12:
        return None
    return tuple(component / length for component in vector)


def dihedral(first, second, third, fourth):
    """Return the signed four-point dihedral in degrees, or ``None``."""
    b0 = subtract(first, second)
    b1 = subtract(third, second)
    b2 = subtract(fourth, third)
    axis = normalized(b1)
    if axis is None:
        return None
    projection0 = tuple(b0[i] - dot(b0, axis) * axis[i] for i in range(3))
    projection2 = tuple(b2[i] - dot(b2, axis) * axis[i] for i in range(3))
    if norm(projection0) <= 1.0e-12 or norm(projection2) <= 1.0e-12:
        return None
    return math.degrees(math.atan2(dot(cross(axis, projection0), projection2),
                                   dot(projection0, projection2)))
