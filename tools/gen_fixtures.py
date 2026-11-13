#!/usr/bin/env python3
"""Generate the slice-1 reference fixtures for the Swift port of spektrafilm.

The fixtures are the numerical contract between the upstream Python engine
(https://github.com/andreavolpato/spektrafilm) and the pure-Swift
``FilmPhysics`` package.  Everything is produced by running the *unmodified*
upstream pipeline, so the Swift implementation can be validated tap by tap
against the reference values.

What is captured
----------------
For every parameter case the pipeline is run with the upstream
``SimulationPipeline`` and every topology tap is collected:

    rgb_in -> log_e_film -> cmy_film -> log_e_print -> cmy_print -> rgb_out

Besides the taps, the fixture stores the *digested* per-stage data that the
Swift port needs but that is not trivially recoverable from the raw profile
JSON (digest of the profiles, illuminant spectra, neutral CC filter values,
print-balance mid-grey reference, print exposure normalisation factors,
scanner illuminant / CMFs / colour matrices, ...).

Output layout
-------------
    Tests/FilmPhysicsTests/Fixtures/slice1_common.json   shared big arrays
    Tests/FilmPhysicsTests/Fixtures/slice1_<case>.json    one file per case

Usage
-----
    /workspace/venv-sf/bin/python tools/gen_fixtures.py
    /workspace/venv-sf/bin/python tools/gen_fixtures.py --out /tmp/fx
"""

from __future__ import annotations

import argparse
import base64
import contextlib
import hashlib
import json
import math
import os
import sys
import tempfile
import time
from dataclasses import fields, is_dataclass, replace

import numpy as np

# --------------------------------------------------------------------------
# upstream import
# --------------------------------------------------------------------------

# Keep the numba JIT cache out of the upstream checkout: the upstream tree is
# read only for this project, the compiled kernels are cached in a temporary
# directory instead (the first run pays the compilation, ≈ 10 s).
os.environ.setdefault(
    "NUMBA_CACHE_DIR", os.path.join(tempfile.gettempdir(), "spektrafilm-numba-cache")
)

try:  # pragma: no cover - import shim
    import spektrafilm  # noqa: F401
except ImportError:  # pragma: no cover - import shim
    _SRC = os.environ.get("SPEKTRAFILM_SRC", "/workspace/spektrafilm/src")
    if os.path.isdir(_SRC):
        sys.path.insert(0, _SRC)

import colour  # noqa: E402
from opt_einsum import contract  # noqa: E402

from spektrafilm.config import SPECTRAL_SHAPE, STANDARD_OBSERVER_CMFS  # noqa: E402
from spektrafilm.model.color_filters import custom_dichroic_filters  # noqa: E402
from spektrafilm.model.diffusion import (  # noqa: E402
    _bloom_max_lambda_um,
    _strength_to_scatter,
    diffusion_filter_psf,
)
from spektrafilm.model.couplers import (  # noqa: E402
    compute_density_curves_before_dir_couplers,
    compute_dir_couplers_matrix,
)
from spektrafilm.model.illuminants import standard_illuminant  # noqa: E402
from spektrafilm.profiles.io import load_profile  # noqa: E402
from spektrafilm.runtime.params_builder import digest_params, init_params  # noqa: E402
from spektrafilm.runtime.pipeline import SimulationPipeline  # noqa: E402
from spektrafilm.utils.conversions import density_to_light  # noqa: E402
from spektrafilm.utils.fast_gaussian_filter import (  # noqa: E402
    _reflect,
    fast_exponential_filter,
    fast_gaussian_filter,
)
from spektrafilm.utils.gamut_compression import OutputGamutCompressSpec, compress_rgb  # noqa: E402
from spektrafilm.utils.morph_curves import (  # noqa: E402
    _evaluate_fitted_density,
)

# --------------------------------------------------------------------------
# constants
# --------------------------------------------------------------------------

UPSTREAM_PROJECT = "spektrafilm"
UPSTREAM_URL = "https://github.com/andreavolpato/spektrafilm"
UPSTREAM_COMMIT = "3bb2c2d"

FILM_PROFILE = "kodak_portra_400"
PRINT_PROFILE = "kodak_portra_endura"

IMAGE_SIZE = 12
SIGNIFICANT_DIGITS = 7

TAPS = (
    "rgb_in",
    "log_e_film",
    "cmy_film",
    "log_e_print",
    "cmy_print",
    "rgb_out",
)

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_OUT = os.path.join(REPO_ROOT, "Tests", "FilmPhysicsTests", "Fixtures")


# --------------------------------------------------------------------------
# JSON helpers
# --------------------------------------------------------------------------


def round_sig(value: float, digits: int = SIGNIFICANT_DIGITS) -> float | None:
    """Round a float to ``digits`` significant digits (NaN/Inf -> None)."""
    v = float(value)
    if math.isnan(v) or math.isinf(v):
        return None
    return float(f"{v:.{digits}g}")


def jsonable(obj, digits: int = SIGNIFICANT_DIGITS):
    """Recursively convert numpy/dataclass structures into JSON friendly data."""
    if obj is None or isinstance(obj, (bool, str)):
        return obj
    if isinstance(obj, (np.bool_,)):
        return bool(obj)
    if isinstance(obj, (int, np.integer)):
        return int(obj)
    if isinstance(obj, (float, np.floating)):
        return round_sig(obj, digits)
    if isinstance(obj, np.ndarray):
        if obj.ndim == 0:
            return jsonable(obj.item(), digits)
        return [jsonable(v, digits) for v in obj.tolist()]
    if isinstance(obj, (list, tuple)):
        return [jsonable(v, digits) for v in obj]
    if isinstance(obj, dict):
        return {str(k): jsonable(v, digits) for k, v in obj.items()}
    if is_dataclass(obj):
        return {f.name: jsonable(getattr(obj, f.name), digits) for f in fields(obj)}
    return str(obj)


def _is_number(v) -> bool:
    return v is None or isinstance(v, (int, float)) and not isinstance(v, bool)


def _fmt_scalar(v) -> str:
    if v is None:
        return "null"
    if v is True:
        return "true"
    if v is False:
        return "false"
    if isinstance(v, str):
        return json.dumps(v)
    if isinstance(v, int):
        return str(v)
    return repr(float(v))


def _write_json(path: str, obj) -> None:
    """Write JSON with compact numeric arrays but readable top level keys."""
    with open(path, "w", encoding="utf-8") as handle:
        _emit(obj, handle, 0)
        handle.write("\n")


def _emit(obj, handle, level: int) -> None:
    pad = "  " * level
    if isinstance(obj, dict):
        if not obj:
            handle.write("{}")
            return
        handle.write("{\n")
        items = list(obj.items())
        for i, (key, value) in enumerate(items):
            handle.write(pad + "  " + json.dumps(str(key)) + ": ")
            _emit(value, handle, level + 1)
            handle.write(",\n" if i < len(items) - 1 else "\n")
        handle.write(pad + "}")
        return
    if isinstance(obj, list):
        if not obj:
            handle.write("[]")
            return
        if all(_is_number(v) for v in obj):
            handle.write("[" + ",".join(_fmt_scalar(v) for v in obj) + "]")
            return
        handle.write("[\n")
        for i, value in enumerate(obj):
            handle.write(pad + "  ")
            _emit(value, handle, level + 1)
            handle.write(",\n" if i < len(obj) - 1 else "\n")
        handle.write(pad + "]")
        return
    handle.write(_fmt_scalar(obj))


# --------------------------------------------------------------------------
# deterministic test image
# --------------------------------------------------------------------------


def build_test_image() -> np.ndarray:
    """A small deterministic linear ProPhoto RGB test image (12 x 12 x 3).

    row 0 : neutral grey ramp, log spaced 0.002 .. 2.0
    row 1 : saturated colour patches
    row 2 : skin like colour patches
    rows 3..11 : seeded random block (numpy default_rng(1234))
    """
    img = np.zeros((IMAGE_SIZE, IMAGE_SIZE, 3), dtype=np.float64)

    grey = np.logspace(np.log10(0.002), np.log10(2.0), IMAGE_SIZE)
    img[0, :, :] = grey[:, None]

    saturated = [
        (1.0, 0.0, 0.0),
        (0.0, 1.0, 0.0),
        (0.0, 0.0, 1.0),
        (1.0, 1.0, 0.0),
        (1.0, 0.0, 1.0),
        (0.0, 1.0, 1.0),
        (1.0, 0.2, 0.0),
        (0.0, 0.6, 1.0),
        (0.9, 0.0, 0.6),
        (0.0, 1.0, 0.4),
        (1.0, 0.0, 0.3),
        (0.1, 0.0, 0.0),
    ]
    img[1, :, :] = np.array(saturated, dtype=np.float64)

    skin = [
        (0.72, 0.55, 0.45),
        (0.60, 0.42, 0.33),
        (0.85, 0.68, 0.57),
        (0.45, 0.30, 0.24),
        (0.95, 0.78, 0.66),
        (0.55, 0.38, 0.30),
        (0.78, 0.62, 0.50),
        (0.35, 0.22, 0.18),
        (0.68, 0.50, 0.42),
        (0.90, 0.72, 0.60),
        (0.50, 0.33, 0.26),
        (0.80, 0.60, 0.50),
    ]
    img[2, :, :] = np.array(skin, dtype=np.float64)

    rng = np.random.default_rng(1234)
    block = rng.random((IMAGE_SIZE - 3, IMAGE_SIZE, 3))
    lo, hi = math.log10(0.001), math.log10(4.0)
    img[3:, :, :] = 10 ** (lo + block * (hi - lo))

    return img


# --------------------------------------------------------------------------
# colour helpers (mirroring the upstream colour-science calls)
# --------------------------------------------------------------------------


def _illuminant_to_xy(illuminant_label: str) -> np.ndarray:
    """Same helper as spektrafilm.utils.spectral_upsampling._illuminant_to_xy."""
    illu = standard_illuminant(illuminant_label)
    xyz = np.array([np.sum(illu * STANDARD_OBSERVER_CMFS[:, i]) for i in range(3)])
    return xyz[0:2] / np.sum(xyz)


def _filming_rgb_to_xyz_matrix(reference_illuminant_xy: np.ndarray) -> np.ndarray:
    """Effective ProPhoto RGB (linear) -> XYZ(D55) matrix used by the filming stage."""
    identity = np.eye(3)
    xyz = colour.RGB_to_XYZ(
        identity,
        colourspace="ProPhoto RGB",
        apply_cctf_decoding=False,
        illuminant=reference_illuminant_xy,
        chromatic_adaptation_transform="CAT16",
    )
    return np.asarray(xyz, dtype=np.float64).T  # rows = basis vectors


def _scanning_xyz_to_rgb_matrix(scan_illuminant_xy: np.ndarray) -> np.ndarray:
    """Effective XYZ -> sRGB (linear) matrix used by the scanning stage."""
    identity = np.eye(3)
    rgb = colour.XYZ_to_RGB(
        identity,
        colourspace="sRGB",
        apply_cctf_encoding=False,
        illuminant=scan_illuminant_xy,
    )
    # row i of the result is the RGB obtained for the i-th XYZ basis vector,
    # i.e. rgb = result @ xyz
    return np.asarray(rgb, dtype=np.float64)


def _exposure_factor(sensitivity, print_illuminant, density_spectral_midgray):
    """Copy of spektrafilm.runtime.stages.printing._exposure_factor."""
    light_midgray = density_to_light(density_spectral_midgray, print_illuminant)
    raw_midgray = contract("ijk, kl->ijl", light_midgray, sensitivity)
    raw_midgray = np.fmax(raw_midgray, 1e-10)
    raw_midgray_geomean = np.exp(np.mean(np.log(raw_midgray), axis=2, keepdims=True))
    return 1 / raw_midgray_geomean


# --------------------------------------------------------------------------
# parameter cases
# --------------------------------------------------------------------------


