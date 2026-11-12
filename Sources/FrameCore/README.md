# Vendored FrameCore

The seven Swift sources in this directory are unmodified copies of
`Sources/FrameCore/*.swift` from
[Panhe-C/lightsuffer-border-mac](https://github.com/Panhe-C/lightsuffer-border-mac)
at commit **`f6de465d5195f01bf6ded1b023e234233dd9ca7b`** (`f6de465`).
They provide the mini-program-compatible border catalogue, layout, seeded
random generator and painter. FrameKit, the Mac application and generated
build products are intentionally not vendored.

Both projects use GPLv3. Core Graphics and Image I/O adapters live in the iOS
app target; this target remains Foundation-only and Linux-testable.
