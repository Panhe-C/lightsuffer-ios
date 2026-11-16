#!/usr/bin/env python3
"""Capture print chemistry curves and pipeline taps from pinned spektrafilm.

Uses the same import/environment setup as gen_fixtures.py. Only this fixture
family is written; the upstream checkout and earlier fixtures are untouched.
"""

from __future__ import annotations

import argparse
from dataclasses import asdict, replace
import json
from pathlib import Path

import numpy as np
import gen_fixtures as reference
from gen_autoexposure_fixtures import packed_float32
from spektrafilm.profiles.io import load_profile
from spektrafilm.runtime.params_builder import digest_params
from spektrafilm.runtime.pipeline import SimulationPipeline
from spektrafilm.utils.morph_curves import PrintCurvesMorphParams, apply_print_curves_morph


CASES = {
    "off": PrintCurvesMorphParams(active=False),
    "defaults": PrintCurvesMorphParams(),
    "global": PrintCurvesMorphParams(gamma_factor=1.4),
    "fast": PrintCurvesMorphParams(gamma_factor_fast=0.6),
    "slow": PrintCurvesMorphParams(gamma_factor_slow=1.8),
    "red": PrintCurvesMorphParams(gamma_factor_red=1.3),
    "green": PrintCurvesMorphParams(gamma_factor_green=0.7),
    "blue": PrintCurvesMorphParams(gamma_factor_blue=1.6),
    "exhaustion_half": PrintCurvesMorphParams(developer_exhaustion=0.5),
    "exhaustion_full": PrintCurvesMorphParams(developer_exhaustion=1.0),
    "combined": PrintCurvesMorphParams(
        gamma_factor=1.25, gamma_factor_fast=0.7, gamma_factor_slow=1.6,
        gamma_factor_red=1.1, gamma_factor_green=0.9, gamma_factor_blue=1.4,
        developer_exhaustion=0.65,
    ),
    "sigma_floor": PrintCurvesMorphParams(
        gamma_factor=2.0, gamma_factor_fast=2.0, gamma_factor_slow=2.0,
        gamma_factor_red=2.0, gamma_factor_green=2.0, gamma_factor_blue=2.0,
        developer_exhaustion=1.0,
    ),
}


def generate() -> dict:
    curves = []
    for stock in reference.SLICE4_PRINT_STOCKS:
        profile = load_profile(stock)
        curves.append({
            "stock": stock,
            "profile_type": profile.info.type,
            "log_exposure": profile.data.log_exposure,
            "cases": [
                {
                    "name": name,
                    "params": asdict(morph),
                    "density": packed_float32(apply_print_curves_morph(
                        profile.data.log_exposure, profile.data.density_curves_model,
                        morph, profile_type=profile.info.type,
                    )),
                }
                for name, morph in CASES.items()
            ],
        })

    # Reuse a small established input, quantized before the reference runs.
    image = reference.build_test_image().astype(np.float32).astype(np.float64)
    pipelines = []
    for name, stock, scan_film, black, white, film in (
        ("off", "kodak_portra_endura", False, False, False, "kodak_portra_400"),
        ("combined", "kodak_portra_endura", False, False, False, "kodak_portra_400"),
        ("exhaustion_full", "kodak_2383", False, False, False, "kodak_portra_400"),
        ("combined", "kodak_portra_endura", False, True, True, "kodak_portra_400"),
        ("combined", "kodak_portra_endura", True, False, False, "kodak_portra_400"),
        ("off", "kodak_portra_endura", False, True, True, "kodak_portra_400"),
        ("combined", "kodak_portra_endura", False, True, False, "kodak_portra_400"),
        ("combined", "kodak_portra_endura", False, False, True, "kodak_portra_400"),
        ("combined", "kodak_portra_endura", True, True, True, "kodak_portra_400"),
        ("combined", "kodak_portra_endura", True, True, True, "fujifilm_velvia_100"),
    ):
        params = reference._base_params(
            output_gamut_compress="cam16ucs", print_profile=stock, film_profile=film,
        )
        params.print_render.density_curves_morph = replace(CASES[name])
        params.io.scan_film = scan_film
        params.scanner.black_correction = black
        params.scanner.white_correction = white
        params = digest_params(params)
        pipeline = SimulationPipeline(params)
        taps = {
            tap: packed_float32(pipeline.process(image, inject="rgb_in", collect=tap))
            for tap in ("log_e_film", "cmy_film", "log_e_print", "cmy_print", "rgb_out")
            if not scan_film or tap not in ("log_e_print", "cmy_print")
        }
        pipelines.append({
            "name": f"{film}/{stock}/{name}/direct={scan_film}/black={black}/white={white}",
            "film_profile": film,
            "print_profile": stock,
            "params": reference.params_to_json(params),
            "taps": taps,
        })

    return reference.jsonable({
        "format": "lightsuffer-ios print chemistry fixture v1",
        "upstream": {"url": reference.UPSTREAM_URL, "commit": reference.UPSTREAM_COMMIT},
        "curves": curves,
        "image": {"width": image.shape[1], "height": image.shape[0], **packed_float32(image)},
        "pipelines": pipelines,
    })


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, default=Path("Tests/FilmPhysicsTests/Fixtures"))
    args = parser.parse_args()
    payload = generate()
    args.out.mkdir(parents=True, exist_ok=True)
    destination = args.out / "chemistry.json"
    destination.write_text(json.dumps(payload, indent=2, allow_nan=False) + "\n")
    print(f"Wrote {destination}: {len(payload['curves'])} media x {len(CASES)} curve cases, "
          f"{len(payload['pipelines'])} pipeline cases")


if __name__ == "__main__":
    main()