def _base_params(
    output_gamut_compress: str = "off",
    film_profile: str = FILM_PROFILE,
    print_profile: str = PRINT_PROFILE,
):
    """init_params() with every spatial / stochastic effect disabled.

    ``output_gamut_compress`` selects the output gamut compression: the
    slice 1 fixtures use the diagnostic ``"off"`` build, the slice 2 fixtures
    use the upstream default (``"cam16ucs"``).
    """
    params = init_params(film_profile=film_profile, print_profile=print_profile)

    # --- camera ---------------------------------------------------------
    params.camera.auto_exposure = False
    params.camera.auto_exposure_method = "center_weighted"
    params.camera.lens_blur_um = 0.0
    params.camera.diffusion_filter.active = False

    # --- film rendering -------------------------------------------------
    params.film_render.grain.active = False
    params.film_render.halation.active = False
    params.film_render.glare.active = False
    # DIR couplers stay ACTIVE (they are part of the film chemistry) but
    # their spatial diffusion is switched off -> purely per pixel.
    params.film_render.dir_couplers.active = True
    params.film_render.dir_couplers.diffusion_size_um = 0.0

    # --- print rendering ------------------------------------------------
    params.print_render.glare.active = False
    params.print_render.density_curves_morph = replace(
        params.print_render.density_curves_morph, active=False
    )

    # --- enlarger -------------------------------------------------------
    params.enlarger.lens_blur = 0.0
    params.enlarger.diffusion_filter.active = False
    params.enlarger.preflash_exposure = 0.0

    # --- scanner --------------------------------------------------------
    params.scanner.lens_blur = 0.0
    params.scanner.white_correction = False
    params.scanner.black_correction = False
    params.scanner.unsharp_mask = (0.0, 0.0)

    # --- io -------------------------------------------------------------
    params.io.scan_film = False
    params.io.crop = False
    params.io.upscale_factor = 1.0
    # input gamut compression stays at the upstream default
    # (active=True, algorithm="xy", knee=(0.0, 1.0, 6.0)).
    params.io.output_gamut_compress = OutputGamutCompressSpec(
        algorithm=output_gamut_compress
    )

    # --- debug / settings ----------------------------------------------
    params.debug.deactivate_spatial_effects = False
    params.debug.deactivate_stochastic_effects = False
    params.debug.lut_mode = False
    params.settings.use_enlarger_lut = False
    params.settings.use_scanner_lut = False
    params.settings.preview_mode = False

    return params


CASES = (
    {
        "name": "defaults",
        "title": "Default parameters (all spatial / stochastic effects off)",
        "description": (
            "Kodak Portra 400 -> Kodak Portra Endura with upstream defaults. "
            "Grain, halation, glare and the camera/enlarger diffusion filters "
            "are disabled, the DIR couplers stay active but per pixel "
            "(diffusion_size_um = 0), auto exposure is off and the output "
            "gamut compression is off."
        ),
        "apply": lambda p: None,
    },
    {
        "name": "camera_ev_plus1",
        "title": "Camera exposure compensation +1 EV",
        "description": (
            "Same as 'defaults' but with camera.exposure_compensation_ev = +1.0. "
            "The negative receives one stop more light; because "
            "enlarger.print_exposure_compensation stays enabled the enlarger "
            "re-normalises the print exposure against the compensated "
            "mid-grey reference."
        ),
        "apply": lambda p: setattr(p.camera, "exposure_compensation_ev", 1.0),
    },
    {
        "name": "print_exposure_and_filter_shifts",
        "title": "Enlarger print exposure 1.3 with Y / M filter shifts",
        "description": (
            "Same as 'defaults' but with enlarger.print_exposure = 1.3, "
            "enlarger.y_filter_shift = +10 CC and enlarger.m_filter_shift = -5 CC "
            "(the shifts are added to the neutral CC values coming from the "
            "upstream neutral_print_filters.json database)."
        ),
        "apply": lambda p: (
            setattr(p.enlarger, "print_exposure", 1.3),
            setattr(p.enlarger, "y_filter_shift", 10.0),
            setattr(p.enlarger, "m_filter_shift", -5.0),
        ),
    },
    {
        "name": "dir_couplers_inactive",
        "title": "DIR couplers inactive",
        "description": (
            "Same as 'defaults' but with film_render.dir_couplers.active = False, "
            "i.e. the inter-image (chemical) coupling between the emulsion "
            "layers is switched off."
        ),
        "apply": lambda p: setattr(p.film_render.dir_couplers, "active", False),
    },
)


# --------------------------------------------------------------------------
# per case extraction
# --------------------------------------------------------------------------


def params_to_json(params) -> dict:
    """Serialise the digested params (the two profiles are referenced by name)."""
    out = {
        "film_profile": params.film.info.stock,
        "print_profile": params.print.info.stock,
    }
    for f in fields(params):
        if f.name in ("film", "print"):
            continue
        out[f.name] = jsonable(getattr(params, f.name))
    return out


def run_case(case, image):
    """Digest the params, run the pipeline and collect every tap."""
    params = _base_params()
    case["apply"](params)
    params = digest_params(params)

    pipeline = SimulationPipeline(params)

    taps = {}
    for tap in TAPS:
        value = pipeline.process(image, inject="rgb_in", collect=tap)
        taps[tap] = np.asarray(value, dtype=np.float64)

    enlarger_service = pipeline._enlarger_service
    color_reference = pipeline._color_reference_service

    film = pipeline.film
    print_profile = pipeline.print

    # --- print balance reference (computed by the filming stage) --------
    density_spectral_midgray = np.asarray(enlarger_service.density_spectral_midgray)
    density_spectral_midgray_comp = enlarger_service.density_spectral_midgray_comp
    if density_spectral_midgray_comp is not None:
        density_spectral_midgray_comp = np.asarray(density_spectral_midgray_comp)
    # --- enlarger illuminant + exposure normalisation -------------------
    light_source = standard_illuminant(pipeline.enlarger.illuminant)
    print_illuminant = np.asarray(enlarger_service.enlarger_filtered_illuminant(light_source))
    print_sensitivity = 10 ** np.asarray(print_profile.data.log_sensitivity)

    factor_midgray = _exposure_factor(
        print_sensitivity, print_illuminant, density_spectral_midgray
    )
    if density_spectral_midgray_comp is not None:
        factor_midgray_comp = _exposure_factor(
            print_sensitivity, print_illuminant, density_spectral_midgray_comp
        )
    else:
        factor_midgray_comp = 1.0

    if (
        pipeline.enlarger.print_exposure_compensation
        and not pipeline.enlarger.normalize_print_exposure
    ):
        factor_used = factor_midgray_comp / factor_midgray
    elif pipeline.enlarger.normalize_print_exposure and pipeline.enlarger.print_exposure_compensation:
        factor_used = factor_midgray_comp
    elif pipeline.enlarger.normalize_print_exposure and not pipeline.enlarger.print_exposure_compensation:
        factor_used = factor_midgray
    else:
        factor_used = 1.0

    # --- DIR couplers ---------------------------------------------------
    dir_couplers = pipeline.film_render.dir_couplers
    couplers_matrix = compute_dir_couplers_matrix(dir_couplers) * dir_couplers.amount
    normalized_film_curves = np.asarray(film.data.density_curves) - np.nanmin(
        np.asarray(film.data.density_curves), axis=0
    )
    if dir_couplers.active:
        density_curves_before_couplers = compute_density_curves_before_dir_couplers(
            normalized_film_curves,
            np.asarray(film.data.log_exposure),
            couplers_matrix,
            positive=film.info.type == "positive",
        )
    else:
        density_curves_before_couplers = None

    # --- the hanatos2025 tc LUT actually used by the filming stage ------
    tc_lut = pipeline._lut_service.filming_tc_lut_memory
    if tc_lut is None:  # pragma: no cover - defensive
        raise RuntimeError("the filming tc LUT was not built")
    tc_lut = np.asarray(tc_lut, dtype=np.float64)

    derived = {
        "neutral_filters_cc": {
            "c": float(pipeline.enlarger.c_filter_neutral),
            "m": float(pipeline.enlarger.m_filter_neutral),
            "y": float(pipeline.enlarger.y_filter_neutral),
            "m_with_shift": float(pipeline.enlarger.m_filter_neutral + pipeline.enlarger.m_filter_shift),
            "y_with_shift": float(pipeline.enlarger.y_filter_neutral + pipeline.enlarger.y_filter_shift),
        },
        "enlarger": {
            "illuminant": pipeline.enlarger.illuminant,
            "light_source_spectrum": np.asarray(light_source),
            "filtered_illuminant_spectrum": print_illuminant,
            "print_sensitivity": print_sensitivity,
            "print_exposure": float(pipeline.enlarger.print_exposure),
            "exposure_factor_midgray": np.ravel(factor_midgray),
            "exposure_factor_midgray_comp": np.ravel(factor_midgray_comp),
            "exposure_factor_used": np.ravel(factor_used),
            "print_exposure_compensation": bool(pipeline.enlarger.print_exposure_compensation),
            "normalize_print_exposure": bool(pipeline.enlarger.normalize_print_exposure),
            "preflash_exposure": float(pipeline.enlarger.preflash_exposure),
            "exposure_factor_note": (
                "the exposure factors are scalars (upstream shape 1 x 1 x 1) that "
                "are broadcast over the three channels of the print exposure"
            ),
        },
        "print_balance": {
            "density_spectral_midgray": np.ravel(density_spectral_midgray),
            "density_spectral_midgray_comp": (
                None
                if density_spectral_midgray_comp is None
                else np.ravel(density_spectral_midgray_comp)
            ),
            "midgray_rgb": [0.184, 0.184, 0.184],
            "shape_note": (
                "the upstream arrays are 1 x 1 x 81 (one mid-grey patch), they "
                "are stored here flattened in wavelength order"
            ),
        },
        "print_black_white_reference": {
            "log_raw_print_black": np.ravel(color_reference.log_raw_print_black),
            "log_raw_print_white": np.ravel(color_reference.log_raw_print_white),
            "film_density_min": np.asarray(pipeline.film_render.grain.density_min),
            "film_density_max": np.nanmax(np.asarray(film.data.density_curves), axis=0),
        },
        "dir_couplers": {
            "active": bool(dir_couplers.active),
            "matrix": couplers_matrix,
            "density_curves_before_couplers": density_curves_before_couplers,
        },
        "camera_exposure_scale": float(2 ** pipeline.camera.exposure_compensation_ev),
        "pixel_size_um": float(pipeline._resize_service.pixel_size_um),
        "hanatos2025_tc_lut_sha256": hashlib.sha256(
            np.ascontiguousarray(tc_lut, dtype=np.float32).tobytes()
        ).hexdigest(),
    }

    return {
        "case": case["name"],
        "title": case["title"],
        "description": case["description"],
        "film_profile": FILM_PROFILE,
        "print_profile": PRINT_PROFILE,
        "params": params_to_json(params),
        "taps": {tap: taps[tap] for tap in TAPS},
        "derived": derived,
    }, tc_lut


# --------------------------------------------------------------------------
# common data
# --------------------------------------------------------------------------


