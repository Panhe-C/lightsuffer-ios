import CoreGraphics
import PhotosUI
import SwiftUI

struct ContentView: View {
    @StateObject private var model = PreviewViewModel()
    @State private var selection: PhotosPickerItem?
    @State private var holdingOriginal = false

    private var displayedImage: CGImage? {
        if holdingOriginal {
            return model.originalImage
        }
        return model.gradedImage ?? model.originalImage
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                if let image = displayedImage {
                    Image(decorative: image, scale: 1, orientation: .up)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .gesture(compareGesture)
                        .accessibilityLabel(
                            holdingOriginal ? "Original photo" : "Film-graded preview"
                        )
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 44))
                        Text("Choose a photo to begin")
                            .font(.headline)
                        Text("The whole frame is previewed at a 1280-pixel long edge.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .foregroundStyle(.white)
                    .padding()
                }

                if model.activity != .idle {
                    VStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.large)
                        Text(model.activity == .loading ? "Decoding photo…" : "Rendering film preview…")
                            .font(.callout)
                    }
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                    .allowsHitTesting(false)
                }
            }
            .navigationTitle("light suffer胶片")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    PhotosPicker(selection: $selection, matching: .images) {
                        Label("Choose Photo", systemImage: "photo.on.rectangle")
                    }
                    .accessibilityIdentifier("choose-photo")
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 6) {
                    if let errorMessage = model.errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("Kodak Portra 400 → Portra Endura")
                        .font(.footnote)
                    if let backendName = model.backendName {
                        Text("Rendered with \(backendName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if model.gradedImage != nil {
                        Text("Hold the photo to see the original; release to restore the grade.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial)
            }
            .onChange(of: selection) { _, newSelection in
                holdingOriginal = false
                model.select(newSelection)
            }
        }
        .preferredColorScheme(.dark)
    }

    private var compareGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                if model.gradedImage != nil {
                    holdingOriginal = true
                }
            }
            .onEnded { _ in
                holdingOriginal = false
            }
    }
}
