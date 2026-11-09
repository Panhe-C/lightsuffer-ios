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
| P1 | `FilmPhysics`: pure-Swift port of the spektrafilm pipeline (CPU reference), validated tap by tap against the Python engine | **in progress** (slice 1 ported: profile loading, negative development with DIR couplers, enlarger printing, print development, scanning — parity with the Python engine, mean ΔE2000 ≈ 0.0025) |
| P2 | Spatial effects (halation, grain, DIR-coupler diffusion, diffusion filters, glare, blur, unsharp) | not started |
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
  Colour.swift                    sRGB, CIELAB, CIEDE2000
  Pipeline.swift                  the public entry point (Slice1Pipeline)
  Resources/profiles/             spektrafilm profile JSON (unmodified copies)
    kodak_portra_400.json         film    — CC BY-SA 4.0
    kodak_portra_endura.json       print   — CC BY-SA 4.0
    CHANGELOG.txt                 provenance of the copied profiles
Tests/FilmPhysicsTests/           Swift test target
  Fixtures/                       reference fixtures generated from upstream Python
  Slice1ParityTests.swift         tap by tap parity with the Python engine
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
validates the ported slice 1 against the reference fixtures:

* `Slice1ParityTests` — the Swift pipeline is fed with the `log_e_film` tap
  captured from the upstream Python engine and every downstream tap
  (`cmy_film`, `log_e_print`, `cmy_print`, `rgb_out`) is compared with the
  reference. Measured: max abs error ≈ 1e-6 on the density taps and a mean
  ΔE2000 of ≈ 0.0025 on the scanned image (gate: < 0.5).
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

### Profile data

The film and print **profile data** copied from spektrafilm
(`Sources/FilmPhysics/Resources/profiles/*.json`) and every derivative of it
are licensed under the **Creative Commons Attribution-ShareAlike 4.0
International licence (CC BY-SA 4.0)**, as stated in the upstream metadata
and in [`SPEKTRAFILM_LICENSE.txt`](SPEKTRAFILM_LICENSE.txt) at the root of
this repository. Redistribution must credit the author, link the project,
preserve the licence and stay CC BY-SA 4.0; modifications must be noted (see
`Sources/FilmPhysics/Resources/profiles/CHANGELOG.txt`).

If you use these profiles in your work, please cite the spektrafilm project:
<https://github.com/andreavolpato/spektrafilm> (see `CITATION.cff` upstream).

### This repository

* Code (including the Swift port of the physics engine): **GPL-3.0-or-later** —
  [`LICENSE`](LICENSE).
* Bundled/derived spektrafilm profile data: **CC BY-SA 4.0** —
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