def build_common(tc_lut: np.ndarray, image: np.ndarray) -> dict:
    film = load_profile(FILM_PROFILE)
    print_profile = load_profile(PRINT_PROFILE)

    wavelengths = np.asarray(film.data.wavelengths, dtype=np.float64)
    film_curves = np.asarray(film.data.density_curves, dtype=np.float64)
    print_curves = np.asarray(print_profile.data.density_curves, dtype=np.float64)

    # the print stage evaluates the *fitted* CDF model (not the stored curves)
    print_curves_fitted = _evaluate_fitted_density(
        np.asarray(print_profile.data.log_exposure, dtype=np.float64),
        print_profile.data.density_curves_model,
        profile_type=print_profile.info.type,
    )

    reference_illuminant = film.info.reference_illuminant
    reference_illuminant_xy = _illuminant_to_xy(reference_illuminant)

    scan_illuminant_label = print_profile.info.viewing_illuminant
    scan_illuminant = np.asarray(standard_illuminant(scan_illuminant_label))
    normalization = float(np.sum(scan_illuminant * STANDARD_OBSERVER_CMFS[:, 1], axis=0))
    illuminant_xyz = contract("k,kl->l", scan_illuminant, STANDARD_OBSERVER_CMFS[:]) / normalization
    scan_illuminant_xy = colour.XYZ_to_xy(illuminant_xyz)

    filming_matrix = _filming_rgb_to_xyz_matrix(reference_illuminant_xy)
    scanning_matrix = _scanning_xyz_to_rgb_matrix(scan_illuminant_xy)

    prophoto = colour.RGB_COLOURSPACES["ProPhoto RGB"]
    srgb = colour.RGB_COLOURSPACES["sRGB"]

    # colour.RGB_to_RGB(rgb, 'sRGB', 'sRGB', apply_cctf_encoding=True) is
    # *not* a no-op: it multiplies by the sRGB -> sRGB matrix, which carries
    # a Bradford chromatic adaptation of ~4e-5 that the upstream pipeline
    # applies before the sRGB transfer function. The Swift port has to
    # reproduce it to match the upstream output bit for bit.
    srgb_to_srgb = np.asarray(colour.models.matrix_RGB_to_RGB(srgb, srgb))

    common = {
        "format": "lightsuffer-ios slice1 common fixture v1",
        "generated_by": "tools/gen_fixtures.py",
        "upstream": {
            "project": UPSTREAM_PROJECT,
            "url": UPSTREAM_URL,
            "commit": UPSTREAM_COMMIT,
            "license": "GPL-3.0-or-later (code) / CC BY-SA 4.0 (profile data)",
        },
        "notes": {
            "float_format": "all floating point values are rounded to 7 significant digits",
            "nan_policy": (
                "JSON null marks a NaN in the upstream numpy array. "
                "spektrafilm.utils.conversions.density_to_light turns NaN "
                "densities into zero light transmittance."
            ),
            "array_layout": "wavelength indexed arrays are [wavelength][cmy]; image arrays are [height][width][3]",
        },
        "spectral": {
            "wavelengths": wavelengths,
            "shape": {
                "start": float(SPECTRAL_SHAPE.wavelengths[0]),
                "end": float(SPECTRAL_SHAPE.wavelengths[-1]),
                "step": float(np.mean(np.diff(SPECTRAL_SHAPE.wavelengths))),
                "count": int(len(SPECTRAL_SHAPE.wavelengths)),
            },
            "cmfs_cie1931_2deg": np.asarray(STANDARD_OBSERVER_CMFS[:], dtype=np.float64),
        },
        "illuminants": {
            "TH-KG3": np.asarray(standard_illuminant("TH-KG3")),
            "D55": np.asarray(standard_illuminant("D55")),
            "D50": np.asarray(standard_illuminant("D50")),
            "scan_illuminant_label": scan_illuminant_label,
            "scan_illuminant_spectrum": scan_illuminant,
            "scan_normalization": normalization,
            "scan_illuminant_xyz": illuminant_xyz,
            "scan_illuminant_xy": scan_illuminant_xy,
        },
        "color": {
            "input_color_space": "ProPhoto RGB",
            "input_cctf_decoding": False,
            "output_color_space": "sRGB",
            "output_cctf_encoding": True,
            "reference_illuminant": reference_illuminant,
            "reference_illuminant_xy": reference_illuminant_xy,
            "filming_rgb_to_xyz": filming_matrix,
            "filming_note": (
                "XYZ(D55) = filming_rgb_to_xyz * RGB(linear ProPhoto). "
                "The matrix is colour.RGB_to_XYZ('ProPhoto RGB') followed by a "
                "CAT16 adaptation from the ProPhoto white point (D50) to the "
                "film reference illuminant (D55)."
            ),
            "scanning_xyz_to_rgb": scanning_matrix,
            "scanning_note": (
                "RGB(linear sRGB) = scanning_xyz_to_rgb * XYZ. "
                "The matrix is colour.XYZ_to_RGB('sRGB') with the default CAT02 "
                "adaptation from the scan illuminant (D50) to the sRGB white "
                "point (D65); the sRGB CCTF is applied afterwards."
            ),
            "prophoto_rgb_to_xyz_matrix": np.asarray(prophoto.matrix_RGB_to_XYZ),
            "srgb_xyz_to_rgb_matrix": np.asarray(srgb.matrix_XYZ_to_RGB),
            "prophoto_whitepoint_xy": np.asarray(prophoto.whitepoint)[0:2],
            "srgb_whitepoint_xy": np.asarray(srgb.whitepoint)[0:2],
            "srgb_to_srgb_matrix": srgb_to_srgb,
            "srgb_to_srgb_note": (
                "colour.RGB_to_RGB(rgb, 'sRGB', 'sRGB', apply_cctf_encoding=True) "
                "first multiplies by this matrix (a Bradford CAT that is only "
                "numerically the identity) and then applies the sRGB inverse "
                "EOTF (encoding): v = 12.92 * c for c <= 0.0031308, "
                "v = 1.055 * sign(c) * |c| ** (1 / 2.4) - 0.055 otherwise."
            ),
            "xy_note": (
                "xy = (X, Y) / (X + Y + Z); the lookup coordinates of the "
                "hanatos2025 tc LUT are tc = ((1 - x) ** 2, y / (1 - x)), i.e. "
                "spektrafilm.utils.spectral_upsampling._tri2quad(xy)."
            ),
        },
        "enlarger": {
            "illuminant": "TH-KG3",
            "dichroic_filter_transmittance_cmy": np.asarray(custom_dichroic_filters.filters),
            "dichroic_note": (
                "Custom (synthetic) CMY dichroic filters used by "
                "spektrafilm.model.color_filters.color_enlarger. CC values are "
                "Kodak CC units: transmittance = 10 ** (-cc / 100)."
            ),
        },
        "film": {
            "stock": film.info.stock,
            "name": film.info.name,
            "type": film.info.type,
            "support": film.info.support,
            "stage": film.info.stage,
            "use": film.info.use,
            "antihalation": film.info.antihalation,
            "reference_illuminant": film.info.reference_illuminant,
            "viewing_illuminant": film.info.viewing_illuminant,
            "wavelengths": np.asarray(film.data.wavelengths),
            "log_sensitivity": np.asarray(film.data.log_sensitivity),
            "sensitivity": 10 ** np.asarray(film.data.log_sensitivity),
            "channel_density": np.asarray(film.data.channel_density),
            "base_density": np.asarray(film.data.base_density),
            "midscale_neutral_density": np.asarray(film.data.midscale_neutral_density),
            "log_exposure": np.asarray(film.data.log_exposure),
            "density_curves": film_curves,
            "density_curves_normalized": film_curves - np.nanmin(film_curves, axis=0),
            "density_curves_layers": np.asarray(film.data.density_curves_layers),
            "density_curves_model": {
                "model_type": film.data.density_curves_model.model_type,
                "centers": np.asarray(film.data.density_curves_model.centers),
                "amplitudes": np.asarray(film.data.density_curves_model.amplitudes),
                "sigmas": np.asarray(film.data.density_curves_model.sigmas),
            },
            "density_min": np.nanmin(film_curves, axis=0),
            "density_max": np.nanmax(film_curves, axis=0),
        },
        "print": {
            "stock": print_profile.info.stock,
            "name": print_profile.info.name,
            "type": print_profile.info.type,
            "support": print_profile.info.support,
            "stage": print_profile.info.stage,
            "use": print_profile.info.use,
            "antihalation": print_profile.info.antihalation,
            "reference_illuminant": print_profile.info.reference_illuminant,
            "viewing_illuminant": print_profile.info.viewing_illuminant,
            "wavelengths": np.asarray(print_profile.data.wavelengths),
            "log_sensitivity": np.asarray(print_profile.data.log_sensitivity),
            "sensitivity": 10 ** np.asarray(print_profile.data.log_sensitivity),
            "channel_density": np.asarray(print_profile.data.channel_density),
            "base_density": np.asarray(print_profile.data.base_density),
            "midscale_neutral_density": np.asarray(print_profile.data.midscale_neutral_density),
            "log_exposure": np.asarray(print_profile.data.log_exposure),
            "density_curves": print_curves,
            "density_curves_fitted": print_curves_fitted,
            "density_curves_layers": np.asarray(print_profile.data.density_curves_layers),
            "density_curves_model": {
                "model_type": print_profile.data.density_curves_model.model_type,
                "centers": np.asarray(print_profile.data.density_curves_model.centers),
                "amplitudes": np.asarray(print_profile.data.density_curves_model.amplitudes),
                "sigmas": np.asarray(print_profile.data.density_curves_model.sigmas),
            },
            "density_min": np.nanmin(print_curves, axis=0),
            "density_max": np.nanmax(print_curves, axis=0),
        },
        "development": {
            "film_note": (
                "filming.develop() interpolates the NORMALIZED film density "
                "curves (density_curves - nanmin per channel) with "
                "log_exposure / gamma, then applies the DIR couplers, then "
                "grain (disabled in slice 1)."
            ),
            "print_note": (
                "printing.develop() evaluates the fitted CDF model of the print "
                "profile (density_curves_fitted) when the print curve morph is "
                "inactive, then interpolates with log_exposure."
            ),
            "midgray_note": (
                "The print balance reference density_spectral_midgray is "
                "computed from a 0.184 grey patch using the UN-normalized film "
                "density curves (develop_simple on density_curves)."
            ),
        },
        "test_image": {
            "size": [IMAGE_SIZE, IMAGE_SIZE, 3],
            "color_space": "linear ProPhoto RGB",
            "description": (
                "row 0: neutral grey ramp log spaced 0.002..2.0; row 1: "
                "saturated patches; row 2: skin like patches; rows 3..11: "
                "seeded random block (numpy default_rng(1234)) log spaced "
                "0.001..4.0"
            ),
            "data": image,
        },
        "hanatos2025_tc_lut": {
            "shape": list(tc_lut.shape),
            "dtype": "float32",
            "encoding": "base64 (little endian, C order)",
            "sha256_float32": hashlib.sha256(
                np.ascontiguousarray(tc_lut, dtype=np.float32).tobytes()
            ).hexdigest(),
            "note": (
                "rgb_to_raw_hanatos2025 lookup table: raw(tc.x, tc.y) is "
                "interpolated with a Mitchell-Netravali cubic (B = C = 1/3) "
                "on a reflected border and multiplied by the XYZ luminance b. "
                "It already contains the film sensitivity, the hanatos2025 "
                "window adaptation and the default input gamut compression "
                "(algorithm 'xy'). See "
                "spektrafilm.utils.fast_interp_lut._cubic_interp_lut_at_2d."
            ),
            "data": base64.b64encode(
                np.ascontiguousarray(tc_lut, dtype=np.float32).tobytes()
            ).decode("ascii"),
        },
    }

    return jsonable(common)


# --------------------------------------------------------------------------
# slice 2: the whole pipeline, from rgb_in
# --------------------------------------------------------------------------


def build_srgb_test_image() -> np.ndarray:
    """The test image encoded in sRGB (the realistic phone photo path).

    The linear test image is clipped to [0, 1] (a camera never records
    negative light) and encoded with the sRGB inverse EOTF.
    """
    linear = np.clip(build_test_image(), 0.0, 1.0)
    return np.where(
        linear <= 0.0031308,
        linear * 12.92,
        1.055 * np.power(linear, 1.0 / 2.4) - 0.055,
    )


#: The linear sRGB samples used to reference the CAM16-UCS forward model and
#: the output gamut compressor.
CAM16UCS_SAMPLES = [
    [0.0, 0.0, 0.0],
    [1.0, 1.0, 1.0],
    [1.0, 0.0, 0.0],
    [0.0, 1.0, 0.0],
    [0.0, 0.0, 1.0],
    [0.5, 0.5, 0.5],
    [0.184, 0.184, 0.184],
    [1.0, 0.5, 0.0],
    [0.2, 0.4, 0.9],
    [1.4, -0.2, 0.3],
    [-0.1, 1.2, 0.4],
    [0.9, 0.9, 1.3],
]


SLICE2_CASES = (
    {
        "name": "defaults",
        "title": "Upstream defaults, end to end from rgb_in",
        "description": (
            "Kodak Portra 400 -> Kodak Portra Endura with the upstream "
            "defaults: every spatial and stochastic effect is switched off, "
            "the input gamut compression is the upstream default (xy, knee "
            "(0, 1, 6)), the output gamut compression is the upstream "
            "default (cam16ucs) and the scanner corrections are off."
        ),
        "input": "linear_prophoto",
        "output_gamut_compress": "cam16ucs",
        "apply": lambda p: None,
    },
    {
        "name": "srgb_input",
        "title": "An sRGB encoded phone photo (CCTF decoding)",
        "description": (
            "Same as 'defaults' but the input is an sRGB encoded image and "
            "io.input_color_space is 'sRGB' with io.input_cctf_decoding = True, "
            "i.e. the realistic path of a phone photo."
        ),
        "input": "srgb_encoded",
        "output_gamut_compress": "cam16ucs",
        "apply": lambda p: (
            setattr(p.io, "input_color_space", "sRGB"),
            setattr(p.io, "input_cctf_decoding", True),
        ),
    },
    {
        "name": "camera_ev_minus1",
        "title": "Camera exposure compensation -1 EV",
        "description": (
            "Same as 'defaults' but with camera.exposure_compensation_ev = -1.0. "
            "The negative receives one stop less light; the enlarger "
            "re-normalises the print exposure against the compensated "
            "mid-grey reference (enlarger.print_exposure_compensation is on)."
        ),
        "input": "linear_prophoto",
        "output_gamut_compress": "cam16ucs",
        "apply": lambda p: setattr(p.camera, "exposure_compensation_ev", -1.0),
    },
    {
        "name": "output_gamut_off",
        "title": "Output gamut compression off",
        "description": (
            "Same as 'defaults' but with io.output_gamut_compress.algorithm = "
            "'off', which isolates the CAM16-UCS output compressor."
        ),
        "input": "linear_prophoto",
        "output_gamut_compress": "off",
        "apply": lambda p: None,
    },
)


