//
//  FilmRenderBackend.swift
//  light suffer胶片 — iOS app
//
//  The backend protocol of the renderer: the CPU reference and the Metal
//  implementation share the same entry point.
//
//  film modeling powered by spektrafilm
//  https://github.com/andreavolpato/spektrafilm
//
//  This file is part of a GPLv3 licensed project; see LICENSE at the repo root.
//

import Foundation

/// A renderer of the film simulation.
///
/// The protocol is the seam between the numerical core (`FilmPhysics`, pure
/// Swift, the reference implementation) and the GPU implementation
/// (`FilmPhysicsMetal`, the Metal port of the same pipeline).
///
/// A backend receives the **camera image** (in the input colourspace of the
/// parameters) and returns the **scanned print** (in the output colourspace
/// of the parameters), exactly like ``FilmPipeline`` does.
///
/// The protocol is intentionally minimal: the plan of the render (the
/// precomputed data the GPU needs) is built by the backend itself, so that
/// the caller does not have to know whether the render happens on the CPU or
/// on the GPU.
public protocol FilmRenderBackend {

    /// Renders an image.
    ///
    /// - Parameters:
    ///   - image: the camera image, in the input colourspace of the
    ///     parameters.
    ///   - params: the parameters of the simulation.
    /// - Returns: the scanned print, in the output colourspace of the
    ///   parameters.
    /// - Throws: `PipelineError` when the parameters or the image are not
    ///   supported.
    func render(_ image: RGBImage, params: PipelineParams) throws -> RGBImage
}

/// The CPU reference implementation of ``FilmRenderBackend``.
///
/// It runs the pure Swift pipeline of ``FilmPipeline`` and returns its
/// `rgb_out` tap. It is the reference the Metal backend is validated
/// against.
public struct CPUBackend: FilmRenderBackend {

    /// Creates the CPU backend.
    public init() {}

    /// Renders an image with the pure Swift pipeline.
    ///
    /// - Parameters:
    ///   - image: the camera image, in the input colourspace of the
    ///     parameters.
    ///   - params: the parameters of the simulation.
    /// - Returns: the scanned print.
    public func render(_ image: RGBImage, params: PipelineParams) throws -> RGBImage {
        let pipeline = try FilmPipeline(params: params)
        let taps = try pipeline.process(rgbIn: image)
        return taps.rgbOut
    }
}
