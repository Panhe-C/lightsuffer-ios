# light suffer胶片 — iOS 版

An iOS app that is a **full port of the [spektrafilm](https://github.com/andreavolpato/spektrafilm)
physical film-simulation engine**: a real spectral simulation of shooting a
negative film, developing it, printing it on paper and scanning the print
back — not a set of baked LUTs.

> film modeling powered by spektrafilm

---

## Status

**Early — the physical engine core is being built on Linux.**

| Phase | Scope | State |
|---|---|---|
| P1 | `FilmPhysics`: pure-Swift port of the spektrafilm pipeline (CPU reference), validated tap by tap against the Python engine | **in progress** (slices 1, 2 and 4 ported: profile loading, the hanatos 2025 spectral upsampling and the whole camera → print → scan chain, negative development with DIR couplers, enlarger printing, print development, scanning, the cam16ucs gamut compression and the whole stock catalogue — parity with the Python engine, mean ΔE2000 ≈ 0.0021) |
| P2 | Spatial effects (halation, grain, DIR-coupler diffusion, diffusion filters, glare, blur, unsharp) | **in progress** (slice 5 ported: the highlight boost, the in-emulsion scatter, the back-reflection halation, the DIR-coupler diffusion, the four diffusion-filter families, the lens blurs and the unsharp mask — parity with the Python engine, mean ΔE2000 ≈ 0.0011. The **grain** and the **glare** are stochastic and are deferred to the next slice) |
| P3 | Metal port of the engine, parity-tested against the CPU reference | not started |
| P4 | SwiftUI app shell (photo/RAW input, all parameters, export, borders) | not started |
| P5 | Release | not started |

See [`docs/PLAN.md`](docs/PLAN.md) for the full plan.

The engine core (`FilmPhysics`) uses **pure Swift + Foundation only** — no
Metal, no UIKit — so it builds and runs its tests on Linux (the development
box), on macOS and on iOS.

---

## Repository layout

```
Package.swift                     SwiftPM manifest (iOS 17 / macOS 14, Linux friendly)
Sources/FilmPhysics/              pure-Swift physical engine (CPU reference)
  FilmPhysics.swift               version + bundled-resource accessors
  Profile.swift                   profile model + loader (spektrafilm.profiles.io)
  Digest.swift                    the digest of the runtime parameters (params_builder)
  Numerics.swift                  interpolation, geometric mean, normal CDF
  DensityCurves.swift             density curves, the fitted CDF model
  Couplers.swift                  the DIR coupler chemistry
  Spectral.swift                  spectral density and light transmittance
  Enlarger.swift                  the filtered illuminant, the exposure factor
  Printing.swift                  the printing stage
  Scanning.swift                  the scanning stage
  ColorReference.swift            the black / white reference of the print
  Colour.swift                    sRGB, ProPhoto RGB, CIELAB, CIEDE2000
  ColourScience.swift             the colour-science primitives (CAT02/CAT16, RGB ↔ XYZ)
  CAM16.swift                     the CAM16 / CAM16-UCS appearance model
  SpectralUpsampling.swift        the hanatos 2025 spectral upsampling and its tc LUT
  Filming.swift                   the filming stage (camera image → log exposure)
  SpatialEffects.swift            the image space filters (separable Gaussian, the
                                  Young & van Vliet IIR, the exponential surrogate,
                                  the unsharp mask)
  DiffusionFilter.swift           the diffusion filters of the camera and of the
                                  enlarger (the four families and their PSF)
  Halation.swift                  the highlight boost, the in emulsion scatter and
                                  the back reflection halation
  GamutCompression.swift          the input and the output gamut compression
  Illuminants.swift               the illuminant spectra and their chromaticity
  NeutralPrintFilters.swift       the neutral print filter database lookup
  ColorFilters.swift              the CMY dichroic filters of the enlarger
  Pipeline.swift                  the slice 1 entry point (Slice1Pipeline)
  FilmPipeline.swift              the slice 2 entry point (FilmPipeline, rgb_in → rgb_out)
  Resources.swift                 the bundled upstream resources (spectra, CMFs, filters)
  Resources/profiles/             spektrafilm profile JSON (unmodified copies)
    kodak_portra_400.json         film    — CC BY-SA 4.0
    kodak_portra_endura.json       print   — CC BY-SA 4.0
    CHANGELOG.txt                 provenance of the copied profiles
  Resources/spectral/             the packed upstream spectral tables
    irradiance_xy_tc.f16          the hanatos 2025 irradiance spectra (float16)
    cmfs_cie1931_2deg.f32          the CIE 1931 2° colour matching functions
    illuminants.f32                TH-KG3, D55, D50 and D65
  Resources/filters/
    neutral_print_filters.json    the neutral print filter database
  Resources/CHANGELOG.txt         provenance of every bundled resource
Tests/FilmPhysicsTests/           Swift test target
  Fixtures/                       reference fixtures generated from upstream Python
  Slice2ParityTests.swift         whole pipeline parity (rgb_in → rgb_out) + the
                                  tc LUT, the CAM16-UCS model, the gamut compressor
  Slice1ParityTests.swift         tap by tap parity with the Python engine
  SpatialParityTests.swift        parity of the spatial effects (the halation, the
                                  highlight boost, the DIR coupler diffusion, the
                                  diffusion filters, the lens blurs, the unsharp
                                  mask) and of the image space helpers
  CatalogParityTests.swift        the whole stock catalogue (148 looks)
  ProfileLoaderTests.swift        the loaded profile vs. the digested fixture data
  ColourTests.swift               sRGB / CIELAB / CIEDE2000 (Sharma test data)
  NumericsTests.swift             the numeric helpers
tools/
  gen_fixtures.py                 regenerates the reference fixtures
  README.md                       how to regenerate them
docs/PLAN.md                      project plan and decisions
docs/PORTING.md                   upstream → Swift mapping, TODO list, measured errors
LICENSE                           GPL-3.0-or-later (this repository)
SPEKTRAFILM_LICENSE.txt           CC BY-SA 4.0 for the upstream spektrafilm data
NOTICE                            attribution
```

---

## Running the tests

```bash
swift build        # build the FilmPhysics library
swift test         # run the FilmPhysics test target
```

The test target checks the package scaffold and the bundled profiles, and
validates the ported slices against the reference fixtures:

* `Slice2ParityTests` — the whole pipeline is fed with the **camera image**
  captured from the upstream Python engine and every tap (`log_e_film`,
  `cmy_film`, `log_e_print`, `cmy_print`, `rgb_out`) is compared with the
  reference. Measured: max abs error ≤ 8.6e-07 on the density taps and a
  mean ΔE2000 of ≈ 0.0021 on the scanned image (gate: < 0.5). The test also
  checks the hanatos 2025 tc LUT (max relative error 2.4e-07), the CAM16-UCS
  model (max abs error 2.5e-05, round trip 1.1e-15), the cam16ucs output
  gamut compressor (max abs error 4.8e-08) and the colour matrices.
* `Slice1ParityTests` — the Swift pipeline is fed with the `log_e_film` tap
  captured from the upstream Python engine and every downstream tap
  (`cmy_film`, `log_e_print`, `cmy_print`, `rgb_out`) is compared with the
  reference. Measured: max abs error ≈ 1e-6 on the density taps and a mean
  ΔE2000 of ≈ 0.0025 on the scanned image (gate: < 0.5).
* `SpatialParityTests` — the deterministic spatial effects (the highlight
  boost, the in-emulsion scatter, the back-reflection halation, the spatial
  diffusion of the DIR-coupler inhibitors, the diffusion filters of the
  camera and of the enlarger, the lens blurs and the unsharp mask) are
  compared with the reference on ten parameter cases (the upstream
  defaults, every effect alone and everything at once). Measured: a mean
  ΔE2000 of 0.00093 – 0.00155 and a max ΔE2000 of 0.0022 – 0.0114 (gates:
  mean < 0.5, tightened to mean < 0.01 and max < 0.05). The image space
  helpers (the FIR and the Young & van Vliet Gaussian, the exponential
  surrogate and the `reflect` boundary) match the reference to ≈ 8e-08.
* `CatalogParityTests` — the whole stock catalogue (the 148 looks of the
  upstream engine) is compared with the reference.
* `ProfileLoaderTests` — the loaded profile data vs. the digested fixture
  data (max relative difference ≤ 1e-6).
* `ColourTests` — the sRGB transfer function, the CIELAB conversion and the
  CIEDE2000 formula against the published Sharma et al. test pairs.
* `NumericsTests` — the interpolation semantics, the geometric mean and the
  normal distribution function.

See [`docs/PORTING.md`](docs/PORTING.md) for the upstream → Swift mapping,
the list of values that are still taken from the fixtures and the measured
error numbers.

> **Linux note.** The Swift toolchain on the development box needs
> `libncurses.so.6`. If `swift test` fails with
> `error while loading shared libraries: libncurses.so.6`, link the shim
> into the toolchain runtime directory (SwiftPM does not forward
> `LD_LIBRARY_PATH` to the compiler driver):
>
> ```bash
> ln -s /usr/lib/x86_64-linux-gnu/libncursesw.so.6 \
>   "$(dirname "$(readlink -f "$(command -v swiftc)")")/../lib/swift/linux/libncurses.so.6"
> ```

## Regenerating the reference fixtures

The fixtures under `Tests/FilmPhysicsTests/Fixtures/` are produced by running
the **unmodified upstream Python engine**, so they are the ground truth for
the Swift port.

```bash
/workspace/venv-sf/bin/python tools/gen_fixtures.py
```

The upstream data tables the package bundles (the hanatos 2025 irradiance
spectra, the CIE 1931 2° CMFs, the illuminant spectra and the neutral print
filter database) are packed into the binary resources of
`Sources/FilmPhysics/Resources/` by:

```bash
/workspace/venv-sf/bin/python tools/pack_resources.py
```

See [`tools/README.md`](tools/README.md) for the details (what is captured, the
parameter cases, the file format and the exact upstream parameters that are
switched off).

---

## Credits and licence

### Physics engine

The physical film-simulation engine in this repository is a **Swift port of
[spektrafilm](https://github.com/andreavolpato/spektrafilm) by Andrea
Volpato**, which is licensed under the **GNU General Public License v3.0
(GPLv3)**. As a derivative work, this repository is distributed under the
**GPLv3** as well — see [`LICENSE`](LICENSE).

The upstream project is the reference implementation of every physical model
used here (spectral upsampling, film exposure and development, DIR couplers,
enlarger printing, scanning) and of the reference fixtures.

### Profile and resource data

The film and print **profile data** copied from spektrafilm
(`Sources/FilmPhysics/Resources/profiles/*.json`), the **spectral resources**
packed from the upstream tables (`Sources/FilmPhysics/Resources/spectral/`,
`Sources/FilmPhysics/Resources/filters/`) and every derivative of them are
licensed under the **Creative Commons Attribution-ShareAlike 4.0
International licence (CC BY-SA 4.0)**, as stated in the upstream metadata
and in [`SPEKTRAFILM_LICENSE.txt`](SPEKTRAFILM_LICENSE.txt) at the root of
this repository. Redistribution must credit the author, link the project,
preserve the licence and stay CC BY-SA 4.0; modifications must be noted (see
`Sources/FilmPhysics/Resources/CHANGELOG.txt`).

If you use these profiles in your work, please cite the spektrafilm project:
<https://github.com/andreavolpato/spektrafilm> (see `CITATION.cff` upstream).

### This repository

* Code (including the Swift port of the physics engine): **GPL-3.0-or-later** —
  [`LICENSE`](LICENSE).
* Bundled/derived spektrafilm profile and spectral data: **CC BY-SA 4.0** —
  [`SPEKTRAFILM_LICENSE.txt`](SPEKTRAFILM_LICENSE.txt).
* Attribution summary: [`NOTICE`](NOTICE).

---

## Credits

* **spektrafilm** — Andrea Volpato — <https://github.com/andreavolpato/spektrafilm>
  (GPLv3 code, CC BY-SA 4.0 profile data). This app exists because of it.
* **colour-science** — the colour conversions used by the upstream engine and
  reproduced by the port.
* **hanatos** — the spectral upsampling method and LUTs used by the upstream
  engine.