def run_slice2_case(case, images):
    """Digest the params, run the whole pipeline and collect every tap."""
    params = _base_params(output_gamut_compress=case["output_gamut_compress"])
    case["apply"](params)
    params = digest_params(params)

    image = images[case["input"]]
    pipeline = SimulationPipeline(params)

    taps = {}
    for tap in TAPS:
        value = pipeline.process(image, inject="rgb_in", collect=tap)
        taps[tap] = np.asarray(value, dtype=np.float64)

    enlarger_service = pipeline._enlarger_service
    color_reference = pipeline._color_reference_service

    light_source = standard_illuminant(pipeline.enlarger.illuminant)
    print_illuminant = np.asarray(enlarger_service.enlarger_filtered_illuminant(light_source))
    print_sensitivity = 10 ** np.asarray(pipeline.print.data.log_sensitivity)
    density_spectral_midgray = np.asarray(enlarger_service.density_spectral_midgray)
    density_spectral_midgray_comp = enlarger_service.density_spectral_midgray_comp
    if density_spectral_midgray_comp is not None:
        density_spectral_midgray_comp = np.asarray(density_spectral_midgray_comp)

    factor_midgray = _exposure_factor(
        print_sensitivity, print_illuminant, density_spectral_midgray
    )
    if density_spectral_midgray_comp is not None:
        factor_midgray_comp = _exposure_factor(
            print_sensitivity, print_illuminant, density_spectral_midgray_comp
        )
    else:
        factor_midgray_comp = 1.0
    if (
        pipeline.enlarger.print_exposure_compensation
        and not pipeline.enlarger.normalize_print_exposure
    ):
        factor_used = factor_midgray_comp / factor_midgray
    elif pipeline.enlarger.normalize_print_exposure and pipeline.enlarger.print_exposure_compensation:
        factor_used = factor_midgray_comp
    elif pipeline.enlarger.normalize_print_exposure and not pipeline.enlarger.print_exposure_compensation:
        factor_used = factor_midgray
    else:
        factor_used = 1.0

    derived = {
        "neutral_filters_cc": {
            "c": float(pipeline.enlarger.c_filter_neutral),
            "m": float(pipeline.enlarger.m_filter_neutral),
            "y": float(pipeline.enlarger.y_filter_neutral),
        },
        "enlarger": {
            "illuminant": pipeline.enlarger.illuminant,
            "light_source_spectrum": np.asarray(light_source),
            "filtered_illuminant_spectrum": print_illuminant,
            "print_sensitivity": print_sensitivity,
            "print_exposure": float(pipeline.enlarger.print_exposure),
            "exposure_factor_midgray": np.ravel(factor_midgray),
            "exposure_factor_midgray_comp": np.ravel(factor_midgray_comp),
            "exposure_factor_used": np.ravel(factor_used),
        },
        "print_balance": {
            "density_spectral_midgray": np.ravel(density_spectral_midgray),
            "density_spectral_midgray_comp": (
                None
                if density_spectral_midgray_comp is None
                else np.ravel(density_spectral_midgray_comp)
            ),
        },
        "print_black_white_reference": {
            "log_raw_print_black": np.ravel(color_reference.log_raw_print_black),
            "log_raw_print_white": np.ravel(color_reference.log_raw_print_white),
        },
        "camera_exposure_scale": float(2 ** pipeline.camera.exposure_compensation_ev),
    }

    return {
        "case": case["name"],
        "title": case["title"],
        "description": case["description"],
        "film_profile": FILM_PROFILE,
        "print_profile": PRINT_PROFILE,
        "input": case["input"],
        "params": params_to_json(params),
        "taps": {tap: taps[tap] for tap in TAPS},
        "derived": derived,
    }


def build_slice2_common(images) -> dict:
    """The data shared by the slice 2 cases."""
    film = load_profile(FILM_PROFILE)
    print_profile = load_profile(PRINT_PROFILE)

    reference_illuminant = film.info.reference_illuminant
    reference_illuminant_xy = _illuminant_to_xy(reference_illuminant)
    scan_illuminant_label = print_profile.info.viewing_illuminant
    scan_illuminant = np.asarray(standard_illuminant(scan_illuminant_label))
    normalization = float(np.sum(scan_illuminant * STANDARD_OBSERVER_CMFS[:, 1], axis=0))
    illuminant_xyz = contract("k,kl->l", scan_illuminant, STANDARD_OBSERVER_CMFS[:]) / normalization
    scan_illuminant_xy = colour.XYZ_to_xy(illuminant_xyz)

    srgb = colour.RGB_COLOURSPACES["sRGB"]
    white = np.asarray(srgb.whitepoint, dtype=float)
    xyz_w = np.asarray([white[0] / white[1], 1.0, (1.0 - white[0] - white[1]) / white[1]])

    # The CAM16-UCS forward model and the output gamut compressor, on a set
    # of linear sRGB samples.
    cam16_samples = []
    for rgb in CAM16UCS_SAMPLES:
        xyz = np.asarray(
            colour.RGB_to_XYZ(
                np.array(rgb),
                colourspace="sRGB",
                apply_cctf_decoding=False,
                illuminant=white,
            )
        )
        jab = np.asarray(
            colour.XYZ_to_CAM16UCS(xyz, XYZ_w=xyz_w, L_A=64.0, Y_b=20.0)
        )
        compressed = np.asarray(
            compress_rgb(
                np.array(rgb),
                OutputGamutCompressSpec(algorithm="cam16ucs"),
                output_color_space="sRGB",
            )
        )
        cam16_samples.append(
            {
                "rgb": list(rgb),
                "xyz": list(xyz),
                "jpab": list(jab),
                "compressed": list(compressed),
            }
        )

    common = {
        "format": "lightsuffer-ios slice2 common fixture v1",
        "generated_by": "tools/gen_fixtures.py",
        "upstream": {
            "project": UPSTREAM_PROJECT,
            "url": UPSTREAM_URL,
            "commit": UPSTREAM_COMMIT,
            "license": "GPL-3.0-or-later (code) / CC BY-SA 4.0 (profile data)",
        },
        "notes": {
            "float_format": "all floating point values are rounded to 7 significant digits",
            "tc_lut": (
                "the hanatos2025 tc LUT of the film is the same as the one of "
                "slice1_common.json (it only depends on the film sensitivity, "
                "the hanatos2025 adaptation and the input gamut compression)"
            ),
        },
        "spectral": {
            "wavelengths": np.asarray(film.data.wavelengths),
            "cmfs_cie1931_2deg": np.asarray(STANDARD_OBSERVER_CMFS[:], dtype=np.float64),
        },
        "illuminants": {
            "TH-KG3": np.asarray(standard_illuminant("TH-KG3")),
            "D55": np.asarray(standard_illuminant("D55")),
            "D50": np.asarray(standard_illuminant("D50")),
            "D65": np.asarray(standard_illuminant("D65")),
            "scan_illuminant_label": scan_illuminant_label,
            "scan_illuminant_spectrum": scan_illuminant,
            "scan_normalization": normalization,
            "scan_illuminant_xyz": illuminant_xyz,
            "scan_illuminant_xy": scan_illuminant_xy,
        },
        "color": {
            "reference_illuminant": reference_illuminant,
            "reference_illuminant_xy": reference_illuminant_xy,
            "filming_prophoto_rgb_to_xyz": _filming_rgb_to_xyz_matrix(
                reference_illuminant_xy
            ),
            "filming_srgb_rgb_to_xyz": np.asarray(
                colour.RGB_to_XYZ(
                    np.eye(3),
                    colourspace="sRGB",
                    apply_cctf_decoding=False,
                    illuminant=reference_illuminant_xy,
                    chromatic_adaptation_transform="CAT16",
                )
            ).T,
            "scanning_xyz_to_rgb": _scanning_xyz_to_rgb_matrix(scan_illuminant_xy),
            "srgb_to_srgb_matrix": np.asarray(
                colour.models.matrix_RGB_to_RGB(srgb, srgb)
            ),
            "srgb_whitepoint_xy": np.asarray(srgb.whitepoint)[0:2],
            "prophoto_whitepoint_xy": np.asarray(
                colour.RGB_COLOURSPACES["ProPhoto RGB"].whitepoint
            )[0:2],
            "srgb_xyz_to_rgb_matrix": np.asarray(srgb.matrix_XYZ_to_RGB),
            "prophoto_rgb_to_xyz_matrix": np.asarray(
                colour.RGB_COLOURSPACES["ProPhoto RGB"].matrix_RGB_to_XYZ
            ),
            "matrix_note": (
                "the matrices are stored with the RGB response of every XYZ "
                "basis vector in their rows (the layout colour.XYZ_to_RGB "
                "returns for an identity input), i.e. rgb = xyz · matrix"
            ),
        },
        "cam16ucs": {
            "viewing_conditions": {"L_A": 64.0, "Y_b": 20.0},
            "xyz_w": xyz_w,
            "samples": cam16_samples,
        },
        "input_images": {
            "linear_prophoto": {
                "size": [IMAGE_SIZE, IMAGE_SIZE, 3],
                "color_space": "linear ProPhoto RGB",
                "data": images["linear_prophoto"],
            },
            "srgb_encoded": {
                "size": [IMAGE_SIZE, IMAGE_SIZE, 3],
                "color_space": "sRGB (encoded)",
                "data": images["srgb_encoded"],
            },
        },
        "enlarger": {
            "illuminant": "TH-KG3",
            "dichroic_filter_transmittance_cmy": np.asarray(custom_dichroic_filters.filters),
        },
    }
    return jsonable(common)


# --------------------------------------------------------------------------
# slice 4: the full catalogue (every film x print + the direct scan)
# --------------------------------------------------------------------------

#: The 20 camera films of the upstream catalogue
#: (``spektrafilm.model.stocks.FilmStocks``).
SLICE4_FILM_STOCKS = (
    "kodak_ektar_100",
    "kodak_portra_160",
    "kodak_portra_400",
    "kodak_portra_800",
    "kodak_portra_800_push1",
    "kodak_portra_800_push2",
    "kodak_gold_200",
    "kodak_ultramax_400",
    "kodak_vision3_50d",
    "kodak_vision3_250d",
    "kodak_verita_200d",
    "kodak_vision3_200t",
    "kodak_vision3_500t",
    "fujifilm_pro_400h",
    "fujifilm_c200",
    "fujifilm_xtra_400",
    "kodak_ektachrome_100",
    "kodak_kodachrome_64",
    "fujifilm_velvia_100",
    "fujifilm_provia_100f",
)

#: The 8 print media of the upstream catalogue
#: (``spektrafilm.model.stocks.PrintPapers``).
SLICE4_PRINT_STOCKS = (
    "kodak_ultra_endura",
    "kodak_endura_premier",
    "kodak_ektacolor_edge",
    "kodak_supra_endura",
    "kodak_portra_endura",
    "fujifilm_crystal_archive_typeii",
    "kodak_2383",
    "kodak_2393",
)

#: The papers that are scanned directly do not use a print medium at all; the
#: reference paper of the upstream GUI is kept in the parameters so that the
#: parameter set is complete, but the result does not depend on it.
SLICE4_DIRECT_SCAN_PRINT = "kodak_portra_endura"

#: The size of the (small) slice 4 test image.
SLICE4_IMAGE_SIZE = 6


def build_slice4_test_image() -> np.ndarray:
    """The deterministic linear ProPhoto RGB test image of the slice 4 (6 x 6).

    row 0 : neutral grey ramp, log spaced 0.002 .. 2.0
    row 1 : saturated colour patches
    row 2 : skin like colour patches
    row 3 : mixed patches (black, white, 50 % grey, 18 % grey, ...)
    rows 4-5 : seeded random block (numpy default_rng(20261109))
    """
    size = SLICE4_IMAGE_SIZE
    img = np.zeros((size, size, 3), dtype=np.float64)

    grey = np.logspace(np.log10(0.002), np.log10(2.0), size)
    img[0, :, :] = grey[:, None]

    saturated = [
        (1.0, 0.0, 0.0),
        (0.0, 1.0, 0.0),
        (0.0, 0.0, 1.0),
        (1.0, 1.0, 0.0),
        (0.2, 0.8, 1.0),
        (1.0, 0.4, 0.1),
    ]
    img[1, :, :] = np.array(saturated, dtype=np.float64)

    skin = [
        (0.72, 0.55, 0.45),
        (0.60, 0.42, 0.33),
        (0.85, 0.68, 0.57),
        (0.45, 0.30, 0.24),
        (0.95, 0.78, 0.66),
        (0.35, 0.22, 0.18),
    ]
    img[2, :, :] = np.array(skin, dtype=np.float64)

    mixed = [
        (0.0, 0.0, 0.0),
        (1.0, 1.0, 1.0),
        (0.5, 0.5, 0.5),
        (0.184, 0.184, 0.184),
        (0.9, 0.9, 0.05),
        (0.05, 0.9, 0.9),
    ]
    img[3, :, :] = np.array(mixed, dtype=np.float64)

    rng = np.random.default_rng(20261109)
    block = rng.random((size - 4, size, 3))
    lo, hi = math.log10(0.001), math.log10(4.0)
    img[4:, :, :] = 10 ** (lo + block * (hi - lo))

    return img


