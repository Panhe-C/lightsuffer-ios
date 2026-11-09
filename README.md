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
| P1 | `FilmPhysics`: pure-Swift port of the spektrafilm pipeline (CPU reference), validated tap by tap against the Python engine | **in progress** (scaffold + reference fixtures done) |
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
  Resources/profiles/             spektrafilm profile JSON (unmodified copies)
    kodak_portra_400.json         film    — CC BY-SA 4.0
    kodak_portra_endura.json       print   — CC BY-SA 4.0
    CHANGELOG.txt                 provenance of the copied profiles
Tests/FilmPhysicsTests/           Swift test target
  Fixtures/                       reference fixtures generated from upstream Python
tools/
  gen_fixtures.py                 regenerates the reference fixtures
  README.md                       how to regenerate them
docs/PLAN.md                      project plan and decisions
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

The test target checks the package scaffold, the bundled profiles and the
presence/shape of the reference fixtures. The numerical parity tests
(Swift pipeline vs. the Python reference) are added as the port progresses.

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
