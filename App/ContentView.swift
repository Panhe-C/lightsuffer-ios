import CoreGraphics
import FrameCore
import LightSufferPreview
import PhotosUI
import SwiftUI

struct ContentView: View {
    @StateObject private var model = PreviewViewModel()
    @State private var selection: PhotosPickerItem?
    @State private var holdingOriginal = false
    @State private var showingAdjustments = false
    @State private var showingAdvanced = false

    private var displayedImage: CGImage? {
        if holdingOriginal {
            return model.originalImage
        }
        // The framed preview shows the border of the export with the layout
        // of the full resolution frame.
        return model.framedImage ?? model.gradedImage ?? model.originalImage
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
        .sheet(isPresented: $showingAdvanced) {
            AdvancedParametersView(model: model)
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

            exportControls

            exportStatus

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

    /// The compact export control: the border, the format and the button.
    private var exportControls: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(ExportRequest.offeredBorderStyles, id: \.self) { style in
                    Button {
                        model.selectBorder(style: style)
                    } label: {
                        if style == model.exportBorderStyle {
                            Label(style.displayName, systemImage: "checkmark")
                        } else {
                            Text(style.displayName)
                        }
                    }
                }
            } label: {
                Label(model.exportBorderStyle.displayName, systemImage: "rectangle.dashed")
                    .font(.callout)
                    .lineLimit(1)
            }
            .disabled(model.isExportRunning)
            .accessibilityIdentifier("export-border")

            Menu {
                ForEach(ExportFormat.allCases, id: \.self) { format in
                    Button {
                        model.selectFormat(format: format)
                    } label: {
                        if format == model.exportFormat {
                            Label(format.displayName, systemImage: "checkmark")
                        } else {
                            Text(format.displayName)
                        }
                    }
                }
            } label: {
                Label(model.exportFormat.displayName, systemImage: "photo")
                    .font(.callout)
            }
            .disabled(model.isExportRunning)
            .accessibilityIdentifier("export-format")

            Spacer(minLength: 0)

            Button {
                model.startExport()
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
                    .font(.callout.weight(.medium))
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canExport)
            .accessibilityIdentifier("export-button")
        }
    }

    /// The progress of the export, and its cancel control.
    @ViewBuilder
    private var exportStatus: some View {
        switch model.exportState {
        case .idle:
            EmptyView()
        case .running(let progress):
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    ProgressView(value: progress.fractionCompleted)
                        .progressViewStyle(.linear)
                    Text(model.exportProgressText(progress))
                        .font(.caption)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Button("Cancel") {
                        model.cancelExport()
                    }
                    .font(.caption.weight(.medium))
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("export-cancel")
                }
                if let snapshot = model.exportSnapshotName {
                    Text("Exporting \(snapshot)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        case .cancelled:
            Label("Export cancelled.", systemImage: "xmark.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .saved(let summary):
            Label(summary, systemImage: "checkmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(.green)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
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
                Section("Input") {
                    LabeledContent(
                        "Photo",
                        value: model.photoKind?.displayName ?? "No photo"
                    )
                    LabeledContent(
                        "Decoder",
                        value: model.isRAWPhoto ? "CIRAWFilter · scene-linear" : "Image I/O · floating point"
                    )

                    Picker("White balance", selection: whiteBalanceBinding) {
                        ForEach(WhiteBalanceMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(!model.isRAWPhoto)
                    if !model.isRAWPhoto {
                        Text("White balance applies to RAW files. JPEG, HEIC and PNG are not re-tinted.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    if model.isRAWPhoto && model.inputSettings.whiteBalanceMode == .custom {
                        HStack {
                            Text("Temperature")
                            Spacer()
                            Text("\(customTemperatureBinding.wrappedValue, specifier: "%.0f") K")
                                .foregroundStyle(.secondary)
                        }
                        Slider(
                            value: customTemperatureBinding,
                            in: WhiteBalanceMode.coreImageTemperatureRange,
                            step: 1
                        ) {
                            Text("Custom white-balance temperature")
                        }
                        HStack {
                            Text("Tint (green multiplier)")
                            Spacer()
                            Text("\(model.inputSettings.customTint, specifier: "%.2f")×")
                                .foregroundStyle(.secondary)
                        }
                        Slider(
                            value: customTintBinding,
                            in: 0.5...1.5,
                            step: 0.01
                        ) {
                            Text("Custom white-balance tint")
                        }
                        Text("1.00× is neutral. The upstream green multiplier is mapped to CIRAWFilter’s green–magenta neutralTint axis.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Picker("Input colour space", selection: inputColorSpaceBinding) {
                        ForEach(PhotoInputColorSpace.offered, id: \.self) { selection in
                            Text(selection.displayName).tag(selection)
                        }
                    }
                    .pickerStyle(.menu)

                    if let inputStatus = model.inputStatus {
                        Text(inputStatus)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

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
                        Text("Halation amount")
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

                Section("Advanced parameters") {
                    Button {
                        showingAdvanced = true
                    } label: {
                        Label("Advanced parameters…", systemImage: "gearshape.2")
                    }
                    .accessibilityIdentifier("open-advanced-parameters")
                    Text("The whole parameter surface of the simulation, in its own sheet.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
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

    private var whiteBalanceBinding: Binding<WhiteBalanceMode> {
        Binding(
            get: { model.inputSettings.whiteBalanceMode },
            set: { mode in
                var settings = model.inputSettings
                settings.whiteBalanceMode = mode
                model.inputSettings = settings
            }
        )
    }

    private var customTemperatureBinding: Binding<Double> {
        Binding(
            get: {
                model.inputSettings.customTemperature
                    ?? WhiteBalanceMode.defaultCustomTemperature
            },
            set: { temperature in
                var settings = model.inputSettings
                settings.customTemperature = temperature
                model.inputSettings = settings
            }
        )
    }

    private var customTintBinding: Binding<Double> {
        Binding(
            get: { model.inputSettings.customTint },
            set: { tint in
                var settings = model.inputSettings
                settings.customTint = tint
                model.inputSettings = settings
            }
        )
    }

    private var inputColorSpaceBinding: Binding<PhotoInputColorSpace> {
        Binding(
            get: { model.inputSettings.inputColorSpace },
            set: { selection in
                var settings = model.inputSettings
                settings.inputColorSpace = selection
                model.inputSettings = settings
            }
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