def slice4_cases() -> list[tuple[str, str, bool]]:
    """The (film, print, scan_film) triplets of the slice 4.

    * the 16 colour negatives are printed on the 8 print media (128 cases),
    * the 20 films (negatives and slides) are scanned directly (20 cases).
    """
    cases: list[tuple[str, str, bool]] = []
    for film in SLICE4_FILM_STOCKS:
        profile = load_profile(film)
        if profile.info.type != "negative":
            # A slide (positive) emulsion is never printed: the upstream
            # engine scans it directly.
            continue
        for print_stock in SLICE4_PRINT_STOCKS:
            cases.append((film, print_stock, False))
    for film in SLICE4_FILM_STOCKS:
        cases.append((film, SLICE4_DIRECT_SCAN_PRINT, True))
    return cases


def _slice4_digest_summary(pipeline) -> dict:
    """The stock specific digest values of a case (they are what the port has
    to reproduce)."""
    dir_couplers = pipeline.film_render.dir_couplers
    halation = pipeline.film_render.halation
    return {
        "neutral_filters_cc": [
            float(pipeline.enlarger.c_filter_neutral),
            float(pipeline.enlarger.m_filter_neutral),
            float(pipeline.enlarger.y_filter_neutral),
        ],
        "dir_couplers": {
            "gamma_samelayer_rgb": [float(v) for v in dir_couplers.gamma_samelayer_rgb],
            "gamma_interlayer_r_to_gb": [float(v) for v in dir_couplers.gamma_interlayer_r_to_gb],
            "gamma_interlayer_g_to_rb": [float(v) for v in dir_couplers.gamma_interlayer_g_to_rb],
            "gamma_interlayer_b_to_rg": [float(v) for v in dir_couplers.gamma_interlayer_b_to_rg],
        },
        "halation": {
            "halation_first_sigma_um": [float(v) for v in halation.halation_first_sigma_um],
            "halation_strength": [float(v) for v in halation.halation_strength],
        },
        "scan_illuminant": (
            pipeline.film.info.viewing_illuminant
            if pipeline.io.scan_film
            else pipeline.print.info.viewing_illuminant
        ),
    }


def run_slice4_case(case, image):
    """Run one catalogue case and collect the taps the fixture stores."""
    film_stock, print_stock, scan_film = case
    params = _base_params(
        output_gamut_compress="cam16ucs",
        film_profile=film_stock,
        print_profile=print_stock,
    )
    params.io.scan_film = scan_film
    params = digest_params(params)

    pipeline = SimulationPipeline(params)

    rgb_out = np.asarray(
        pipeline.process(image, inject="rgb_in", collect="rgb_out"), dtype=np.float64
    )
    cmy_film = None
    if scan_film:
        cmy_film = np.asarray(
            pipeline.process(image, inject="rgb_in", collect="cmy_film"), dtype=np.float64
        )

    return {
        "id": f"{film_stock}__{print_stock}" + ("__scan" if scan_film else ""),
        "film": film_stock,
        "print": print_stock,
        "mode": "scan_film" if scan_film else "print",
        "digest": _slice4_digest_summary(pipeline),
        "rgb_out": rgb_out,
        "cmy_film": cmy_film,
    }


def _slice4_worker(task):
    """The multiprocessing worker of the slice 4 (module level so that it can
    be pickled)."""
    case, image = task
    return run_slice4_case(case, image)


def build_slice4(image: np.ndarray, processes: int | None = None) -> dict:
    """Build the slice 4 catalogue fixture.

    ``processes`` selects the number of worker processes of the
    ``multiprocessing`` pool.  It defaults to **one** (no pool at all): the
    numba kernels of the upstream engine use the GNU OpenMP threading layer
    and a pool deadlocks when the workers are forked after the kernels have
    been compiled in the parent process.  The pool is only used when it is
    explicitly asked for, and it then uses the ``spawn`` start method.
    """
    cases = slice4_cases()

    started = time.time()

    # Warm the numba kernels up in the parent process, so that the workers
    # load the compiled kernels from the cache instead of compiling them.
    run_slice4_case(cases[0], image)

    if processes is None:
        processes = 1
    results = []
    if processes > 1:
        import multiprocessing

        # The "spawn" start method is used on purpose: the numba kernels use
        # the GNU OpenMP threading layer, which cannot be forked.
        context = multiprocessing.get_context("spawn")
        tasks = [(case, image) for case in cases]
        with context.Pool(processes=processes) as pool:
            for index, result in enumerate(pool.imap_unordered(_slice4_worker, tasks, chunksize=1)):
                results.append(result)
                print(f"  slice4 case {index + 1:3d}/{len(cases)}  {result['id']}")
    else:
        for index, case in enumerate(cases):
            result = run_slice4_case(case, image)
            results.append(result)
            print(f"  slice4 case {index + 1:3d}/{len(cases)}  {result['id']}")

    # keep the order of the case list
    order = {case_key(case): index for index, case in enumerate(cases)}
    results.sort(key=lambda result: order[(result["film"], result["print"], result["mode"] == "scan_film")])

    payload = {
        "format": "lightsuffer-ios slice4 catalogue fixture v1",
        "generated_by": "tools/gen_fixtures.py",
        "upstream": {
            "project": UPSTREAM_PROJECT,
            "url": UPSTREAM_URL,
            "commit": UPSTREAM_COMMIT,
            "license": "GPL-3.0-or-later (code) / CC BY-SA 4.0 (profile data)",
        },
        "notes": {
            "float_format": "all floating point values are rounded to 7 significant digits",
            "parameters": (
                "init_params() with every spatial and stochastic effect "
                "switched off (grain, halation, glare, the camera and the "
                "enlarger diffusion filters, the lens blurs, the unsharp mask "
                "and the auto exposure), the DIR couplers active but per "
                "pixel, the print density curve morph off, the input gamut "
                "compression at its upstream default (xy) and the output "
                "gamut compression at its upstream default (cam16ucs)."
            ),
            "print_cases": (
                "the 16 colour negatives printed on the 8 print media "
                "(128 cases)."
            ),
            "scan_cases": (
                "the 20 films scanned directly (io.scan_film = True). The "
                "upstream GUI scans the slides (Velvia, Provia, Kodachrome, "
                "Ektachrome) directly by default "
                "(spektrafilm_gui.state.digest_after_selection) and offers the "
                "same for the negatives. The direct scan does not use the "
                "print medium at all: the reference paper of the upstream GUI "
                "is kept in the parameters, the result does not depend on it."
            ),
            "rgb_in": (
                "the camera image is stored once; every case is fed with the "
                "same linear ProPhoto RGB image."
            ),
        },
        "test_image": {
            "size": [SLICE4_IMAGE_SIZE, SLICE4_IMAGE_SIZE, 3],
            "color_space": "linear ProPhoto RGB",
            "description": (
                "row 0: neutral grey ramp log spaced 0.002..2.0; row 1: "
                "saturated patches; row 2: skin like patches; row 3: mixed "
                "patches (black, white, 50 % grey, 18 % grey, ...); rows 4-5: "
                "seeded random block (numpy default_rng(20261109)) log spaced "
                "0.001..4.0"
            ),
            "data": image,
        },
        "cases": [
            {
                "id": result["id"],
                "film": result["film"],
                "print": result["print"],
                "mode": result["mode"],
                "digest": result["digest"],
                "rgb_out": result["rgb_out"],
                **({"cmy_film": result["cmy_film"]} if result["cmy_film"] is not None else {}),
            }
            for result in results
        ],
    }
    payload["elapsed_seconds"] = time.time() - started
    return jsonable(payload)


def case_key(case):
    """The sort key of a slice 4 case."""
    film_stock, print_stock, scan_film = case
    return (film_stock, print_stock, scan_film)


# --------------------------------------------------------------------------
# slice 5: the spatial effects (halation, diffusion filters, DIR coupler
# diffusion, the lens blurs and the unsharp mask)
# --------------------------------------------------------------------------

#: The size of the (small) slice 5 test image.
SLICE5_IMAGE_SIZE = 32

#: The film format (in millimetres) of the cases whose effects live on the
#: micrometre scale.
#:
#: The upstream parameters of the scatter, of the halation and of the
#: inhibitor diffusion are expressed in micrometres of the *film*; the size
#: of a pixel of the negative is ``film_format_mm * 1000 / max(height,
#: width)``.  On a 32 x 32 test image a 35 mm frame gives a pixel of
#: 1093.75 um, i.e. every micrometre scale effect is far below one pixel
#: (and therefore a mathematical no-op).  The cases that exercise those
#: effects therefore use a narrow film format, so that the upstream
#: parameters land on a meaningful number of pixels.
SLICE5_NARROW_FILM_FORMAT_MM = 1.0


def build_slice5_test_image() -> np.ndarray:
    """The deterministic linear ProPhoto RGB test image of the slice 5 (32 x 32).

    The image carries everything the spatial effects work on:

    * row 0: a neutral grey ramp, log spaced 0.002 .. 4.0,
    * row 1: saturated colour patches (and a mid grey),
    * row 2: skin like colour patches,
    * row 3: mixed patches (black, white, 50 % grey, 18 % grey, ...),
    * rows 4-11: a dark field with a neutral highlight spot (8x) and a warm
      highlight spot (the red weighted halation),
    * rows 12-31: a smooth vertical ramp on the left half and a textured
      field on the right half, separated by a hard vertical edge (a factor
      of four).
    """
    size = SLICE5_IMAGE_SIZE
    img = np.zeros((size, size, 3), dtype=np.float64)

    grey = np.logspace(math.log10(0.002), math.log10(4.0), size)
    img[0, :, :] = grey[:, None]

    saturated = np.array(
        [
            (1.0, 0.0, 0.0),
            (0.0, 1.0, 0.0),
            (0.0, 0.0, 1.0),
            (1.0, 1.0, 0.0),
            (1.0, 0.0, 1.0),
            (0.0, 1.0, 1.0),
            (0.9, 0.1, 0.0),
            (0.0, 0.9, 0.1),
        ],
        dtype=np.float64,
    )
    img[1, 0:8, :] = saturated
    img[1, 8:16, :] = saturated[::-1]
    img[1, 16:, :] = 0.18

    skin = np.array(
        [
            (0.72, 0.55, 0.45),
            (0.60, 0.42, 0.33),
            (0.85, 0.68, 0.57),
            (0.45, 0.30, 0.24),
            (0.95, 0.78, 0.66),
            (0.55, 0.38, 0.30),
            (0.78, 0.62, 0.50),
            (0.35, 0.22, 0.18),
        ],
        dtype=np.float64,
    )
    img[2, 0:8, :] = skin
    img[2, 8:16, :] = skin[::-1]
    img[2, 16:, :] = 0.05

    mixed = np.array(
        [
            (0.0, 0.0, 0.0),
            (1.0, 1.0, 1.0),
            (0.5, 0.5, 0.5),
            (0.184, 0.184, 0.184),
            (0.9, 0.9, 0.05),
            (0.05, 0.9, 0.9),
            (0.02, 0.02, 0.02),
            (2.0, 2.0, 2.0),
        ],
        dtype=np.float64,
    )
    img[3, 0:8, :] = mixed
    img[3, 8:16, :] = mixed[::-1]
    img[3, 16:, :] = 0.1

    # A dark field with the two highlight spots.
    img[4:12, :, :] = 0.004
    img[5:10, 5:10, :] = 8.0
    img[5:10, 18:24, 0] = 8.0
    img[5:10, 18:24, 1] = 5.0
    img[5:10, 18:24, 2] = 2.0

    # A smooth ramp on the left half and a textured field on the right half
    # (separated by a hard vertical edge).
    rng = np.random.default_rng(20261110)
    texture = 10 ** (
        math.log10(0.002)
        + rng.random((size - 12, size, 3)) * (math.log10(3.0) - math.log10(0.002))
    )
    ramp = np.logspace(math.log10(0.01), math.log10(2.0), size - 12)[:, None]
    img[12:, 0:16, :] = np.repeat(ramp[:, :, None], 16, axis=1)
    img[12:, 16:, :] = texture[:, 16:, :] * 4.0

    return img


