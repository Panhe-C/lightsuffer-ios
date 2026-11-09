# PORTING.md — spektrafilm → Swift (slice 1)

Status: **slice 1 ported and validated** (2026-11-09).

This document is the map between the upstream Python engine
([spektrafilm](https://github.com/andreavolpato/spektrafilm) @ `3bb2c2d`, GPLv3)
and the pure-Swift `FilmPhysics` package of this repository.

* Upstream reference tree: `/workspace/spektrafilm/src/spektrafilm` (read only).
* Reference fixtures: `Tests/FilmPhysicsTests/Fixtures/slice1_*.json`, generated
  by `tools/gen_fixtures.py` from the **unmodified** upstream engine.
* The Swift port is a derivative work and is distributed under the GPLv3 as
  well (see `LICENSE`, `NOTICE`).

---

## 1. What slice 1 covers

The upstream topology has six taps:

```
rgb_in ──▶ log_e_film ──▶ cmy_film ──▶ log_e_print ──▶ cmy_print ──▶ rgb_out
```

Slice 1 ports everything **after** `log_e_film`:

| Stage | Upstream | Swift | State |
|---|---|---|---|
| spectral upsampling (camera) | `runtime/stages/filming.py` → `utils/spectral_upsampling.py` | — | **not ported** (the tap is injected) |
| negative development | `runtime/stages/filming.py::develop` → `model/develop.py::develop` | `Pipeline.swift::developFilm` | ported |
| DIR couplers | `model/couplers.py` | `Couplers.swift` | ported (per pixel, no diffusion) |
| printing (exposure) | `runtime/stages/printing.py::expose` | `Pipeline.swift::exposePrint`, `Printing.swift`, `Enlarger.swift` | ported |
| printing (development) | `runtime/stages/printing.py::develop` → `model/develop.py::develop_print_morph` | `Printing.swift::develop` | ported (morph inactive) |
| scanning | `runtime/stages/scanning.py::scan` | `Scanning.swift` | ported (no blur / unsharp / glare) |
| output gamut compression | `utils/gamut_compression.py::compress_rgb` | — | **not ported** (`"off"` in the fixtures) |
| profile loading | `profiles/io.py` | `Profile.swift` | ported |
| parameter digest | `runtime/params_builder.py::digest_params` | `Digest.swift` | ported (film specifics) |

Public entry point:

```swift
let pipeline = try Slice1Pipeline(film: film, print: print, inputs: inputs)
let taps = try pipeline.run(logEFilm: image)   // -> cmyFilm, logEPrint, cmyPrint, rgbOut
```

---

## 2. Mapping table (upstream → Swift)

| Upstream function | File | Swift symbol |
|---|---|---|
| `spektrafilm.profiles.io.profile_from_dict` / `load_profile` / `_validate_profile` | `Sources/FilmPhysics/Profile.swift` | `ProfileLoader.load(stock:)`, `ProfileLoader.validate(_:stock:)` |
| `spektrafilm.profiles.io.ProfileInfo` / `ProfileData` / `DensityCurvesModel` | `Sources/FilmPhysics/Profile.swift` | `ProfileInfo`, `ProfileData`, `DensityCurvesModel` |
| `spektrafilm.runtime.params_builder._apply_film_specifics` / `_apply_halation_preset` | `Sources/FilmPhysics/Digest.swift` | `Digest.filmRender(for:base:)` |
| `spektrafilm.utils.fast_interp.fast_interp` | `Sources/FilmPhysics/DensityCurves.swift` | `DensityCurves.interpolateExposureToDensity` (axis / clamping / right bias) |
| `numpy.interp` (used by the DIR coupler inversion) | `Sources/FilmPhysics/Numerics.swift` | `Numerics.interpolate(x:axis:values:)` |
| `spektrafilm.model.density_curves.interpolate_exposure_to_density` | `Sources/FilmPhysics/DensityCurves.swift` | `DensityCurves.interpolateExposureToDensity` |
| `spektrafilm.model.develop.develop_simple` | `Sources/FilmPhysics/DensityCurves.swift` | `DensityCurves.interpolateExposureToDensity` (gamma factor) |
| `spektrafilm.model.develop.compute_density_spectral` | `Sources/FilmPhysics/Spectral.swift` | `Spectral.densitySpectral(channelDensity:densityCMY:baseDensity:)` |
| `spektrafilm.utils.conversions.density_to_light` | `Sources/FilmPhysics/Spectral.swift` | `Spectral.densityToLight(density:wavelengths:light:)` |
| `numpy.nan_to_num` | `Sources/FilmPhysics/Numerics.swift` | `Numerics.nanToNum(_:)` |
| `numpy.nanmin` / `numpy.nanmax` / `numpy.nanmean` | `Sources/FilmPhysics/Numerics.swift` | `Numerics.nanMin`, `nanMax`, `nanMean` |
| `numpy.exp(numpy.mean(numpy.log(x)))` (geometric mean) | `Sources/FilmPhysics/Numerics.swift` | `Numerics.geometricMean(_:)` |
| `spektrafilm.model.couplers.compute_dir_couplers_matrix` | `Sources/FilmPhysics/Couplers.swift` | `Couplers.matrix(_:)` |
| `spektrafilm.model.couplers.compute_density_curves_before_dir_couplers` | `Sources/FilmPhysics/Couplers.swift` | `Couplers.densityCurvesBeforeCouplers(...)` |
| `spektrafilm.model.couplers.compute_exposure_correction_dir_couplers` (no diffusion) | `Sources/FilmPhysics/Couplers.swift` | `Couplers.exposureCorrection(...)` |
| `spektrafilm.model.couplers.apply_density_correction_dir_couplers` | `Sources/FilmPhysics/Pipeline.swift` | `Slice1Pipeline.developFilm(_:)` |
| `spektrafilm.model.develop.develop` (no grain) | `Sources/FilmPhysics/Pipeline.swift` | `Slice1Pipeline.developFilm(_:)` |
| `spektrafilm.model.color_filters.color_enlarger` / `DichroicFilters.apply_cc` | `Sources/FilmPhysics/Enlarger.swift` | `Enlarger.filteredIlluminant(...)` |
| `spektrafilm.runtime.services.filter_enlarger_source.EnlargerService` | `Sources/FilmPhysics/Enlarger.swift` | `Enlarger.filteredIlluminant(...)` (+ the CC shifts in `Pipeline.swift`) |
| `spektrafilm.runtime.stages.printing._exposure_factor` | `Sources/FilmPhysics/Enlarger.swift` | `Enlarger.exposureFactor(...)` |
| `spektrafilm.runtime.stages.printing.PrintingStage._compute_exposure_factor_midgray` | `Sources/FilmPhysics/Enlarger.swift` | `Enlarger.exposureFactorUsed(...)` |
| `spektrafilm.runtime.stages.printing.PrintingStage._film_cmy_to_print_log_raw` | `Sources/FilmPhysics/Printing.swift` | `Printing.filmCMYToPrintLogRaw(...)` |
| `spektrafilm.runtime.stages.printing.PrintingStage._compute_raw_preflash` | `Sources/FilmPhysics/Printing.swift` | `Printing.rawPreflash(...)` |
| `spektrafilm.runtime.stages.printing.PrintingStage.expose` | `Sources/FilmPhysics/Pipeline.swift` | `Slice1Pipeline.exposePrint(_:colorReference:)` |
| `spektrafilm.utils.morph_curves._evaluate_fitted_density` | `Sources/FilmPhysics/DensityCurves.swift` | `DensityCurves.evaluateFittedDensity(...)` |
| `spektrafilm.model.develop.develop_print_morph` (morph inactive) | `Sources/FilmPhysics/Printing.swift` | `Printing.develop(logRaw:printProfile:)` |
| `spektrafilm.runtime.services.color_reference.ColorReferenceService` | `Sources/FilmPhysics/ColorReference.swift` | `ColorReference` |
| `spektrafilm.runtime.stages.scanning.ScanningStage._return_callable_cmy_to_log_xyz` | `Sources/FilmPhysics/Scanning.swift` | `Scanning.cmyToLogXYZ(...)` |
| `spektrafilm.runtime.stages.scanning.ScanningStage._density_to_rgb` | `Sources/FilmPhysics/Scanning.swift` | `Scanning.scan(...)` |
| `spektrafilm.runtime.stages.scanning.ScanningStage._apply_cctf_encoding` (`colour.RGB_to_RGB`) | `Sources/FilmPhysics/Scanning.swift` + `Colour.swift` | `Scanning.scan(...)` + `Colour.sRGBEncode(_:)` |
| `colour.XYZ_to_RGB` (sRGB, CAT02 from the scan illuminant) | `Sources/FilmPhysics/Scanning.swift` | the `xyzToRGB` matrix of `ScannerInputs` (see §4) |
| `colour.models.eotf_sRGB` / `eotf_inverse_sRGB` | `Sources/FilmPhysics/Colour.swift` | `Colour.sRGBDecode(_:)`, `Colour.sRGBEncode(_:)` |
| `colour.XYZ_to_Lab` | `Sources/FilmPhysics/Colour.swift` | `Colour.xyzToLab(_:)`, `Colour.sRGBToLab(_:)` |
| `colour.difference.delta_E_CIE2000` (Sharma et al. 2005) | `Sources/FilmPhysics/Colour.swift` | `Colour.deltaE2000(_:_:)` |
| `scipy.stats.norm.cdf` | `Sources/FilmPhysics/Numerics.swift` | `Numerics.normalCDF(_:)` (via `erf`/`erfc`, ≤ 1e-14) |

---

## 3. Numerical fidelity notes

The port follows the upstream code line by line. The points that needed care:

1. **`fast_interp` is not `numpy.interp`.** The upstream kernel
   (`utils/fast_interp.py`) uses a per channel axis
   (`log_exposure[:, None] / gamma_factor`), clamps the values outside the
   axis, is right biased on the axis knots and gives a zero slope to
   duplicated axis entries. `DensityCurves.interpolateExposureToDensity`
   reproduces all of it; `Numerics.interpolate` reproduces the plain
   `numpy.interp` used by the DIR coupler inversion (clamping, exact knot
   values, `NaN` in → `NaN` out).
2. **`numpy.interp` on a non monotonic axis.** The DIR coupler inversion
   interpolates on `log_exposure - inhibitors`, which is ascending for every
   shipped profile (verified for Portra 400 in `ProfileLoaderTests`). The
   Swift implementation follows the `numpy.interp` semantics for an
   ascending axis.
3. **The normal CDF.** `scipy.stats.norm.cdf` is reproduced with
   `erf`/`erfc` built on the regularised incomplete gamma function
   (series + continued fraction). The agreement with SciPy is ≤ 1e-14
   (`NumericsTests.testNormalCDF`).
4. **`NaN` handling.** The upstream profiles store the missing measurements as
   `NaN` (JSON `null`); the Swift loader maps `null` to `Double.nan`.
   `density_to_light` turns a `NaN` density into *no* light, `nan_to_num`
   turns the `NaN` sensitivities into zero — both reproduced.
5. **The XYZ → RGB matrix of the scanning stage.** `colour.XYZ_to_RGB`
   applies the CAT02 adaptation **to the input** and then the (unadapted)
   sRGB matrix. The reference fixture stores the resulting matrix the way
   `colour.XYZ_to_RGB(identity, …)` returns it, i.e. **row `i` is the RGB
   response to the `i`-th XYZ basis vector**; the port therefore converts
   with the row vector product `rgb = xyz · matrix`. (The note of the fixture
   calls it `rgb = result @ xyz`, which is the transposed convention — the
   *data* is right, the wording of the note is not.)
   The sRGB → sRGB matrix of the output transfer function is applied the
   other way round (`rgb = matrix · rgb`), exactly like
   `colour.RGB_to_RGB`.
6. **The sRGB matrices** are the rounded ones of `colour-science`
   (`3.2406, -1.5372, …`), so that the Lab conversion of the port agrees
   with the upstream engine to the last digits.
7. **The print development uses the fitted CDF model**
   (`utils/morph_curves._evaluate_fitted_density`), not the stored density
   curves — the stored curves are only used by the black/white reference of
   the print, exactly as upstream.

---

## 4. Values taken from the fixtures (TODO list)

The following upstream inputs are **not** computed by the Swift port yet; they
are loaded from the reference fixtures and passed to the pipeline as explicit
inputs (`Slice1Inputs`). Every one of them is listed here.

| # | Value | Upstream origin | Where it is used in the port | TODO |
|---|---|---|---|---|
| 1 | `density_spectral_midgray`, `density_spectral_midgray_comp` | `runtime/stages/filming.py::_compute_density_spectral_midgray_to_balance_print` (needs the hanatos2025 spectral upsampling of the 0.184 grey patch) | `EnlargerInputs.densitySpectralMidgray` | Port the hanatos2025 upsampling (spectral LUT) and compute the reference in the port. |
| 2 | Neutral CC filter values (C, M, Y) | `runtime/params_builder.py::apply_database_neutral_print_filters` reading `data/filters/neutral_print_filters.json` | `EnlargerInputs.neutralFilterCC` | Bundle the neutral filter database and do the lookup in `Digest`. |
| 3 | TH-KG3 light source spectrum | `model/illuminants.py::standard_illuminant` | `SpectralInputs.enlargerLightSource` | Port the illuminant tables (CIE / TH-KG3). |
| 4 | CMY dichroic filter transmittance | `model/color_filters.py::DichroicFilters` (synthetic filters) | `SpectralInputs.dichroicFilters` | Port the filter model (`create_combined_dichroic_filter`). |
| 5 | Scan illuminant spectrum + normalisation | `model/illuminants.py::standard_illuminant`, `config.py::STANDARD_OBSERVER_CMFS` | `SpectralInputs.scanIlluminant`, `scanIlluminantNormalization` | Port the illuminant tables and the CIE 1931 2° CMFs. |
| 6 | CIE 1931 2° colour matching functions | `config.py::STANDARD_OBSERVER_CMFS` | `SpectralInputs.colourMatchingFunctions` | Port the CMF table (or bundle it as a resource). |
| 7 | XYZ → sRGB matrix (CAT02 adaptation) | `colour.XYZ_to_RGB(…, illuminant=scan_illuminant_xy)` | `ScannerInputs.xyzToRGB` | Port the chromatic adaptation (CAT02 / Bradford) so that the matrix is computed instead of loaded. |
| 8 | sRGB → sRGB matrix of the output transfer function | `colour.models.matrix_RGB_to_RGB(sRGB, sRGB)` (Bradford round trip) | `ScannerInputs.srgbToSRGB` | Same as above. |
| 9 | Enlarger exposure factor (mid grey) | derived from 1 + 3 + 5 | computed in the port from 1/3/5 (`Enlarger.exposureFactor`) — only the *reference density* comes from the fixture | — |
| 10 | Scanner white / black correction levels | `runtime/services/color_reference.py` (`_remove_sRGB_cctf`) | `ColorReference.blackLevel` / `whiteLevel` | The correction itself is ported; the levels are still taken from the fixture. |
| 11 | hanatos2025 tc LUT | `utils/spectral_upsampling.py::compute_hanatos2025_tc_lut` | not used in slice 1 | Port together with #1 (the camera stage is out of scope for slice 1). |

The **black / white printing exposure correction** and the **black / white XYZ
correction** *are* ported (`Sources/FilmPhysics/ColorReference.swift`); they
are inactive in the reference fixtures (the scanner correction is disabled),
so the parity test does not exercise them — only a smoke test
(`testBlackAndWhiteCorrectionRuns`) runs that path.

---

## 5. Measured errors

The Swift pipeline is fed with the `log_e_film` tap of the reference fixtures
and every downstream tap is compared with the reference.

Reference fixtures are stored with **seven significant digits**, so the
rounding alone is worth ≈ 1e-6 — the measured errors sit exactly on that
floor.

| Case | `cmy_film` (max abs) | `log_e_print` (max abs) | `cmy_print` (max abs) | `rgb_out` (max abs) | `rgb_out` mean ΔE₀₀ | `rgb_out` max ΔE₀₀ |
|---|---|---|---|---|---|---|
| `defaults` | 1.0417e-06 | 7.2062e-07 | 7.0010e-07 | 2.2302e-04 | **0.002450** | 0.010716 |
| `camera_ev_plus1` | 8.8654e-07 | 5.2414e-07 | 7.4257e-07 | 2.2052e-04 | **0.002413** | 0.010677 |
| `print_exposure_and_filter_shifts` | 1.0417e-06 | 5.6148e-07 | 7.4609e-07 | 2.1097e-04 | **0.002296** | 0.009934 |
| `dir_couplers_inactive` | 6.6316e-07 | 3.5987e-07 | 7.0996e-07 | 1.2006e-04 | **0.001938** | 0.007900 |

The ΔE₀₀ numbers are computed on the **sRGB encoded output clipped to
[0, 1]**, converted to CIELAB (D65) and compared with the Sharma et al.
(2005) CIEDE2000 formula.

Gates implemented in `Tests/FilmPhysicsTests/Slice1ParityTests.swift`:

* mean ΔE₀₀ < 0.5 (the acceptance criterion of the plan) — **measured ≈ 0.0025**;
* tightened: mean ΔE₀₀ < 0.01 and max ΔE₀₀ < 0.05;
* tap wise: max abs error < 5e-6 for `cmy_film`, `log_e_print`, `cmy_print`
  (the plan asked for 1e-3).

Other measured quantities:

| Quantity | Measured |
|---|---|
| exposure factor (defaults) | 0.8357499920608669 vs. 0.8357499 (reference) |
| print black reference (`log_raw_print_black`) | max abs error 2.15e-08 |
| print white reference (`log_raw_print_white`) | max abs error 3.29e-07 |
| profile data vs. the digested fixture data | max relative difference ≤ 1e-6 (7 digit rounding) |
| DIR coupler inhibitor matrix | max relative difference ≤ 1e-6 |
| density curves before the couplers | max relative difference ≤ 1e-6 |
| fitted print density curves | max relative difference ≤ 1e-6 |
| CIEDE2000 vs. the 33 published Sharma pairs | ≤ 1e-4 (the published precision) |

---

## 6. Test suite

| Test file | What it covers |
|---|---|
| `Tests/FilmPhysicsTests/Slice1ParityTests.swift` | The tap by tap parity of the four parameter cases, the print balance reference, the exposure factor and the black / white correction path. |
| `Tests/FilmPhysicsTests/ProfileLoaderTests.swift` | The profile loader against the digested fixture data, the `NaN` handling, the parameter digest, the DIR coupler matrix and the curves before the couplers. |
| `Tests/FilmPhysicsTests/ColourTests.swift` | The sRGB transfer function, the sRGB ↔ XYZ matrices, the CIELAB conversion and the CIEDE2000 formula against the published Sharma test pairs. |
| `Tests/FilmPhysicsTests/NumericsTests.swift` | The interpolation semantics, the geometric mean, the `NaN` aware statistics and the normal distribution function. |
| `Tests/FilmPhysicsTests/FilmPhysicsTests.swift` | The package scaffold, the bundled profiles and the shape of the reference fixtures. |

```
swift build
swift test
```

---

## 7. Next steps (phase 2 of the plan)

* Port the hanatos2025 spectral upsampling and the camera stage, so that the
  whole `rgb_in → log_e_film` path becomes available and the print balance
  reference is computed by the port (#1, #11).
* Port the chromatic adaptation (CAT02 / Bradford) so that the colour
  matrices are computed instead of loaded (#7, #8).
* Bundle the neutral print filter database (#2) and the illuminant / CMF
  tables (#3 – #6).
* Port the spatial effects (halation, grain, DIR coupler diffusion, diffusion
  filters, glare, blur, unsharp mask) — phase 2 of `docs/PLAN.md`.
