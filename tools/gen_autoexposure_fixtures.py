#!/usr/bin/env python3
"""Generate the CPU auto-exposure parity fixtures from unmodified spektrafilm.

Run from the repository root:

    /workspace/venv-sf/bin/python tools/gen_autoexposure_fixtures.py

Use ``--out /tmp/ae-fixtures`` to write elsewhere, or ``--metering-only`` to
regenerate just the shared image / preview / EV fixture while developing.

The full-pipeline cases use the same 320 x 240 deterministic image and the
usual Kodak Portra 400 -> Kodak Portra Endura setup with grain and the other
spatial / stochastic effects disabled.  All numerical results, including the
small previews and the metered EVs, come from the unmodified upstream engine.
"""

from __future__ import annotations

import argparse
import os
import time

import numpy as np

# gen_fixtures supplies the established JSON format, base parameters, digest
# and profile conventions.  It also installs the upstream import shim and the
# temporary numba cache directory before importing spektrafilm.
import gen_fixtures as reference

from spektrafilm.runtime.params_builder import digest_params
from spektrafilm.runtime.pipeline import SimulationPipeline
from spektrafilm.runtime.services.resize import ResizingService
from spektrafilm.utils.autoexposure import measure_autoexposure_ev


METHODS = (
    "average",
    "median",
    "center_weighted",
    "partial",
    "matrix",
    "multi_zone",
    "highlight_weighted",
)
UNKNOWN_METHOD = "not_a_metering_method"
IMAGE_WIDTH = 320
IMAGE_HEIGHT = 240
PREVIEW_MAX_SIZE = 256
EXPOSURE_COMPENSATION_EV = 0.75

FULL_PIPELINE_CASES = (
    {
        "name": "off",
        "filename": "autoexposure_pipeline_off.json",
        "title": "Auto exposure off (control)",
        "auto_exposure": False,
        "method": "center_weighted",
        "compensation": 0.0,
    },
    {
        "name": "center_weighted",
        "filename": "autoexposure_pipeline_center_weighted.json",
        "title": "Auto exposure on, upstream default method",
        "auto_exposure": True,
        "method": "center_weighted",
        "compensation": 0.0,
    },
    {
        "name": "center_weighted_plus_compensation",
        "filename": "autoexposure_pipeline_compensation.json",
        "title": "Auto exposure plus +0.75 EV camera compensation",
        "auto_exposure": True,
        "method": "center_weighted",
        "compensation": EXPOSURE_COMPENSATION_EV,
    },
)


def build_test_image() -> np.ndarray:
    """A deterministic bright-centre / dark-edge linear ProPhoto RGB image.

    The long edge (320) exceeds 256, so small_preview must downsample it.
    Smooth colour gradients and the off-centre bright region make all seven
    metering methods produce distinct EVs without relying on random input.
    """
    x = (np.arange(IMAGE_WIDTH, dtype=np.float64) + 0.5) / IMAGE_WIDTH
    y = (np.arange(IMAGE_HEIGHT, dtype=np.float64) + 0.5) / IMAGE_HEIGHT
    xx, yy = np.meshgrid(x, y)

    centre = np.exp(
        -(
            ((xx - 0.54) / 0.145) ** 2
            + ((yy - 0.46) / 0.185) ** 2
        )
        / 2.0
    )
    broad_glow = np.exp(
        -(
            ((xx - 0.48) / 0.34) ** 2
            + ((yy - 0.52) / 0.38) ** 2
        )
        / 2.0
    )
    vignette = 0.12 + 0.88 * broad_glow

    red = (0.012 + 0.055 * xx + 0.018 * (1.0 - yy)) * vignette + 1.65 * centre
    green = (0.016 + 0.025 * xx + 0.045 * yy) * vignette + 2.10 * centre
    blue = (0.010 + 0.065 * (1.0 - xx) + 0.030 * yy) * vignette + 1.30 * centre
    return np.stack((red, green, blue), axis=2)