def _slice5_base_params(output_gamut_compress: str = "cam16ucs"):
    """The upstream defaults of a slice 5 case.

    Only the *stochastic* effects (the grain and the glare) and the auto
    exposure are switched off: the grain needs the SciPy binomial and
    Poisson random variates and the glare needs a seeded lognormal, both of
    which are deferred to a later slice.  Every spatial effect keeps its
    upstream default value.
    """
    params = init_params(film_profile=FILM_PROFILE, print_profile=PRINT_PROFILE)

    # --- the stochastic effects (deferred) ------------------------------
    params.film_render.grain.active = False
    params.print_render.glare.active = False
    params.film_render.glare.active = False

    # --- auto exposure (kept off for this established fixture) ---------
    params.camera.auto_exposure = False

    # --- the print density curve morph (off at the upstream default) ---
    params.print_render.density_curves_morph = replace(
        params.print_render.density_curves_morph, active=False
    )

    # --- io -------------------------------------------------------------
    params.io.scan_film = False
    params.io.crop = False
    params.io.upscale_factor = 1.0
    params.io.output_gamut_compress = OutputGamutCompressSpec(
        algorithm=output_gamut_compress
    )

    # --- debug / settings ----------------------------------------------
    params.debug.deactivate_spatial_effects = False
    params.debug.deactivate_stochastic_effects = False
    params.debug.lut_mode = False
    params.settings.use_enlarger_lut = False
    params.settings.use_scanner_lut = False
    params.settings.preview_mode = False

    return params


def _slice5_disable_spatial_effects(params):
    """Switches every spatial effect off (the reference of the single effect
    cases)."""
    params.film_render.halation.active = False
    params.film_render.dir_couplers.diffusion_size_um = 0.0
    params.camera.lens_blur_um = 0.0
    params.camera.diffusion_filter.active = False
    params.enlarger.diffusion_filter.active = False
    params.enlarger.lens_blur = 0.0
    params.scanner.lens_blur = 0.0
    params.scanner.unsharp_mask = (0.0, 0.0)


def _slice5_halation(params):
    """The scatter and the back reflection halation, with a visible strength.

    The micrometre scale of the upstream parameters is brought onto the
    pixels of the test image with a narrow film format (1 mm) and with the
    spatial scale knobs of the upstream (which multiply the image plane
    widths of the kernels).
    """
    _slice5_disable_spatial_effects(params)
    params.camera.film_format_mm = SLICE5_NARROW_FILM_FORMAT_MM
    params.film_render.halation.active = True
    params.film_render.halation.scatter_amount = 1.0
    params.film_render.halation.scatter_spatial_scale = 20.0
    params.film_render.halation.halation_amount = 2.0
    params.film_render.halation.halation_spatial_scale = 1.0


def _slice5_highlight_boost(params):
    """The highlight boost of the halation group (the upstream default is
    boost_ev = 0, i.e. inactive)."""
    _slice5_disable_spatial_effects(params)
    params.film_render.halation.active = True
    params.film_render.halation.boost_ev = 6.0
    params.film_render.halation.boost_range = 0.3
    params.film_render.halation.protect_ev = 4.0


def _slice5_dir_coupler_diffusion(params):
    """The spatial diffusion of the DIR coupler inhibitors."""
    _slice5_disable_spatial_effects(params)
    params.camera.film_format_mm = SLICE5_NARROW_FILM_FORMAT_MM
    params.film_render.dir_couplers.diffusion_size_um = 20.0
    params.film_render.dir_couplers.diffusion_tail_um = 200.0
    params.film_render.dir_couplers.diffusion_tail_weight = 0.06


def _slice5_camera_diffusion_filter(params):
    """The diffusion filter of the camera (the black pro mist family, the
    upstream default family)."""
    _slice5_disable_spatial_effects(params)
    params.camera.diffusion_filter.active = True
    params.camera.diffusion_filter.filter_family = "black_pro_mist"
    params.camera.diffusion_filter.strength = 1.0
    params.camera.diffusion_filter.spatial_scale = 8.0


def _slice5_enlarger_diffusion_filter(params):
    """The diffusion filter of the enlarger."""
    _slice5_disable_spatial_effects(params)
    params.enlarger.diffusion_filter.active = True
    params.enlarger.diffusion_filter.filter_family = "black_pro_mist"
    params.enlarger.diffusion_filter.strength = 1.0
    params.enlarger.diffusion_filter.spatial_scale = 8.0


def _slice5_camera_lens_blur(params):
    """The lens blur of the camera."""
    _slice5_disable_spatial_effects(params)
    params.camera.film_format_mm = SLICE5_NARROW_FILM_FORMAT_MM
    params.camera.lens_blur_um = 60.0


def _slice5_scanner_blur_unsharp(params):
    """The lens blur and the unsharp mask of the scanner."""
    _slice5_disable_spatial_effects(params)
    params.scanner.lens_blur = 1.5
    params.scanner.unsharp_mask = (0.7, 0.7)


def _slice5_all_effects(params):
    """Every deterministic spatial effect at once."""
    _slice5_halation(params)
    params.film_render.halation.boost_ev = 6.0
    params.film_render.dir_couplers.diffusion_size_um = 20.0
    params.film_render.dir_couplers.diffusion_tail_um = 200.0
    params.film_render.dir_couplers.diffusion_tail_weight = 0.06
    params.camera.diffusion_filter.active = True
    params.camera.diffusion_filter.filter_family = "black_pro_mist"
    params.camera.diffusion_filter.strength = 1.0
    params.camera.diffusion_filter.spatial_scale = 0.25
    params.enlarger.diffusion_filter.active = True
    params.enlarger.diffusion_filter.filter_family = "black_pro_mist"
    params.enlarger.diffusion_filter.strength = 1.0
    params.enlarger.diffusion_filter.spatial_scale = 0.25
    params.camera.lens_blur_um = 60.0
    params.scanner.lens_blur = 1.5
    params.scanner.unsharp_mask = (0.7, 0.7)


SLICE5_CASES = (
    {
        "name": "baseline",
        "title": "Every spatial effect switched off",
        "description": (
            "The reference of the single effect cases: the scatter and the "
            "halation off, the DIR couplers active but per pixel (no "
            "inhibitor diffusion), the camera and the enlarger diffusion "
            "filters off, the lens blurs off and the unsharp mask off."
        ),
        "apply": _slice5_disable_spatial_effects,
        "taps": ("rgb_out",),
    },
    {
        "name": "defaults_grain_off",
        "title": "The upstream defaults, with the grain off",
        "description": (
            "The upstream defaults of init_params(): the scatter and the "
            "halation active (with the stock preset of Portra 400), the DIR "
            "couplers active with their default 20 um inhibitor diffusion, "
            "the unsharp mask of the scanner at its default (0.7, 0.7). The "
            "grain and the glare are switched off (they are stochastic) and "
            "so is the auto exposure (kept off for this fixture). On a 35 mm frame of a "
            "32 x 32 image a pixel is 1093.75 um, so the micrometre scale "
            "effects are below one pixel."
        ),
        "apply": lambda p: None,
        "taps": ("rgb_out", "log_e_film", "cmy_film"),
    },
    {
        "name": "halation",
        "title": "The scatter and the back reflection halation",
        "description": (
            "The scatter (a Gaussian core and an exponential tail) and the "
            "back reflection halation (three Gaussians with sqrt(k) spaced "
            "widths) of the negative, with the upstream parameters on a 1 mm "
            "film format (a pixel is 31.25 um) and with the spatial scale "
            "of the scatter multiplied by 20 so that both kernels cover "
            "several pixels."
        ),
        "apply": _slice5_halation,
        "taps": ("rgb_out", "log_e_film"),
    },
    {
        "name": "highlight_boost",
        "title": "The highlight boost",
        "description": (
            "The boost that reconstructs the pre clip irradiance of the "
            "negative (boost_ev = 6, the upstream default range of 0.3 and "
            "the upstream default protection of 4 stops). The upstream "
            "default of boost_ev is 0, i.e. the boost is inactive."
        ),
        "apply": _slice5_highlight_boost,
        "taps": ("rgb_out", "log_e_film"),
    },
    {
        "name": "dir_coupler_diffusion",
        "title": "The spatial diffusion of the DIR coupler inhibitors",
        "description": (
            "The inhibitors released by the emulsion layers diffuse into the "
            "neighbourhood (a Gaussian of 20 um and an exponential tail of "
            "200 um with a weight of 0.06, the upstream defaults) before "
            "they reduce the development of the neighbouring pixels. The "
            "case uses a 1 mm film format so that the diffusion covers "
            "several pixels."
        ),
        "apply": _slice5_dir_coupler_diffusion,
        "taps": ("rgb_out", "cmy_film"),
    },
    {
        "name": "camera_diffusion_filter",
        "title": "The diffusion filter of the camera",
        "description": (
            "The black pro mist family (the upstream default family) at a "
            "strength of 1.0 and a spatial scale of 8. The filter "
            "redistributes the light between the unscattered and the "
            "scattered population, with a per channel point spread "
            "function."
        ),
        "apply": _slice5_camera_diffusion_filter,
        "taps": ("rgb_out", "log_e_film"),
    },
    {
        "name": "enlarger_diffusion_filter",
        "title": "The diffusion filter of the enlarger",
        "description": (
            "The same filter as the camera case, but applied on the exposure "
            "of the paper."
        ),
        "apply": _slice5_enlarger_diffusion_filter,
        "taps": ("rgb_out", "log_e_print"),
    },
    {
        "name": "camera_lens_blur",
        "title": "The lens blur of the camera",
        "description": (
            "The 60 um lens blur of the camera, on a 1 mm film format (a "
            "pixel is 31.25 um, so the blur is 1.92 pixels wide)."
        ),
        "apply": _slice5_camera_lens_blur,
        "taps": ("rgb_out", "log_e_film"),
    },
    {
        "name": "scanner_blur_unsharp",
        "title": "The lens blur and the unsharp mask of the scanner",
        "description": (
            "The lens blur of the scanner (1.5 pixels) and its unsharp mask "
            "(the upstream default of 0.7 pixels and 0.7 of amount), "
            "applied on the linear RGB of the scan, after the output gamut "
            "compression and before the output transfer function."
        ),
        "apply": _slice5_scanner_blur_unsharp,
        "taps": ("rgb_out",),
    },
    {
        "name": "all_effects",
        "title": "Every deterministic spatial effect at once",
        "description": (
            "The scatter, the halation, the highlight boost, the DIR coupler "
            "diffusion, the camera and the enlarger diffusion filters, the "
            "lens blur of the camera and the lens blur and the unsharp mask "
            "of the scanner, all at once."
        ),
        "apply": _slice5_all_effects,
        "taps": ("rgb_out", "log_e_film", "cmy_film", "log_e_print"),
    },
)


def build_slice5_helpers() -> dict:
    """The reference of the image space helpers.

    The port reimplements the separable FIR Gaussian (below three pixels),
    the Young & van Vliet recursive Gaussian (above), the Gaussian mixture
    surrogate of the exponential PSF and the `reflect` boundary of SciPy;
    the reference holds what the upstream kernels return.
    """
    width, height = 12, 10
    rng = np.random.default_rng(4242)
    plane = rng.random((height, width))

    gaussians = []
    for sigma in (0.0, 0.4, 0.7, 1.0, 2.5, 3.0, 4.5, 8.0):
        filtered = np.asarray(fast_gaussian_filter(plane, sigma), dtype=np.float64)
        gaussians.append({"sigma": float(sigma), "filtered": filtered})

    exponentials = []
    for decay in (0.5, 1.0, 3.0, 7.5):
        filtered = np.asarray(
            fast_exponential_filter(plane, decay), dtype=np.float64
        )
        exponentials.append({"decay": float(decay), "filtered": filtered})

    reflect = [float(_reflect(index, 7)) for index in range(-12, 13)]

    return {
        "width": width,
        "height": height,
        "plane": plane.reshape(-1),
        "gaussians": gaussians,
        "exponentials": exponentials,
        "reflect": reflect,
        "notes": {
            "plane": "a deterministic random plane (numpy default_rng(4242))",
            "gaussians": (
                "fast_gaussian_filter(plane, sigma) of the upstream: the "
                "separable FIR below three pixels and the Young & van Vliet "
                "recursion above, both with the reflect boundary."
            ),
            "exponentials": (
                "fast_exponential_filter(plane, decay) of the upstream: the "
                "Gaussian mixture surrogate of the isotropic 2D exponential "
                "PSF."
            ),
            "reflect": "the _reflect helper of the upstream for an axis of 7 samples",
        },
    }


