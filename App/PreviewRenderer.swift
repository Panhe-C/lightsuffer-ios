import CoreGraphics
import FilmPhysics
import FilmPhysicsMetal
import LightSufferPreview
import Metal

struct RenderedPreview: @unchecked Sendable {
    let image: CGImage
    let backendName: String
}

enum PreviewRenderer {

    /// Runs synchronously; the view model calls this from a detached task.
    static func render(
        _ photo: PreparedPhoto,
        request: PreviewRenderRequest
    ) throws -> RenderedPreview {
        let params = try request.pipelineParams()

        // A Metal device alone is not enough: MetalBackend can return nil for
        // a missing command queue and can report a shader compilation error
        // through initializationError.  Both cases select the CPU reference.
        let backend: any FilmRenderBackend
        let backendName: String
        if let device = MTLCreateSystemDefaultDevice(),
           let metal = MetalBackend(device: device),
           metal.initializationError == nil {
            backend = metal
            backendName = "Metal"
        } else {
            backend = CPUBackend()
            backendName = "CPU"
        }

        let output = try backend.render(photo.input, params: params)
        let pixels = try SRGBPixelBuffer(encodedSRGB: output)
        return RenderedPreview(
            image: try CGImagePixels.makeImage(from: pixels),
            backendName: backendName
        )
    }
}
