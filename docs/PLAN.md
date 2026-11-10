# light suffer胶片 — iOS app: Phase 0 plan

Date: 2026-11-09 (Asia/Shanghai). Status: decisions taken (see §0); development started in this repo.
User ask: 「现在开始开发ios-app吧，保留spektrafilm的所有功能」.

Sources read on the box:
- Mini program `/workspace/wx-spektrafilm`: branch `feat/film-border` @ `571f84f` (PR #1, not merged), main @ `9901163`.
  https://github.com/Panhe-C/wx-spektrafilm
- Mac border app `/workspace/mac-frame/lightsuffer-border-mac` @ `f6de465`.
  https://github.com/Panhe-C/lightsuffer-border-mac
- Upstream spektrafilm `/workspace/spektrafilm` @ `3bb2c2d` (2026-06-07).
  https://github.com/andreavolpato/spektrafilm
- vkdt filmsim, a GPU port of spektrafilm: https://jo.dreggn.org/vkdt/src/pipe/modules/filmsim/readme.html


## 0. User decisions (2026-11-09) — these override the recommendations below

1. **Build the full spektrafilm physical engine directly**, with every parameter live. The baked-LUT-first path (P1–P4 LUT engine) is skipped. Baked LUTs may only be used as a test oracle or as a thumbnail cache; the product engine is physical.
2. **Installation / distribution: decided later.** No signing, Apple account or store work for now.
3. **Repo: public `Panhe-C/lightsuffer-ios`, GPLv3.**

Reshaped phases:
- **P1 — Physical core on Linux:** SwiftPM `FilmPhysics` (pure Swift CPU reference of the spektrafilm pipeline). Slice 1: profile loading, negative development for one stock, print on one paper, scan, validated against Python `simulate()` tap fixtures (mean ΔE2000 < 0.5). Then: spectral upsampling (hanatos2025), all stocks × prints, couplers, enlarger filters/preflash, chemistry morph, gamut compression.
- **P2 — Spatial effects (CPU):** halation/scatter, grain, DIR-coupler diffusion, diffusion filters, glare, blur, unsharp mask. *Status 2026-11-10: the deterministic effects are ported and parity tested (slice 5, mean ΔE2000 ≈ 0.0011); the grain and the glare are stochastic and are deferred to the next slice.*
- **P3 — Metal port** of P1–P2 with parity tests vs the CPU reference on the macOS CI simulator.
- **P4 — App shell:** SwiftUI, photo/RAW input, all parameters (basic/advanced tiers), export, borders via FrameCore (lightsuffer-border-mac dependency).
- **P5 — Release** per a later distribution decision.

---

## 1. Feature inventory

### 1a. What the mini program exposes today

| Area | Feature | Source |
|---|---|---|
| Input | Pick from the album or take a photo. The picture is EXIF-uprighted and resized within bounds, and the whole frame is decoded (no crop). | `utils/photo.js`, `docs/ORIENTATION.md` |
| Presets | **11 stocks** in 3 groups. **Colour negative (6):** Portra 400, Portra 160, Gold 200, Ultramax 400, Ektar 100, Pro 400H. **Slide / direct scan (3):** Velvia 100, Provia 100F, Kodachrome 64. **Cinema (2):** Vision3 250D, Vision3 500T. Each stock has a fixed print pairing (Portra/Supra/Ultra Endura, Crystal Archive II, 2383). | `tools/stocks.json`, `subpackages/luts/luts.json` |
| Preset cards | Name, ISO, a one-line Chinese description, and a lazy 16:9 centre-cropped live thumbnail (96×54) cached per photo. | `utils/thumbnail.js`, `docs/UI.md` |
| LUTs | Per stock: a 33³ base cube and a 49³ "ev2" cube with +2 EV headroom. Both are 8-bit sRGB PNG tiled grids. 22 PNGs, 1.1 MB. Baked with the single physical recipe `native_zero_scan_v2` (TH-KG3, database neutral filters, scanner white 0.98 / black 0.01, cam16ucs output gamut). | `tools/pipeline_config.py`, `docs/LUT_FORMAT.md` |
| Adjustments | **5 sliders plus intensity.** 曝光 EV −2…+2 (linear, before the LUT). 色温 and 色调 −100…+100 (Bradford, before the LUT). Under 「后期微调（非胶片物理）」: 对比度 −1…1 (×0.7…1.4) and 饱和度 0…2. 强度 0–100 %. One 「重置」 button. | `utils/adjust.js`, `docs/ADJUSTMENTS.md` |
| Effects | **3 effects.** 颗粒 grain 0…2: hash value noise with per-stock measured amplitude and RGB correlation. 光晕 halation 0…2: red-weighted bloom, σ 65 µm still / 50 µm cine, per-stock `halation_strength`, applied before the LUT. 暗角 vignette 0…1, non-physical. 「重置效果」 button. | `utils/effects.js`, `shaders/halo.frag.glsl`, `docs/EFFECTS.md` |
| Viewing | Press and hold to compare with the original, clear, letterboxed preview. | `pages/index/index.js` |
| Export | Long edge = min(original, 4096, GPU limit). Tiled render that stays seamless with effects. JPEG q 0.92 to the album. Stage progress, cancel, and timeouts with retry. | `utils/export.js`, `docs/EXPORT.md` |
| Borders (PR #1) | **10 options:** none, 细白边, 拍立得, 黑边, 35mm 胶片 (sprockets, edge print with stock name, frame no.), 120 胶片, and 4 irregular edges (细黑 / 黑 / 细白 / 白). Seeded, never graded, included in the export. | `utils/border.js`, `docs/BORDER.md` |
| About | spektrafilm credit, licence split (GPLv3 code, CC BY-SA 4.0 LUT data), version, approximation note, hidden 诊断 (GL diagnostics). | `pages/index/*`, `utils/diagnostics.js` |
| WeChat only | Privacy-authorisation popup and WeChat permission recovery. These are not needed on iOS; iOS uses `NSPhotoLibraryAddUsageDescription` instead. | `utils/privacy.js`, `utils/export-wechat.js` |

### 1b. What upstream spektrafilm offers beyond that

Profiles are in `src/spektrafilm/data/profiles/*.json`. There are 28 in total.

- **20 camera films** (the mini program ships 11 of them):
  - **Still negative (11):** Portra 160 / 400 / 800 / 800 push1 / 800 push2, Ektar 100, Gold 200, Ultramax 400, Pro 400H, Fujicolor C200, Superia X-TRA 400.
  - **Cine negative (5):** Vision3 50D / 200T / 250D / 500T, Verita 200D.
  - **Positive / slide (4):** Velvia 100, Provia 100F, Kodachrome 64, Ektachrome 100.
  - **Missing from the mini program (9):** Portra 800, 800 push1, 800 push2, C200, X-TRA 400, Vision3 50D, Vision3 200T, Verita 200D, Ektachrome 100.
- **8 print media:**
  - **Papers (6):** Portra Endura, Supra Endura, Ultra Endura, Endura Premier, Ektacolor Edge, Fujifilm Crystal Archive Type II.
  - **Cine print films (2):** Kodak 2383 and 2393.
  - The mini program uses 5 of them, as fixed pairings. The user cannot choose the paper.
- **Every film × print combination:** 16 negatives × 8 prints + 4 direct-scan positives = **132 looks**. The mini program has 11.
- **GUI parameters:** 107 `ParamSpec` entries in `src/spektrafilm_gui/param_manifest.py`, about 118 in practice because the diffusion group is instantiated for both the camera and the enlarger. Grouped as follows:
  - **Camera:** exposure compensation EV, auto exposure (7 metering methods), film format mm, lens blur µm, camera diffusion filter.
  - **Diffusion filter, camera and enlarger:** families glimmerglass / black_pro_mist / pro_mist / cinebloom. Strength, spatial scale, halo warmth, and core / halo / bloom intensity and size.
  - **DIR couplers:** on, amount, same-layer and interlayer inhibition, interlayer gammas, diffusion size µm.
  - **Halation and scatter:** amounts, spatial scales, highlight boost (`boost_ev`, protect, range), scatter core / tail, halation strength, first σ, number of bounces, bounce decay.
  - **Grain:** on, sublayers, particle area / scale (per layer), density min, uniformity, blur, dye-cloud blur, micro-structure. This is a stochastic particle model.
  - **Enlarger / print:** illuminant, print exposure, exposure compensation, **Y/M filter shifts**, preflash exposure and its Y/M shifts, enlarger diffusion.
  - **Chemistry (print density-curve morph):** gamma factor (overall, fast, slow, R/G/B), developer exhaustion.
  - **Glare:** percent, roughness, blur.
  - **Scanner:** lens blur, white / black correction and levels, unsharp mask, `scan_film` (direct scan).
  - **Gamut:** input gamut compress (xy / oklch) and output gamut compress (off / oklch / aces_rgc / oklrab / jzazbz / cam16ucs).
  - **Colour I/O:** 7 input colour spaces (sRGB, DCI-P3, Display P3, Adobe RGB, BT.2020, ProPhoto, ACES2065-1), CCTF decode, output and saving colour space.
  - **Spectral settings:** RGB→spectrum method (hanatos2025 / mallett2019) and its adaptation flags.
  - **Other:** channel swaps, upscale factor, crop.
- **GUI extras** (`src/spektrafilm_gui/`):
  - RAW import with white balance as-shot / daylight / tungsten / custom, temperature and tint (`utils/raw_file_processor.py`).
  - Rotate, white padding (print border), 18 % grey canvas.
  - Preview and final scan quality. Save to file.
  - Save / load state and save as default (`controller_persistence.py`).
  - Polaroid animation and virtual paper back.

**Dropped by the mini program because it uses baked static LUTs:**
- the film × paper choice (11 of 132 looks);
- every live physical parameter except camera EV and white balance: print exposure, enlarger filters, preflash, couplers, chemistry morph, gamut and scanner options, input colour space;
- physical grain and halation/scatter, which were replaced by measured approximations;
- diffusion filters, glare, lens blur and unsharp mask;
- RAW input.

The mini program's own `docs/LIMITATIONS.md` lists these.

---

## 2. Recommended iOS architecture

**Recommendation: a hybrid with two engines behind one `FilmEngine` protocol.**

1. **LUT engine (ship first).** It reproduces the mini program on Metal and the user can choose among all 132 film × print looks. The LUT cubes are baked on the box with the existing `tools/bake_luts.py` recipe extended to every pair, about 132 × ~100 KB ≈ 13 MB, which is fine for an app.
2. **Physical engine (later, behind a 「物理模式」 toggle).** It is an on-device Metal port of the spektrafilm pipeline: spectral upsampling → film exposure → halation/scatter → development with couplers and grain → enlarger print → scan. All upstream parameters become live sliders.
   - **Feasibility:** vkdt already runs spektrafilm on the GPU interactively. Per-pixel work is a few thousand FLOPs over about 81 wavelengths, which an A-series GPU handles in real time at preview size and in seconds at 12–48 MP.
   - **Effort:** the Python core is about 9.8 k lines. The work is numerical porting plus binary packing of the profile JSON (5.6 MB) and the spectral-upsampling tables (9.8 MB).
   - **Validation:** Swift/Metal output is checked against Python `simulate()` golden images generated on the box (the `venv-sf` already exists) with ΔE2000 gates. This is the same method the mini-program harness used.
   - **Licence caveat:** a port of spektrafilm code is a GPLv3 derivative (see decision 2). vkdt's GLSL implementation is a useful reference; check its licence before borrowing any code.

**Stack**
- **UI and minimum OS:** SwiftUI, minimum **iOS 17** (Observation, mature `PhotosPicker`, Metal 3).
- **Rendering:** Metal compute kernels with LUTs in `MTLTexture.type3D` and an explicit half-texel trilinear sampler, matching `docs/LUT_FORMAT.md`. Grain, halation and vignette run as compute passes. Core Image is used only for decoding.
  - Core Image's `CIColorCube` was rejected: it would not let us match the existing trilinear rule or the effect order.
- **Input:**
  - `PhotosPicker` and the camera via `UIImagePickerController`.
  - JPEG, HEIC/HEIF, PNG and **RAW/ProRAW DNG** through `CIRAWFilter`, which gives scene-linear input. RAW suits the physical engine. The LUT engine takes sRGB-encoded input, so RAW is rendered to sRGB first.
  - Display P3 sources are converted.
- **Output:**
  - Save to Photos with `PHPhotoLibrary` (add-only permission) or share via `ShareLink` / Files.
  - JPEG, HEIC, or 16-bit TIFF.
  - Full original resolution with tiled rendering, without the mini program's 4096 cap (an optional cap is kept).
  - EXIF is kept with optional location stripping, plus a non-destructive "edited" adjustment-data record.
- **Borders:** reuse **FrameCore** from lightsuffer-border-mac as a SwiftPM dependency. It already passes 280/280 parity with `border.js`. Add a UIKit / CoreGraphics canvas, mirroring `FrameKit/CGCanvas.swift`.
- **State:** a look is serialised as a Codable value with stock, print, adjustments, effects, border, engine and physical params. Users can save their own presets, which mirrors the GUI's save/load state.

**Project layout (new repo, e.g. `lightsuffer-ios`)**
```
Package.swift                 # SwiftPM, builds + tests on Linux (box) and macOS
  Sources/FilmCore/           # pure Swift: LUT format decode, CPU reference trilinear, adjust.js port,
                              #   effects.js model port, stock catalogue, Look state (Codable)
  Sources/SpektraCore/        # (later) pure-Swift physical pipeline reference (CPU, slow, testable on Linux)
  Sources/FilmMetal/          # Apple-only: Metal kernels + renderer, tiling export
  Sources/FilmIO/             # Apple-only: decode (ImageIO/CIRAWFilter), encode, Photos save
  dependency: lightsuffer-border-mac → FrameCore
App/                          # SwiftUI app target (screens, view models)
project.yml                   # XcodeGen spec → .xcodeproj generated in CI (not committed)
Resources/LUTs/, Resources/Spektra/   # baked cubes + packed profiles (CC BY-SA 4.0 + SPEKTRAFILM_LICENSE.txt)
tools/                        # Python bake/pack + golden generation (reuse wx-spektrafilm/tools)
.github/workflows/ci.yml
```
- **Linux (box):** `swift test` runs FilmCore and SpektraCore against JS/Python golden values: adjust.js, effects.js, LUT lookup, and later simulate().
- **CI (GitHub Actions `macos-15`):**
  1. `xcodegen`, then `xcodebuild test` on the iPhone Simulator: Metal vs CPU reference parity and UI smoke tests.
  2. `xcodebuild build -sdk iphoneos CODE_SIGNING_ALLOWED=NO`, packaged as an unsigned `.ipa` (Payload zip) artifact.
  3. Render a sample contact sheet as an artifact.
  - Free only while the repo is **public**. A private repo on the Free plan gets 2,000 min/month, and macOS minutes count ×10, so roughly 200 macOS minutes (verify the current GitHub pricing).

**Distribution options (list only)**
1. **App Store or TestFlight:** needs the Apple Developer Program at $99/yr.
2. **Free Apple ID with Xcode on a Mac:** sideload to the user's own iPhone, valid 7 days, max 3 apps. Needs Xcode on the Mac mini.
3. **AltStore / SideStore:** re-sign the unsigned `.ipa` with a free Apple ID, auto-refreshed every 7 days.
4. **AltStore PAL or alternative marketplaces:** EU only, so not relevant in China.
5. **Unsigned IPA on GitHub Releases:** for people who sideload themselves.
- The China App Store also needs an ICP 备案 number for apps (MIIT rule since 2024).

---

## 3. Phased plan (pi writes the code; I review, build and test)

| Phase | Scope | Acceptance criteria |
|---|---|---|
| **P0** (this) | Inventory, architecture, decisions | PLAN.md exists; user answers the decisions below |
| **P1 — Core on Linux** | New repo scaffold. FilmCore: LUT PNG/grid decode, CPU trilinear with the half-texel rule, ports of `adjust.js` and `effects.js` (grain hash, halation kernel, vignette), stock catalogue from `luts.json`, Look model. FrameCore dependency. | `swift test` green on the box. CPU LUT output vs `tools/lut_apply.py` ≤ 1 code on the 66 harness pairs. Adjust/effect parity vs the JS modules ≤ 1e-6 on fixed vectors. Borders still 280/280. |
| **P2 — App shell + Metal LUT renderer** | SwiftUI: pick or camera, preview with pinch/zoom, hold-to-compare, preset strip in 3 groups with live thumbnails, adjustments panel (5 sliders + intensity + reset), effects panel. Metal 3D-LUT + effects kernels. XcodeGen + CI. | CI green: simulator tests show Metal vs CPU reference ≤ 1 code on all 11 stocks × test photos. Slider → preview < 33 ms at 1280 px on simulator (logged). Unsigned `.ipa` artifact. Screenshots of every screen attached to the run. |
| **P3 — Export, borders, I/O** | Full-res tiled export (seamless effects), JPEG/HEIC/TIFF, Photos add-only save, share sheet, EXIF handling, HEIC/ProRAW/DNG input, all 10 borders in preview and export, About/licences, diagnostics. | Tiled vs single-pass ≤ 1 code at 3000×2000 with effects on. Framed export leaves the graded photo bit-identical (same test as `test-border-browser.mjs`). 48 MP export finishes within the simulator memory budget. **= mini-program parity (v0.1).** |
| **P4 — Full catalogue (LUT engine)** | Bake all 20 films × 8 prints (132 looks) on the box with the same physical recipe. Film + paper pickers. User presets (save / load / default). | Each bake validated against full `simulate()` like `docs/validation.md`: mean ΔE2000 < 0.01, max < 2. Bundle size < 25 MB. |
| **P5 — Physical engine (CPU reference)** | SpektraCore: pure-Swift port of the spektrafilm pipeline (spectral upsampling, filming, couplers, development, enlarger with filters/preflash/chemistry morph, scan, gamut compress). Profile and table packer. | On the box: Swift vs Python `simulate()` mean ΔE2000 < 0.5 on the test photos for every film × print, with spatial effects off. |
| **P6 — Physical engine on Metal + all parameters** | Metal port of P5. Spatial effects: halation/scatter, physical grain with sublayers, DIR-coupler diffusion, diffusion filters, glare, lens blur, unsharp mask. UI for all ~118 params (basic / advanced tiers mirroring `param_manifest.py`), auto-exposure methods, RAW WB, input colour spaces. | Metal vs SpektraCore ≤ 1 code without effects. Each spatial effect vs Python within documented statistical tolerances. Preview ≥ 15 fps at 1280 px on a recent iPhone (needs a real device, see decision 3). |
| **P7 — Release** | Icons, localisation (zh-Hans primary), privacy manifest (`PrivacyInfo.xcprivacy`), App Store or sideload packaging per decision 3. | Per the chosen channel. Any publish only after the user approves. |

P1–P3 deliver a usable app with the same look as the mini program. P4 gives every upstream film and paper. P5–P6 add every upstream physical parameter.

---

## 4. Decisions that need the user

1. **What does "keep all spektrafilm features" mean?**
   - **(a) Mini-program parity plus all 132 film × paper looks via LUTs.** About 3–4 phases.
   - **(b) Full physical engine on the phone with every upstream parameter live**: enlarger filters, couplers, physical grain, diffusion filters, RAW and so on. Much bigger and riskier.
   - **Recommendation:** do (a) first, then (b) behind a 「物理模式」 switch (P5–P6).
2. **Distribution, Apple account and licence.**
   - TestFlight and the App Store need the $99/yr Developer Program, and a China App Store listing also needs app 备案.
   - The free path is a 7-day sideload via Xcode on the Mac mini, or AltStore with the unsigned IPA from CI.
   - **GPL note:** the App Store's terms are widely considered incompatible with GPLv3; VLC was pulled in 2011. The user can relicense their own code. But the P5/P6 physical engine is a port of Andrea Volpato's GPLv3 code, so an App Store build of it would need his permission (his README invites contact) or a sideload-only distribution. The LUT data (CC BY-SA 4.0) is fine anywhere with attribution.
3. **Repo name and visibility.** Proposed `Panhe-C/lightsuffer-ios` (GPLv3).
   - Public keeps the macOS CI minutes free. Private costs ×10 minutes.
   - Separately: for P6 performance, may we use a real iPhone? That needs a signed build, so it depends on decision 2.

## 5. Process notes
- **Coding:** all code is written by pi (`pi -p --provider minimax-m3 --model MiniMax-M3.1-Flash`, stdin `</dev/null`), following the `/workspace/mac-frame/run_pi.sh` pattern. The coordinator reviews, runs `swift test` on the box, and pushes only after the user agrees on the repo.
- **Licence files:** ship `SPEKTRAFILM_LICENSE.txt`, a CHANGELOG for derived LUTs (required by its preamble), and the 「film modeling powered by spektrafilm」 credit.