def build_slice5_diffusion_filters() -> list:
    """The reference of the point spread functions of the diffusion filters.

    Every family of the upstream is evaluated with and without a warmth
    bias, so that the per channel redistribution of the halo (the warm rim
    around the practical lights) is validated as well.
    """
    entries = []
    for family in ("glimmerglass", "black_pro_mist", "pro_mist", "cinebloom"):
        for warmth in (0.0, 1.0):
            psf = diffusion_filter_psf(
                (13, 13),
                family=family,
                spatial_scale=1.0,
                pixel_size_um=100.0,
                halo_warmth=warmth,
                overrides=None,
            )
            entries.append(
                {
                    "family": family,
                    "halo_warmth": float(warmth),
                    "spatial_scale": 1.0,
                    "pixel_size_um": 100.0,
                    "shape": [13, 13],
                    "psf": np.asarray(psf, dtype=np.float64),
                    "scatter_fraction": float(_strength_to_scatter(1.0, family)),
                    "bloom_max_lambda_um": float(_bloom_max_lambda_um(family, None)),
                }
            )
    return entries


def run_slice5_case(case, image):
    """Run one slice 5 case and collect its taps."""
    params = _slice5_base_params()
    case["apply"](params)
    params = digest_params(params)

    pipeline = SimulationPipeline(params)

    taps = {}
    for tap in case["taps"]:
        value = pipeline.process(image, inject="rgb_in", collect=tap)
        taps[tap] = np.asarray(value, dtype=np.float64)

    pixel_size_um = float(
        params.camera.film_format_mm * 1000 / np.max(image.shape[0:2])
    )

    return {
        "id": case["name"],
        "title": case["title"],
        "description": case["description"],
        "params": params_to_json(params),
        "pixel_size_um": pixel_size_um,
        "taps": taps,
    }


def build_slice5(image: np.ndarray) -> dict:
    """Build the slice 5 fixture (the spatial effects)."""
    cases = []
    for case in SLICE5_CASES:
        case_start = time.time()
        result = run_slice5_case(case, image)
        cases.append(result)
        print(
            f"  slice5 {case['name']:<28} "
            f"({time.time() - case_start:5.1f} s)"
        )

    payload = {
        "format": "lightsuffer-ios slice5 spatial effects fixture v1",
        "generated_by": "tools/gen_fixtures.py",
        "upstream": {
            "project": UPSTREAM_PROJECT,
            "url": UPSTREAM_URL,
            "commit": UPSTREAM_COMMIT,
            "license": "GPL-3.0-or-later (code) / CC BY-SA 4.0 (profile data)",
        },
        "notes": {
            "float_format": "all floating point values are rounded to 7 significant digits",
            "spatial_effects": (
                "the deterministic spatial effects of the upstream engine: "
                "the highlight boost, the in emulsion scatter, the back "
                "reflection halation, the spatial diffusion of the DIR "
                "coupler inhibitors, the diffusion filters of the camera and "
                "of the enlarger, the lens blurs of the camera and of the "
                "scanner and the unsharp mask of the scanner."
            ),
            "deferred": (
                "the grain and the glare are NOT part of this fixture: the "
                "grain needs the SciPy binomial and Poisson random variates "
                "and the glare needs a seeded lognormal, both of which are "
                "deferred to a later slice."
            ),
            "film_format": (
                "the micrometre scale effects (the scatter, the halation and "
                "the inhibitor diffusion) need a pixel of a meaningful size: "
                "on a 32 x 32 image a 35 mm frame gives a pixel of "
                "1093.75 um and the effects are below one pixel. The cases "
                "that exercise them use a 1 mm film format (31.25 um per "
                "pixel) and, for the scatter, the spatial scale knob of the "
                "upstream."
            ),
        },
        "test_image": {
            "size": [SLICE5_IMAGE_SIZE, SLICE5_IMAGE_SIZE, 3],
            "color_space": "linear ProPhoto RGB",
            "description": (
                "row 0: a neutral grey ramp log spaced 0.002..4.0; row 1: "
                "saturated colour patches; row 2: skin like colour patches; "
                "row 3: mixed patches (black, white, 50 % grey, 18 % grey, "
                "...); rows 4-11: a dark field with a neutral highlight spot "
                "and a warm highlight spot; rows 12-31: a smooth vertical "
                "ramp on the left half and a textured field (numpy "
                "default_rng(20261110)) on the right half, separated by a "
                "hard vertical edge"
            ),
            "data": image,
        },
        "helpers": build_slice5_helpers(),
        "diffusion_filters": build_slice5_diffusion_filters(),
        "cases": cases,
    }
    return jsonable(payload)


# --------------------------------------------------------------------------
# slice 6: the stochastic effects (the grain of the negative and the glare of
# the print)
# --------------------------------------------------------------------------

#: The size of the slice 6 test images.
SLICE6_IMAGE_SIZE = 64

#: The film format (in millimetres) of the slice 6 cases.
#:
#: The grain of the negative is a *statistical* effect: its amplitude is the
#: shot noise of the silver halide grains a pixel of the negative holds, i.e.
#: it scales with one over the square root of the number of particles per
#: pixel.  The number of particles of a pixel is the area of the pixel (in
#: square micrometres) divided by the area of a particle (0.2 um^2), so the
#: grain is only visible when the pixel of the negative is small: on a 64 x 64
#: image a 35 mm frame gives a pixel of 546 um and the grain is 0.1 % of the
#: density.  The cases therefore use a narrow film format (1 mm, i.e. a pixel
#: of 15.6 um), like the slice 5 does for the micrometre scale effects.
SLICE6_NARROW_FILM_FORMAT_MM = 1.0

#: The lags (in pixels) of the autocorrelation of the grain.
SLICE6_LAGS = (1, 2, 3, 5, 8)

#: The quantiles of the density histogram.
SLICE6_QUANTILES = (0.05, 0.25, 0.5, 0.75, 0.95)

#: The upstream seeds of the slice 6 cases.
#:
#: The upstream grain reseeds the global NumPy random state with a *fixed*
#: seed (0, 1 and 2 per channel, plus ten per sub layer), so the upstream
#: grain is deterministic; the fixture shifts those seeds to measure the
#: spread of the upstream.  The upstream glare draws from the *unseeded* global
#: random state, so the fixture seeds it.
#:
#: Twelve seeds are used: the spread of the upstream is the reference of the
#: validation, and the estimate of a standard deviation from twelve samples
#: has a relative error of about 20 %.
SLICE6_SEEDS = tuple(range(12))

#: The stocks of the slice 6 cases.
SLICE6_STOCKS = (
    {
        "id": "portra_400",
        "film": "kodak_portra_400",
        "print": "kodak_portra_endura",
        "scan_film": False,
    },
    {
        "id": "ultramax_400",
        "film": "kodak_ultramax_400",
        "print": "kodak_portra_endura",
        "scan_film": False,
    },
    {
        "id": "vision3_500t",
        "film": "kodak_vision3_500t",
        "print": "kodak_2383",
        "scan_film": False,
    },
    {
        "id": "velvia_100",
        "film": "fujifilm_velvia_100",
        "print": "kodak_portra_endura",
        "scan_film": True,
    },
)

#: The test images of the slice 6 cases.
SLICE6_IMAGES = (
    {"id": "flat_ev_minus2", "kind": "flat", "ev": -2.0},
    {"id": "flat_ev_0", "kind": "flat", "ev": 0.0},
    {"id": "flat_ev_plus2", "kind": "flat", "ev": 2.0},
    {"id": "textured_ev_0", "kind": "textured", "ev": 0.0},
)


def build_slice6_images() -> dict:
    """The test images of the slice 6 (the stochastic effects).

    * a flat mid grey patch (0.18, linear ProPhoto RGB): the grain of a flat
      patch is the pure shot noise of the emulsion,
    * a textured patch: a vertical ramp, a noise floor and two saturated
      patches.
    """
    size = SLICE6_IMAGE_SIZE
    flat = np.full((size, size, 3), 0.18, dtype=np.float64)

    rng = np.random.default_rng(20261111)
    ramp = np.logspace(math.log10(0.01), math.log10(2.0), size)[:, None]
    noise = 10 ** (
        math.log10(0.002)
        + rng.random((size, size, 3)) * (math.log10(3.0) - math.log10(0.002))
    )
    textured = np.repeat(ramp[:, :, None], size, axis=1) * 0.5 + noise
    textured[10:20, 10:20, :] = np.array([0.9, 0.2, 0.05])
    textured[30:40, 30:40, :] = np.array([0.05, 0.4, 0.9])

    return {"flat": flat, "textured": textured}


def _slice6_base_params(stock: dict, ev: float, output_gamut_compress: str = "cam16ucs"):
    """The upstream defaults of a slice 6 case.

    Every parameter keeps its upstream default value; the only changes are
    the ones the port needs: the auto exposure is off (the focused CPU AE
    fixtures cover the enabled path) and the film format is narrow (so that
    the grain is visible on a 64 x 64
    image).
    """
    params = init_params(film_profile=stock["film"], print_profile=stock["print"])

    params.camera.auto_exposure = False
    params.camera.film_format_mm = SLICE6_NARROW_FILM_FORMAT_MM
    params.camera.exposure_compensation_ev = ev

    params.io.scan_film = stock["scan_film"]
    params.io.crop = False
    params.io.upscale_factor = 1.0
    params.io.output_gamut_compress = OutputGamutCompressSpec(
        algorithm=output_gamut_compress
    )

    params.print_render.density_curves_morph = replace(
        params.print_render.density_curves_morph, active=False
    )

    params.debug.deactivate_spatial_effects = False
    params.debug.deactivate_stochastic_effects = False
    params.debug.lut_mode = False
    params.settings.preview_mode = False
    params.settings.use_enlarger_lut = False
    params.settings.use_scanner_lut = False

    return params


@contextlib.contextmanager
def _upstream_grain_seed_offset(offset: int):
    """Shifts the fixed seeds the upstream grain uses.

    The upstream grain reseeds the global NumPy random state with a fixed
    seed for every channel and sub layer, so two runs of the upstream engine
    are bit identical.  To measure the spread of the upstream, the fixture
    shifts those seeds; the algorithm of the upstream is not touched.
    """
    import spektrafilm.model.grain as grain_module

    original = grain_module.layer_particle_model

    def patched(density, *args, **kwargs):
        seed = kwargs.get("seed")
        if seed is not None:
            kwargs["seed"] = seed + offset
        return original(density, *args, **kwargs)

    grain_module.layer_particle_model = patched
    try:
        yield
    finally:
        grain_module.layer_particle_model = original


def field_statistics(field: np.ndarray) -> dict:
    """The summary statistics of a field (height x width x 3).

    The statistics are the ones the Swift port computes as well:

    * the mean and the standard deviation of every channel,
    * the autocorrelation of the field at a few lags (the horizontal and the
      vertical neighbours are pooled, the field is centred first),
    * the correlation of the three channels,
    * the quantiles of the density histogram (the three channels pooled).
    """
    channels = field.shape[2]
    centered = field - field.mean(axis=(0, 1), keepdims=True)

    stats = {}
    for channel in range(channels):
        plane = field[:, :, channel]
        stats[f"mean_{channel}"] = float(plane.mean())
        stats[f"std_{channel}"] = float(plane.std())

    for lag in SLICE6_LAGS:
        numerator = 0.0
        denominator = 0.0
        for channel in range(channels):
            plane = centered[:, :, channel]
            left = plane[:, :-lag]
            right = plane[:, lag:]
            numerator += float((left * right).sum())
            denominator += float((left * left).sum())
            top = plane[:-lag, :]
            bottom = plane[lag:, :]
            numerator += float((top * bottom).sum())
            denominator += float((top * top).sum())
        stats[f"acf_{lag}"] = numerator / denominator if denominator > 0 else 0.0

    for first, second in ((0, 1), (0, 2), (1, 2)):
        a = field[:, :, first].ravel()
        b = field[:, :, second].ravel()
        sa = a.std()
        sb = b.std()
        covariance = float(((a - a.mean()) * (b - b.mean())).mean())
        stats[f"corr_{first}_{second}"] = (
            covariance / (sa * sb) if sa > 0 and sb > 0 else 0.0
        )

    flat = field.reshape(-1)
    for quantile in SLICE6_QUANTILES:
        stats[f"q{int(round(quantile * 100)):02d}"] = float(np.quantile(flat, quantile))

    return stats


def aggregate_statistics(runs: list) -> dict:
    """The mean and the spread of a statistic over the seeds of a case."""
    if not runs:
        return {}
    keys = list(runs[0].keys())
    aggregate = {}
    for key in keys:
        values = np.array([run[key] for run in runs], dtype=np.float64)
        aggregate[key] = {
            "mean": float(values.mean()),
            "std": float(values.std()),
            "min": float(values.min()),
            "max": float(values.max()),
        }
    return aggregate


