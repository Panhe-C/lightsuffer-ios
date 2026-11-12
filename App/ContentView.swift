import CoreGraphics
import LightSufferPreview
import PhotosUI
import SwiftUI

struct ContentView: View {
    @StateObject private var model = PreviewViewModel()
    @State private var selection: PhotosPickerItem?
    @State private var holdingOriginal = false
    @State private var showingAdjustments = false

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
                    VStack {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text(
                                model.activity == .loading
                                    ? "Decoding photo…" : "Rendering preview…"
                            )
                            .font(.caption)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(.regularMaterial, in: Capsule())
                        .allowsHitTesting(false)
                        Spacer()
                    }
                    .padding(.top, 8)
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
                bottomControls
            }
            .onChange(of: selection) { _, newSelection in
                holdingOriginal = false
                model.select(newSelection)
            }
        }
        .sheet(isPresented: $showingAdjustments) {
            adjustmentsSheet
        }
        .preferredColorScheme(.dark)
    }

    private var bottomControls: some View {
        VStack(spacing: 9) {
            if let errorMessage = model.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            filmStrip

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.look.name)
                        .font(.caption)
                        .lineLimit(2)
                    Text(model.backendName.map { "\($0) backend" } ?? "Metal / CPU automatic")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    showingAdjustments = true
                } label: {
                    Label("Adjustments", systemImage: "slider.horizontal.3")
                        .font(.callout.weight(.medium))
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("open-adjustments")
            }

            if model.gradedImage != nil {
                Text("Hold the photo to compare with the original")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private var filmStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8) {
                    ForEach(model.films, id: \.stock) { film in
                        let selected = film.stock == model.look.film.stock
                        Button {
                            model.selectFilm(stock: film.stock)
                        } label: {
                            Text(film.name)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(selected ? Color.black : Color.white)
                                .padding(.horizontal, 13)
                                .padding(.vertical, 10)
                                .background(
                                    selected ? Color.white : Color.white.opacity(0.12),
                                    in: Capsule()
                                )
                        }
                        .buttonStyle(.plain)
                        .id(film.stock)
                        .accessibilityValue(selected ? "Selected" : "Not selected")
                        .accessibilityHint("Selects this film and its default print or scan")
                    }
                }
                .padding(.horizontal, 2)
            }
            .frame(height: 38)
            .onChange(of: model.look.film.stock) { _, stock in
                withAnimation {
                    proxy.scrollTo(stock, anchor: .center)
                }
            }
        }
    }

    private var adjustmentsSheet: some View {
        NavigationStack {
            Form {
                Section("Film output") {
                    if model.look.film.isPositive {
                        LabeledContent("Output", value: "Direct scan")
                        Text("Slide films are scanned directly; a paper path is not available.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Print / scan", selection: outputBinding) {
                            Text("Direct scan").tag(PreviewLook.directScanIdentifier)
                            ForEach(model.printMedia, id: \.stock) { medium in
                                Text(medium.name).tag(medium.stock)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }

                Section("Camera") {
                    HStack {
                        Text("Exposure compensation")
                        Spacer()
                        Text("\(model.adjustments.exposureCompensationEV, specifier: "%+.2f") EV")
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: $model.adjustments.exposureCompensationEV,
                        in: PreviewAdjustments.exposureCompensationRange,
                        step: 0.01
                    ) {
                        Text("Camera exposure compensation")
                    }
                }

                Section("Physical grain") {
                    Toggle("Grain", isOn: $model.adjustments.grainEnabled)
                    HStack {
                        Text("Grain strength")
                        Spacer()
                        Text("\(model.adjustments.grainStrength, specifier: "%.2f")×")
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: $model.adjustments.grainStrength,
                        in: PreviewAdjustments.grainStrengthRange,
                        step: 0.05
                    ) {
                        Text("Grain strength")
                    }
                    .disabled(!model.adjustments.grainEnabled)
                    Text("1.00× preserves the digested particle sizes. This scales the physical grain model, not a noise overlay.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Halation") {
                    Toggle("Halation", isOn: $model.adjustments.halationEnabled)
                    HStack {
                        Text("Amount")
                        Spacer()
                        Text("\(model.adjustments.halationAmount, specifier: "%.2f")×")
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: $model.adjustments.halationAmount,
                        in: PreviewAdjustments.halationAmountRange,
                        step: 0.05
                    ) {
                        Text("Halation amount")
                    }
                    .disabled(!model.adjustments.halationEnabled)
                }
            }
            .navigationTitle("Physical adjustments")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        showingAdjustments = false
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var outputBinding: Binding<String> {
        Binding(
            get: { model.outputSelection },
            set: { model.selectOutput($0) }
        )
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