def encode_srgb(linear: np.ndarray) -> np.ndarray:
    """Encode a camera-range [0, 1] image with the sRGB inverse EOTF."""
    linear = np.clip(linear, 0.0, 1.0)
    return np.where(
        linear <= 0.0031308,
        linear * 12.92,
        1.055 * np.power(linear, 1.0 / 2.4) - 0.055,
    )


def image_record(image: np.ndarray, color_space: str, description: str) -> dict:
    return {
        "size": [image.shape[1], image.shape[0], image.shape[2]],
        "color_space": color_space,
        "description": description,
        "data": image,
    }


def build_common(images: dict[str, np.ndarray]) -> dict:
    """Capture upstream previews and EVs for both input colour variants."""
    resize = ResizingService(reference._base_params().io, 35.0)
    variants = (
        ("linear_prophoto", "ProPhoto RGB", False),
        ("srgb_encoded", "sRGB", True),
    )
    previews = {}
    metering = []
    for input_name, color_space, decode in variants:
        image = images[input_name]
        # This is the unmodified upstream service, with its default max_size.
        preview = resize.small_preview(image)
        previews[input_name] = {
            "shape": list(preview.shape),
            "array_layout": "[height][width][3]",
            "data": preview,
        }
        for method in METHODS + (UNKNOWN_METHOD,):
            ev = measure_autoexposure_ev(
                preview,
                color_space,
                decode,
                method=method,
            )
            metering.append(
                {
                    "input": input_name,
                    "input_color_space": color_space,
                    "input_cctf_decoding": decode,
                    "method": method,
                    "ev": float(ev),
                    "preview_shape": list(preview.shape),
                }
            )

    payload = {
        "format": "lightsuffer-ios CPU auto-exposure common fixture v1",
        "generated_by": "tools/gen_autoexposure_fixtures.py",
        "regenerate": (
            "/workspace/venv-sf/bin/python "
            "tools/gen_autoexposure_fixtures.py"
        ),
        "upstream": {
            "project": reference.UPSTREAM_PROJECT,
            "url": reference.UPSTREAM_URL,
            "commit": reference.UPSTREAM_COMMIT,
            "license": "GPL-3.0-or-later (code) / CC BY-SA 4.0 (profile data)",
        },
        "notes": {
            "float_format": "all floating point values are rounded to 7 significant digits",
            "array_layout": "image arrays are [height][width][3]",
            "preview": (
                "ResizingService.small_preview(image) with the default "
                "max_size=256 and order=0. The input long edge is 320, so "
                "the linear and encoded previews are both downsampled. "
                "Their complete upstream arrays are included for sampling diagnostics."
            ),
            "unknown_method": (
                f"{UNKNOWN_METHOD!r} intentionally exercises the upstream "
                "unknown-method fallback (exposure=1, EV=0)."
            ),
        },
        "methods": list(METHODS),
        "unknown_method": UNKNOWN_METHOD,
        "preview_max_size": PREVIEW_MAX_SIZE,
        "mid_grey": 0.184,
        "images": {
            "linear_prophoto": image_record(
                images["linear_prophoto"],
                "linear ProPhoto RGB",
                "320 x 240 deterministic bright centre, dark edges and colour gradients",
            ),
            "srgb_encoded": image_record(
                images["srgb_encoded"],
                "sRGB (encoded)",
                "the linear image clipped to [0, 1] and encoded with the sRGB inverse EOTF",
            ),
        },
        "previews": previews,
        "metering": metering,
    }
    return reference.jsonable(payload)


