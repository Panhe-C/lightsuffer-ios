//
//  PreviewLook.swift
//  light suffer胶片 — preview support
//

import FilmPhysics

/// The one fixed look of the minimal app-shell preview.
public enum PreviewLook {
    public static let filmStock = "kodak_portra_400"
    public static let printStock = "kodak_portra_endura"

    /// Loads the bundled profiles and returns the engine's supported default
    /// parameters for that look.
    ///
    /// `StockCatalog.pipelineParams` keeps the pipeline defaults, including
    /// `.fast` grain sampling, ProPhoto RGB linear input and encoded sRGB
    /// output.  It disables only camera auto-exposure, which the current
    /// engine explicitly reports as unported, and applies the stock digest.
    public static func pipelineParams() throws -> PipelineParams {
        try StockCatalog.pipelineParams(
            film: filmStock,
            print: printStock,
            scanFilm: false
        )
    }
}
