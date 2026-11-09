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
import hashlib
import json
import math
import os
import sys
import time
from dataclasses import fields, is_dataclass, replace

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

import colour  # noqa: E402
from opt_einsum import contract  # noqa: E402

from spektrafilm.config import SPECTRAL_SHAPE, STANDARD_OBSERVER_CMFS  # noqa: E402
from spektrafilm.model.color_filters import custom_dichroic_filters  # noqa: E402
from spektrafilm.model.couplers import (  # noqa: E402
    compute_density_curves_before_dir_couplers,
    compute_dir_couplers_matrix,
)
from spektrafilm.model.illuminants import standard_illuminant  # noqa: E402
from spektrafilm.profiles.io import load_profile  # noqa: E402
from spektrafilm.runtime.params_builder import digest_params, init_params  # noqa: E402
from spektrafilm.runtime.pipeline import SimulationPipeline  # noqa: E402
from spektrafilm.utils.conversions import density_to_light  # noqa: E402
from spektrafilm.utils.gamut_compression import OutputGamutCompressSpec  # noqa: E402
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


def _base_params():
    """init_params() with every spatial / stochastic effect disabled."""
    params = init_params(film_profile=FILM_PROFILE, print_profile=PRINT_PROFILE)

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
    params.io.output_gamut_compress = OutputGamutCompressSpec(algorithm="off")

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
# main
# --------------------------------------------------------------------------


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--out",
        default=DEFAULT_OUT,
        help="output directory for the fixtures (default: %(default)s)",
    )
    args = parser.parse_args(argv)

    out_dir = os.path.abspath(args.out)
    os.makedirs(out_dir, exist_ok=True)

    started = time.time()
    image = build_test_image()

    print(f"spektrafilm upstream: {UPSTREAM_PROJECT} @ {UPSTREAM_COMMIT}")
    print(f"film profile : {FILM_PROFILE}")
    print(f"print profile: {PRINT_PROFILE}")
    print(f"output dir   : {out_dir}")
    print("-" * 72)

    written = []
    tc_lut = None
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

    total = sum(os.path.getsize(p) for p in written)
    print("-" * 72)
    print(f"total fixture size: {total} bytes ({total / 1024:.1f} KiB, {total / 1e6:.3f} MB)")
    print(f"elapsed: {time.time() - started:.1f} s")
    for path in written:
        print(f"  {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