def run_pipeline_case(case: dict, image: np.ndarray) -> dict:
    """Run unmodified SimulationPipeline and capture the Swift replay data."""
    params = reference._base_params(output_gamut_compress="cam16ucs")
    params.camera.auto_exposure = case["auto_exposure"]
    params.camera.auto_exposure_method = case["method"]
    params.camera.exposure_compensation_ev = case["compensation"]
    params = digest_params(params)

    pipeline = SimulationPipeline(params)
    taps = {}
    for tap in ("rgb_in", "log_e_film", "rgb_out"):
        taps[tap] = np.asarray(
            pipeline.process(image, inject="rgb_in", collect=tap),
            dtype=np.float64,
        )

    if params.camera.auto_exposure:
        preview = pipeline._resize_service.small_preview(image)
        auto_exposure_ev = float(
            measure_autoexposure_ev(
                preview,
                params.io.input_color_space,
                params.io.input_cctf_decoding,
                method=params.camera.auto_exposure_method,
            )
        )
    else:
        auto_exposure_ev = 0.0

    enlarger_service = pipeline._enlarger_service
    midgray = np.asarray(enlarger_service.density_spectral_midgray)
    midgray_comp = enlarger_service.density_spectral_midgray_comp
    if midgray_comp is not None:
        midgray_comp = np.asarray(midgray_comp)

    return {
        "case": case["name"],
        "title": case["title"],
        "description": (
            "Unmodified upstream SimulationPipeline on the common 320 x 240 "
            "linear ProPhoto image. Grain, halation, glare, diffusion and "
            "blur are off; DIR couplers remain active per pixel. Auto "
            "exposure is applied before filming and is separate from "
            "camera.exposure_compensation_ev."
        ),
        "film_profile": reference.FILM_PROFILE,
        "print_profile": reference.PRINT_PROFILE,
        "input": "linear_prophoto",
        "params": reference.params_to_json(params),
        "taps": taps,
        "derived": {
            "auto_exposure_ev": auto_exposure_ev,
            "auto_exposure_scale": float(2.0**auto_exposure_ev),
            "camera_exposure_scale": float(
                2.0**params.camera.exposure_compensation_ev
            ),
            "pixel_size_um": float(pipeline._resize_service.pixel_size_um),
            "print_balance": {
                "midgray_rgb": [0.184, 0.184, 0.184],
                "midgray_compensation_rule": (
                    "0.184 * 2 ** camera.exposure_compensation_ev only; "
                    "the image-dependent auto-exposure EV is not included"
                ),
                "density_spectral_midgray": np.ravel(midgray),
                "density_spectral_midgray_comp": (
                    None if midgray_comp is None else np.ravel(midgray_comp)
                ),
            },
        },
    }


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--out",
        default=reference.DEFAULT_OUT,
        help="output directory (default: %(default)s)",
    )
    parser.add_argument(
        "--metering-only",
        action="store_true",
        help="write only autoexposure_common.json, skipping full-pipeline runs",
    )
    args = parser.parse_args(argv)

    out_dir = os.path.abspath(args.out)
    os.makedirs(out_dir, exist_ok=True)
    started = time.time()
    linear = build_test_image()
    images = {
        "linear_prophoto": linear,
        "srgb_encoded": encode_srgb(linear),
    }

    print(
        f"spektrafilm upstream: {reference.UPSTREAM_PROJECT} "
        f"@ {reference.UPSTREAM_COMMIT}",
        flush=True,
    )
    print(f"image: {IMAGE_WIDTH} x {IMAGE_HEIGHT}; preview max: {PREVIEW_MAX_SIZE}")
    print(f"output dir: {out_dir}", flush=True)

    common = build_common(images)
    common_path = os.path.join(out_dir, "autoexposure_common.json")
    reference._write_json(common_path, common)
    print(f"  autoexposure_common.json ({os.path.getsize(common_path)} bytes)", flush=True)
    for entry in common["metering"]:
        if entry["input"] == "linear_prophoto":
            print(f"    {entry['method']:<24} EV {entry['ev']:+.7g}", flush=True)

    if not args.metering_only:
        for case in FULL_PIPELINE_CASES:
            case_started = time.time()
            payload = reference.jsonable(run_pipeline_case(case, linear))
            path = os.path.join(out_dir, case["filename"])
            reference._write_json(path, payload)
            print(
                f"  {case['filename']} ({os.path.getsize(path)} bytes, "
                f"{time.time() - case_started:.1f} s)",
                flush=True,
            )

    print(f"elapsed: {time.time() - started:.1f} s", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
