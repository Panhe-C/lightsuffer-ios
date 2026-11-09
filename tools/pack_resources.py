#!/usr/bin/env python3
"""Pack the upstream spektrafilm spectral resources into compact binary files.

The Swift port (``Sources/FilmPhysics``) needs a few upstream data tables
that are too big or too awkward to keep in JSON:

* the *hanatos 2025* irradiance spectra lookup table
  (``data/luts/spectral_upsampling/irradiance_xy_tc.npy``) — the spectral
  upsampling table the whole camera stage is built on,
* the CIE 1931 2° colour matching functions,
* the standard illuminant spectra (TH-KG3, D55, D50, D65),
* the neutral print filter database (``data/filters/neutral_print_filters.json``).

The script converts them into little-endian binary resources that the Swift
package bundles.  It never writes outside the output directory and never
modifies the upstream checkout.

Binary layout
-------------
Every ``.f32`` / ``.f16`` file is a *flat* C-order array of little-endian
floats.  The shape is documented in ``Sources/FilmPhysics/Resources/CHANGELOG.txt``
and repeated in the Swift loader (``Sources/FilmPhysics/Resources.swift``).

Usage
-----
    /workspace/venv-sf/bin/python tools/pack_resources.py
    /workspace/venv-sf/bin/python tools/pack_resources.py --out /tmp/res
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sys

import numpy as np

# --------------------------------------------------------------------------
# upstream import
# --------------------------------------------------------------------------

try:  # pragma: no cover - import shim
    import spektrafilm  # noqa: F401
except ImportError:  # pragma: no cover - import shim
    _SRC = os.environ.get("SPEKTRAFILM_SRC", "/workspace/spektrafilm/src")
    if os.path.isdir(_SRC):
        sys.path.insert(0, _SRC)

from spektrafilm.config import SPECTRAL_SHAPE, STANDARD_OBSERVER_CMFS  # noqa: E402
from spektrafilm.model.illuminants import standard_illuminant  # noqa: E402

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_OUT = os.path.join(REPO_ROOT, "Sources", "FilmPhysics", "Resources")

#: The illuminants the port needs, in the order they are packed.
ILLUMINANTS = ("TH-KG3", "D55", "D50", "D65")

#: The shape of the hanatos 2025 irradiance spectra table.
SPECTRA_SHAPE = (192, 192, 81)


def _upstream_root() -> str:
    """The root of the upstream ``spektrafilm`` package."""
    import spektrafilm

    return os.path.dirname(os.path.abspath(spektrafilm.__file__))


def pack_spectra(out_dir: str) -> str:
    """Pack the hanatos 2025 irradiance spectra table.

    The upstream file is a ``float16`` array of shape (192, 192, 81) — the
    tc (triangular → square chromaticity) grid of the visible locus times the
    81 spectral samples of the 380…780 nm / 5 nm shape.  The upstream engine
    loads it with ``np.double(np.load(...))``, i.e. the float16 values are
    widened to double *without any loss*.

    The port therefore keeps the upstream float16 payload (the values are
    bit-identical to the upstream table) instead of widening it to float32,
    which would double the size of the resource from 5.7 MiB to 11.4 MiB.
    """
    path = os.path.join(
        _upstream_root(), "data", "luts", "spectral_upsampling", "irradiance_xy_tc.npy"
    )
    data = np.load(path)
    if tuple(data.shape) != SPECTRA_SHAPE:
        raise RuntimeError(f"unexpected spectra shape {data.shape}, expected {SPECTRA_SHAPE}")
    payload = np.ascontiguousarray(data.astype("<f2"))
    target = os.path.join(out_dir, "spectral", "irradiance_xy_tc.f16")
    os.makedirs(os.path.dirname(target), exist_ok=True)
    payload.tofile(target)
    return target


def pack_cmfs(out_dir: str) -> str:
    """Pack the CIE 1931 2° colour matching functions (81 x 3, float32)."""
    payload = np.ascontiguousarray(np.asarray(STANDARD_OBSERVER_CMFS[:], dtype="<f4"))
    if payload.shape != (81, 3):
        raise RuntimeError(f"unexpected CMF shape {payload.shape}")
    target = os.path.join(out_dir, "spectral", "cmfs_cie1931_2deg.f32")
    os.makedirs(os.path.dirname(target), exist_ok=True)
    payload.tofile(target)
    return target


def pack_illuminants(out_dir: str) -> str:
    """Pack the standard illuminant spectra (4 x 81, float32).

    The rows are, in order: TH-KG3 (the enlarger lamp), D55 (the film
    reference illuminant), D50 (the print viewing illuminant) and D65 (the
    sRGB white point).
    """
    rows = [np.asarray(standard_illuminant(label), dtype=np.float64) for label in ILLUMINANTS]
    payload = np.ascontiguousarray(np.stack(rows).astype("<f4"))
    if payload.shape != (len(ILLUMINANTS), 81):
        raise RuntimeError(f"unexpected illuminant shape {payload.shape}")
    target = os.path.join(out_dir, "spectral", "illuminants.f32")
    os.makedirs(os.path.dirname(target), exist_ok=True)
    payload.tofile(target)
    return target


def pack_neutral_print_filters(out_dir: str) -> str:
    """Copy the neutral print filter database (JSON) into the resources."""
    source = os.path.join(_upstream_root(), "data", "filters", "neutral_print_filters.json")
    target = os.path.join(out_dir, "filters", "neutral_print_filters.json")
    os.makedirs(os.path.dirname(target), exist_ok=True)
    shutil.copyfile(source, target)
    # Sanity check: the database must be a JSON object of print stocks.
    with open(target, "r", encoding="utf-8") as handle:
        data = json.load(handle)
    if not isinstance(data, dict) or not data:
        raise RuntimeError("the neutral print filter database is empty")
    return target


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--out",
        default=DEFAULT_OUT,
        help="output directory for the packed resources (default: %(default)s)",
    )
    args = parser.parse_args(argv)

    out_dir = os.path.abspath(args.out)
    os.makedirs(out_dir, exist_ok=True)

    print(f"spectral shape: {SPECTRAL_SHAPE.start}…{SPECTRAL_SHAPE.end} nm "
          f"({len(SPECTRAL_SHAPE.wavelengths)} samples)")
    written = [
        pack_spectra(out_dir),
        pack_cmfs(out_dir),
        pack_illuminants(out_dir),
        pack_neutral_print_filters(out_dir),
    ]
    total = 0
    for path in written:
        size = os.path.getsize(path)
        total += size
        print(f"  {os.path.relpath(path, out_dir):<48} {size / 1024:9.1f} KiB")
    print("-" * 72)
    print(f"total new resources: {total} bytes ({total / 1024 / 1024:.2f} MiB)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