def run_slice6_case(stock: dict, image_case: dict, image: np.ndarray) -> dict:
    """Run one slice 6 case and collect the statistics of the two effects."""
    ev = image_case["ev"]

    # --- the reference (every stochastic effect off) --------------------
    reference_params = _slice6_base_params(stock, ev)
    reference_params.film_render.grain.active = False
    reference_params.print_render.glare.active = False
    reference_params = digest_params(reference_params)
    reference_pipeline = SimulationPipeline(reference_params)
    reference_cmy_film = np.asarray(
        reference_pipeline.process(image, inject="rgb_in", collect="cmy_film"),
        dtype=np.float64,
    )
    reference_rgb_out = np.asarray(
        reference_pipeline.process(image, inject="rgb_in", collect="rgb_out"),
        dtype=np.float64,
    )

    # --- the grain of the negative --------------------------------------
    grain_params = _slice6_base_params(stock, ev)
    grain_params.film_render.grain.active = True
    grain_params.print_render.glare.active = False
    grain_params = digest_params(grain_params)

    grain_runs = []
    grain_fast_runs = []
    for seed in SLICE6_SEEDS:
        with _upstream_grain_seed_offset(1000 * (seed + 1)):
            pipeline = SimulationPipeline(grain_params)
            cmy_film = np.asarray(
                pipeline.process(image, inject="rgb_in", collect="cmy_film"),
                dtype=np.float64,
            )
        grain_runs.append(field_statistics(cmy_film - reference_cmy_film))

        # The same run with the fast samplers of the upstream
        # (`spektrafilm.utils.fast_stats`), which the Swift port reproduces.
        fast_params = _slice6_base_params(stock, ev)
        fast_params.film_render.grain.active = True
        fast_params.print_render.glare.active = False
        fast_params.settings.use_fast_stats = True
        fast_params = digest_params(fast_params)
        with _upstream_grain_seed_offset(1000 * (seed + 1)):
            pipeline = SimulationPipeline(fast_params)
            cmy_film_fast = np.asarray(
                pipeline.process(image, inject="rgb_in", collect="cmy_film"),
                dtype=np.float64,
            )
        grain_fast_runs.append(field_statistics(cmy_film_fast - reference_cmy_film))

    # --- the glare of the print ----------------------------------------
    glare_runs = []
    glare_applicable = not stock["scan_film"]
    if glare_applicable:
        glare_params = _slice6_base_params(stock, ev)
        glare_params.film_render.grain.active = False
        glare_params.print_render.glare.active = True
        glare_params = digest_params(glare_params)
        for seed in SLICE6_SEEDS:
            # The upstream glare draws from the global NumPy random state.
            np.random.seed(seed)
            pipeline = SimulationPipeline(glare_params)
            rgb_out = np.asarray(
                pipeline.process(image, inject="rgb_in", collect="rgb_out"),
                dtype=np.float64,
            )
            glare_runs.append(field_statistics(rgb_out - reference_rgb_out))

    # The parameters the Swift port replays: both stochastic effects are
    # active, the test switches the one it does not use off.
    replay_params = _slice6_base_params(stock, ev)
    replay_params.film_render.grain.active = True
    replay_params.print_render.glare.active = True
    replay_params = digest_params(replay_params)

    return {
        "id": f"{stock['id']}__{image_case['id']}",
        "film": stock["film"],
        "print": stock["print"],
        "scan_film": stock["scan_film"],
        "image": image_case["id"],
        "exposure_compensation_ev": ev,
        "pixel_size_um": float(
            SLICE6_NARROW_FILM_FORMAT_MM * 1000 / max(image.shape[0:2])
        ),
        "params": params_to_json(replay_params),
        "grain": {
            "seeds": grain_runs,
            "aggregate": aggregate_statistics(grain_runs),
            "fast_aggregate": aggregate_statistics(grain_fast_runs),
        },
        "glare": {
            "applicable": glare_applicable,
            "seeds": glare_runs,
            "aggregate": aggregate_statistics(glare_runs),
        },
    }


def build_slice6() -> dict:
    """Build the slice 6 fixture (the stochastic effects)."""
    images = build_slice6_images()
    cases = []
    for stock in SLICE6_STOCKS:
        for image_case in SLICE6_IMAGES:
            case_start = time.time()
            image = images[image_case["kind"]]
            result = run_slice6_case(stock, image_case, image)
            cases.append(result)
            print(
                f"  slice6 {result['id']:<32} "
                f"({time.time() - case_start:5.1f} s)"
            )

    payload = {
        "format": "lightsuffer-ios slice6 stochastic effects fixture v1",
        "generated_by": "tools/gen_fixtures.py",
        "upstream": {
            "project": UPSTREAM_PROJECT,
            "url": UPSTREAM_URL,
            "commit": UPSTREAM_COMMIT,
            "license": "GPL-3.0-or-later (code) / CC BY-SA 4.0 (profile data)",
        },
        "notes": {
            "float_format": "all floating point values are rounded to 7 significant digits",
            "grain": (
                "the grain of the negative (spektrafilm.model.grain.apply_grain) "
                "is measured on the difference between the cmy_film tap with "
                "and without the grain: it is the grain field itself, in "
                "density units."
            ),
            "glare": (
                "the glare of the print (spektrafilm.model.glare.add_glare) is "
                "measured on the difference between the rgb_out tap with and "
                "without the glare: it is the visible effect of the glare, in "
                "the encoded sRGB domain. The upstream does not apply any "
                "glare to a directly scanned film, so the glare of the slide "
                "is not applicable."
            ),
            "seeds": (
                "the upstream grain reseeds the global NumPy random state "
                "with a fixed seed (0, 1, 2 per channel, plus ten per sub "
                "layer), so the upstream grain is deterministic. The fixture "
                "shifts those seeds (by 1000 * (seed + 1)) to measure the "
                "spread of the upstream; the algorithm is not touched. The "
                "upstream glare draws from the unseeded global random state, "
                "so the fixture seeds it."
            ),
            "fast_aggregate": (
                "the same grain runs with the fast samplers of the upstream "
                "(spektrafilm.utils.fast_stats, settings.use_fast_stats = "
                "True). The Swift port reproduces those samplers, so this is "
                "the closest reference for the port; the difference between "
                "the two aggregates measures the error of the normal "
                "approximation the fast samplers use."
            ),
            "film_format": (
                "the grain is the shot noise of the silver halide grains a "
                "pixel holds: its amplitude scales with one over the square "
                "root of the number of particles per pixel, i.e. with the "
                "area of the pixel. The cases therefore use a 1 mm film "
                "format (a pixel of 15.6 um on a 64 x 64 image), so that the "
                "grain is visible."
            ),
            "statistics": (
                "mean_c and std_c: the mean and the standard deviation of the "
                "field of the channel c. acf_l: the autocorrelation of the "
                "centred field at the lag l (the horizontal and the vertical "
                "neighbours pooled). corr_i_j: the correlation of the "
                "channels i and j. qXX: the quantiles of the density "
                "histogram (the three channels pooled)."
            ),
        },
        "images": {
            "size": [SLICE6_IMAGE_SIZE, SLICE6_IMAGE_SIZE, 3],
            "color_space": "linear ProPhoto RGB",
            "flat": images["flat"],
            "textured": images["textured"],
            "description": (
                "flat: a flat mid grey patch (0.18). textured: a vertical "
                "ramp, a noise floor (numpy default_rng(20261111)) and two "
                "saturated patches."
            ),
        },
        "lags": list(SLICE6_LAGS),
        "quantiles": list(SLICE6_QUANTILES),
        "seeds": list(SLICE6_SEEDS),
        "cases": cases,
    }
    return jsonable(payload)


# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--out",
        default=DEFAULT_OUT,
        help="output directory for the fixtures (default: %(default)s)",
    )
    parser.add_argument(
        "--slices",
        default="1,2,4,5,6",
        help="the slices to generate, comma separated (default: %(default)s)",
    )
    parser.add_argument(
        "--processes",
        type=int,
        default=1,
        help=(
            "number of worker processes of the slice 4 (1 = no pool, 0 = auto). "
            "The default is 1: the numba kernels of the upstream engine use "
            "the GNU OpenMP threading layer and a multiprocessing pool "
            "deadlocks when the workers are forked after the kernels have "
            "been compiled in the parent process."
        ),
    )
    args = parser.parse_args(argv)

    out_dir = os.path.abspath(args.out)
    os.makedirs(out_dir, exist_ok=True)

    slices = {part.strip() for part in args.slices.split(",") if part.strip()}

    started = time.time()
    image = build_test_image()

    print(f"spektrafilm upstream: {UPSTREAM_PROJECT} @ {UPSTREAM_COMMIT}")
    print(f"film profile : {FILM_PROFILE}")
    print(f"print profile: {PRINT_PROFILE}")
    print(f"output dir   : {out_dir}")
    print(f"slices       : {','.join(sorted(slices))}")
    print("-" * 72)

    written = []
    tc_lut = None
    if "1" in slices:
        for case in CASES:
            case_start = time.time()
            payload, tc_lut = run_case(case, image)
            path = os.path.join(out_dir, f"slice1_{case['name']}.json")
            _write_json(path, jsonable(payload))
            size = os.path.getsize(path)
            written.append(path)
            print(
                f"  {case['name']:<34} {size / 1024:8.1f} KiB  "
                f"({time.time() - case_start:5.1f} s)"
            )

        common = build_common(tc_lut, image)
        common_path = os.path.join(out_dir, "slice1_common.json")
        _write_json(common_path, common)
        written.append(common_path)
        print(
            f"  {'common':<34} {os.path.getsize(common_path) / 1024:8.1f} KiB"
        )

    # --- slice 2: the whole pipeline, from rgb_in ----------------------
    images = {
        "linear_prophoto": image,
        "srgb_encoded": build_srgb_test_image(),
    }
    if "2" in slices:
        for case in SLICE2_CASES:
            case_start = time.time()
            payload = run_slice2_case(case, images)
            path = os.path.join(out_dir, f"slice2_{case['name']}.json")
            _write_json(path, jsonable(payload))
            written.append(path)
            print(
                f"  slice2 {case['name']:<28} {os.path.getsize(path) / 1024:8.1f} KiB  "
                f"({time.time() - case_start:5.1f} s)"
            )

        slice2_common = build_slice2_common(images)
        slice2_common_path = os.path.join(out_dir, "slice2_common.json")
        _write_json(slice2_common_path, slice2_common)
        written.append(slice2_common_path)
        print(
            f"  slice2 {'common':<28} {os.path.getsize(slice2_common_path) / 1024:8.1f} KiB"
        )

    # --- slice 4: the full catalogue -----------------------------------
    if "4" in slices:
        slice4_start = time.time()
        slice4 = build_slice4(
            build_slice4_test_image(),
            processes=args.processes if args.processes > 0 else None,
        )
        slice4_path = os.path.join(out_dir, "slice4_catalog.json")
        _write_json(slice4_path, slice4)
        written.append(slice4_path)
        print(
            f"  slice4 {'catalogue':<28} {os.path.getsize(slice4_path) / 1024:8.1f} KiB  "
            f"({time.time() - slice4_start:5.1f} s, {len(slice4['cases'])} cases)"
        )

    # --- slice 5: the spatial effects ----------------------------------
    if "5" in slices:
        slice5_start = time.time()
        slice5 = build_slice5(build_slice5_test_image())
        slice5_path = os.path.join(out_dir, "slice5_spatial.json")
        _write_json(slice5_path, slice5)
        written.append(slice5_path)
        print(
            f"  slice5 {'spatial effects':<28} {os.path.getsize(slice5_path) / 1024:8.1f} KiB  "
            f"({time.time() - slice5_start:5.1f} s, {len(slice5['cases'])} cases)"
        )

    # --- slice 6: the stochastic effects --------------------------------
    if "6" in slices:
        slice6_start = time.time()
        slice6 = build_slice6()
        slice6_path = os.path.join(out_dir, "slice6_stochastic.json")
        _write_json(slice6_path, slice6)
        written.append(slice6_path)
        print(
            f"  slice6 {'stochastic effects':<28} {os.path.getsize(slice6_path) / 1024:8.1f} KiB  "
            f"({time.time() - slice6_start:5.1f} s, {len(slice6['cases'])} cases)"
        )

    total = sum(os.path.getsize(p) for p in written)
    print("-" * 72)
    print(f"total fixture size: {total} bytes ({total / 1024:.1f} KiB, {total / 1e6:.3f} MB)")
    print(f"elapsed: {time.time() - started:.1f} s")
    for path in written:
        print(f"  {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
