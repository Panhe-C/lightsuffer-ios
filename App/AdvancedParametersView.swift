import FilmPhysics
import Foundation
import LightSufferPreview
import SwiftUI

/// The advanced parameter panel.
///
/// The panel is **off** the main screen: it is opened from the Adjustments
/// sheet and it never replaces the basic EV / grain / halation controls.
///
/// Every row is one parameter of the engine catalog
/// (`AdvancedParams.catalog`), which mirrors the upstream presentation
/// manifest.  A row shows the *effective* value (the digested value, the
/// advanced override when there is one, and the basic adjustment for the
/// controls the Adjustments sheet owns).  A parameter that the port does not
/// implement is shown disabled, with the reason why.
///
/// The view is main-actor isolated: the bindings of the rows read and write
/// the state of the (main-actor) view model.
@MainActor
struct AdvancedParametersView: View {
    @ObservedObject var model: PreviewViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(
                        "The parameters of the simulation, grouped like the upstream panel. "
                            + "They are applied on top of the digested look of the stock and "
                            + "before the Adjustments sheet, which always wins for the "
                            + "controls it owns."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }

                ForEach(AdvancedSection.displayOrder, id: \.self) { section in
                    sectionView(section)
                }
            }
            .navigationTitle("Advanced parameters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Reset all") { model.resetAdvancedOverrides() }
                        .disabled(model.advancedOverrides.isEmpty)
                        .accessibilityIdentifier("advanced-reset-all")
                }
            }
            .onAppear { model.refreshAdvancedParameters() }
        }
        .presentationDetents([.large])
    }

    // MARK: - The sections

    @ViewBuilder
    private func sectionView(_ section: AdvancedSection) -> some View {
        let specs = AdvancedParams.specs(in: section)
        Section {
            ForEach(specs, id: \.path) { spec in
                row(for: spec)
            }
        } header: {
            HStack {
                Text(section.rawValue)
                Spacer()
                if model.hasAdvancedOverride(in: section) {
                    Button("Reset") { model.resetAdvancedSection(section) }
                        .font(.caption.weight(.medium))
                        .textCase(nil)
                }
            }
        } footer: {
            if let note = sectionNote(section) {
                Text(note)
            }
        }
    }

    /// The note of a section, when it needs one.
    private func sectionNote(_ section: AdvancedSection) -> String? {
        switch section {
        case .chemistry:
            return "The print density-curve morphing of the upstream is not ported: the "
                + "engine has no counterpart for this group."
        case .filmOutput:
            return "The film, the print medium and the direct scan path are chosen on the "
                + "main screen."
        case .ioPolicy:
            return "The input colour space and the decoding are set in the Input section "
                + "of the Adjustments sheet; the output of the app is encoded sRGB."
        case .viewer:
            return "These parameters belong to the viewer or to the workflow of the upstream "
                + "desktop application; they are not parameters of the simulation."
        case .camera:
            return "The auto exposure is not ported: the engine rejects it, so it stays off."
        case .enlarger:
            return "The neutral print filters of the digest stay the ones of the default "
                + "illuminant of the stock."
        default:
            return nil
        }
    }

    // MARK: - The rows

    @ViewBuilder
    private func row(for spec: AdvancedParamSpec) -> some View {
        switch spec.availability {
        case .applied:
            editableRow(for: spec)
        case .basicSheet:
            ownedRow(for: spec, owner: "the Adjustments sheet")
        case .look:
            ownedRow(for: spec, owner: "the film / print selection")
        case .inputPolicy:
            ownedRow(for: spec, owner: "the Input section")
        case let .locked(reason):
            unavailableRow(for: spec, reason: reason)
        case let .unported(reason):
            unavailableRow(for: spec, reason: reason)
        }
    }

    /// A row the panel can edit.
    @ViewBuilder
    private func editableRow(for spec: AdvancedParamSpec) -> some View {
        switch spec.kind {
        case .toggle:
            Toggle(isOn: toggleBinding(spec)) {
                label(for: spec)
            }
        case .slider:
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    label(for: spec)
                    Spacer()
                    Text(valueLabel(spec))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: doubleBinding(spec), in: spec.range, step: spec.step)
            }
        case .stepper:
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    label(for: spec)
                    Spacer()
                    Text(valueLabel(spec))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: intBinding(spec), in: spec.range, step: 1)
            }
        case .choice:
            Picker(selection: choiceBinding(spec)) {
                ForEach(spec.choices, id: \.self) { choice in
                    Text(choice).tag(choice)
                }
            } label: {
                label(for: spec)
            }
            .pickerStyle(.menu)
        case .vector:
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    label(for: spec)
                    Spacer()
                    if isOverridden(spec) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.caption)
                            .foregroundStyle(.tint)
                    }
                }
                ForEach(spec.components.indices, id: \.self) { index in
                    let component = spec.components[index]
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(component.title)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(componentLabel(spec, index: index))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(
                            value: componentBinding(spec, index: index),
                            in: component.range,
                            step: component.step
                        )
                    }
                }
            }
        }
        if let note = spec.note {
            Text(note)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    /// A row the panel shows but cannot edit.
    @ViewBuilder
    private func ownedRow(for spec: AdvancedParamSpec, owner: String) -> some View {
        HStack {
            label(for: spec)
            Spacer()
            Text(valueLabel(spec))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .disabled(true)
        Text("This value is owned by \(owner); it always wins over the advanced panel.")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    /// A row of a parameter the port does not implement.
    @ViewBuilder
    private func unavailableRow(for spec: AdvancedParamSpec, reason: String) -> some View {
        HStack {
            label(for: spec)
            Spacer()
            Text("Not available")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .disabled(true)
        Text(reason)
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    private func label(for spec: AdvancedParamSpec) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(spec.title)
            if isOverridden(spec) {
                Text(spec.path)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func isOverridden(_ spec: AdvancedParamSpec) -> Bool {
        model.advancedOverrides.contains(spec.path)
    }

    // MARK: - The values

    /// The effective value of a parameter: the digested value, the advanced
    /// override when there is one, and the basic adjustment for the controls
    /// the Adjustments sheet owns.
    private func effectiveValue(_ spec: AdvancedParamSpec) -> AdvancedValue? {
        guard let params = model.advancedParameters else { return nil }
        return AdvancedParams.value(of: spec.path, in: params)
    }

    private func valueLabel(_ spec: AdvancedParamSpec) -> String {
        guard let value = effectiveValue(spec) else { return "—" }
        switch value {
        case let .bool(flag):
            return flag ? "On" : "Off"
        case let .double(number):
            return String(format: "%.3f", number)
        case let .int(number):
            return String(number)
        case let .vector(values):
            return values.map { String(format: "%.2f", $0) }.joined(separator: " · ")
        case let .choice(name):
            return name
        }
    }

    private func componentLabel(_ spec: AdvancedParamSpec, index: Int) -> String {
        guard let values = effectiveValue(spec)?.vectorValue, index < values.count else {
            return "—"
        }
        return String(format: "%.3f", values[index])
    }

    // MARK: - The bindings

    private func toggleBinding(_ spec: AdvancedParamSpec) -> Binding<Bool> {
        Binding(
            get: { effectiveValue(spec)?.boolValue ?? false },
            set: { model.setAdvancedValue(.bool($0), for: spec.path) }
        )
    }

    private func doubleBinding(_ spec: AdvancedParamSpec) -> Binding<Double> {
        Binding(
            get: { effectiveValue(spec)?.doubleValue ?? spec.range.lowerBound },
            set: { model.setAdvancedValue(.double($0), for: spec.path) }
        )
    }

    private func intBinding(_ spec: AdvancedParamSpec) -> Binding<Double> {
        Binding(
            get: { Double(effectiveValue(spec)?.intValue ?? Int(spec.range.lowerBound)) },
            set: { model.setAdvancedValue(.int(Int($0.rounded())), for: spec.path) }
        )
    }

    private func choiceBinding(_ spec: AdvancedParamSpec) -> Binding<String> {
        Binding(
            get: { effectiveValue(spec)?.choiceValue ?? spec.choices.first ?? "" },
            set: { model.setAdvancedValue(.choice($0), for: spec.path) }
        )
    }

    private func componentBinding(_ spec: AdvancedParamSpec, index: Int) -> Binding<Double> {
        Binding(
            get: {
                guard let values = effectiveValue(spec)?.vectorValue, index < values.count else {
                    return 0
                }
                return values[index]
            },
            set: { newValue in
                guard var values = effectiveValue(spec)?.vectorValue, index < values.count else {
                    return
                }
                values[index] = newValue
                model.setAdvancedValue(.vector(values), for: spec.path)
            }
        )
    }
}
