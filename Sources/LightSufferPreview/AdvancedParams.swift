//
//  AdvancedParams.swift
//  light suffer胶片 — the advanced parameter panel
//
//  The catalog of the engine parameter surface, the overrides the panel
//  writes and the apply order of the overrides.
//
//  The catalog mirrors the upstream presentation manifest
//  (`spektrafilm_gui/param_manifest.py`): the dotted path of a parameter is
//  the key.  Every path of the manifest is listed exactly once, and every
//  path is either
//
//  * **applied** — the panel writes it into the Swift `PipelineParams`, or
//  * owned by another sheet of the app (the Adjustments sheet, the film /
//    print selection, the Input policy) or locked to the contract of the
//    display and of the export, or
//  * explicitly listed as **unported**, with the reason why the engine has
//    no counterpart for it.
//
//  Nothing here changes the engine: `FilmPhysics` is not modified, and the
//  numerics, the fixtures and the grain sampler of the port are untouched.
//

import FilmPhysics
import Foundation

// MARK: - The values

/// The value of one advanced parameter.
public enum AdvancedValue: Equatable, Sendable {
    /// A boolean parameter (a toggle).
    case bool(Bool)
    /// A floating point parameter (a slider).
    case double(Double)
    /// An integer parameter (a stepped slider).
    case int(Int)
    /// A vector of floating point parameters (the RGB channels, the two
    /// fields of the unsharp mask, the three fields of the Reinhard knee).
    case vector([Double])
    /// A string parameter with a fixed list of accepted values.
    case choice(String)

    public var boolValue: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }

    public var doubleValue: Double? {
        if case let .double(value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        if case let .int(value) = self { return value }
        return nil
    }

    public var vectorValue: [Double]? {
        if case let .vector(value) = self { return value }
        return nil
    }

    public var choiceValue: String? {
        if case let .choice(value) = self { return value }
        return nil
    }
}

/// The kind of the control of one parameter.
public enum AdvancedParamKind: String, Equatable, Sendable {
    /// A boolean toggle.
    case toggle
    /// A floating point slider.
    case slider
    /// An integer slider with a step of one.
    case stepper
    /// A picker over a fixed list of accepted values.
    case choice
    /// A group of floating point sliders (one per component).
    case vector
}

/// The availability of one parameter.
///
/// The availability is the *honest* description of what the panel does with
/// the parameter: an unported parameter is never offered as if it worked.
public enum AdvancedAvailability: Equatable, Sendable {
    /// The panel writes the value into the engine parameters.
    case applied
    /// The engine has the field, but the Adjustments sheet owns the
    /// effective value: the basic adjustments are applied **after** the
    /// advanced overrides, so the sheet always wins.
    case basicSheet
    /// The engine has the field, but the film / print selection of the main
    /// screen owns it.
    case look
    /// The engine has the field, but the Input section (the I/O policy of
    /// `PhotoInputSettings`) owns it.
    case inputPolicy
    /// The engine has the field, but the app keeps it locked to the contract
    /// of the display and of the export.
    case locked(reason: String)
    /// The upstream parameter has no counterpart in the port.
    case unported(reason: String)

    /// Whether the panel itself writes the value.
    public var isApplied: Bool { self == .applied }

    /// Whether the value is written by the panel *and* by the Adjustments
    /// sheet (the sheet wins).
    public var isBasicSheetOwned: Bool { self == .basicSheet }

    /// The reason a parameter is not applied, when there is one.
    public var reason: String? {
        switch self {
        case .applied, .basicSheet, .look, .inputPolicy:
            return nil
        case let .locked(reason), let .unported(reason):
            return reason
        }
    }
}

/// One component of a vector parameter.
public struct AdvancedVectorComponent: Sendable {
    /// The title of the component ("R", "G", "Sigma", "Threshold", …).
    public let title: String
    /// The range of the slider of the component.
    public let range: ClosedRange<Double>
    /// The step of the slider of the component.
    public let step: Double

    let read: @Sendable (PipelineParams) -> Double
    let write: @Sendable (inout PipelineParams, Double) -> Void

    public init(
        title: String,
        range: ClosedRange<Double>,
        step: Double,
        read: @escaping @Sendable (PipelineParams) -> Double,
        write: @escaping @Sendable (inout PipelineParams, Double) -> Void
    ) {
        self.title = title
        self.range = range
        self.step = step
        self.read = read
        self.write = write
    }
}

/// One parameter of the catalog.
///
/// The `path` is the dotted path of the upstream runtime schema (the key of
/// the upstream presentation manifest); the `enginePath` is the dotted path
/// of the same parameter on the Swift `PipelineParams`.
public struct AdvancedParamSpec: Sendable {
    /// The dotted path on the upstream runtime schema.
    public let path: String
    /// The dotted path on the Swift `PipelineParams`.
    public let enginePath: String
    /// The dotted paths on the Swift `PipelineParams` of the fields the
    /// parameter writes.  A parameter of the upstream manifest can cover
    /// more than one field of the engine (the unsharp mask of the scanner
    /// is a sigma and an amount).
    public let enginePaths: [String]
    /// The section of the panel the parameter belongs to.
    public let section: AdvancedSection
    /// The title of the control.
    public let title: String
    /// The kind of the control.
    public let kind: AdvancedParamKind
    /// The range of a scalar slider.
    public let range: ClosedRange<Double>
    /// The step of a scalar slider.
    public let step: Double
    /// The accepted values of a picker.
    public let choices: [String]
    /// The components of a vector control.
    public let components: [AdvancedVectorComponent]
    /// A short note shown under the control.
    public let note: String?
    /// Whether the parameter is applied, and who owns it otherwise.
    public let availability: AdvancedAvailability

    let read: (@Sendable (PipelineParams) -> AdvancedValue)?
    let write: (@Sendable (inout PipelineParams, AdvancedValue) -> Bool)?

    init(
        path: String,
        enginePath: String,
        enginePaths: [String]? = nil,
        section: AdvancedSection,
        title: String,
        kind: AdvancedParamKind,
        range: ClosedRange<Double> = 0...1,
        step: Double = 0.01,
        choices: [String] = [],
        components: [AdvancedVectorComponent] = [],
        note: String? = nil,
        availability: AdvancedAvailability,
        read: (@Sendable (PipelineParams) -> AdvancedValue)?,
        write: (@Sendable (inout PipelineParams, AdvancedValue) -> Bool)?
    ) {
        self.path = path
        self.enginePath = enginePath
        self.enginePaths = enginePaths ?? [enginePath]
        self.section = section
        self.title = title
        self.kind = kind
        self.range = range
        self.step = step
        self.choices = choices
        self.components = components
        self.note = note
        self.availability = availability
        self.read = read
        self.write = write
    }

    /// Whether the value is acceptable for this parameter.
    ///
    /// A value of an unported (or of an owned) parameter is never accepted,
    /// and a string is only accepted when the engine supports it.
    public func accepts(_ value: AdvancedValue) -> Bool {
        guard availability == .applied || availability == .basicSheet else { return false }
        switch (kind, value) {
        case (.toggle, .bool):
            return true
        case (.slider, .double):
            return true
        case (.stepper, .int):
            return true
        case (.choice, .choice(let name)):
            return choices.contains(name)
        case (.vector, .vector(let values)):
            return values.count == components.count
        default:
            return false
        }
    }
}

/// The sections of the advanced panel.
public enum AdvancedSection: String, CaseIterable, Equatable, Sendable {
    case couplers = "Couplers"
    case halation = "Halation"
    case grain = "Grain"
    case glare = "Glare"
    case preflash = "Preflash"
    case camera = "Camera"
    case cameraDiffusion = "Camera diffusion"
    case enlarger = "Enlarger"
    case enlargerDiffusion = "Enlarger diffusion"
    case scanner = "Scanner"
    case inputGamut = "Input gamut"
    case outputGamut = "Output gamut"
    case settings = "Settings"
    case filmRendering = "Film rendering"
    case filmOutput = "Film and print"
    case ioPolicy = "I/O policy"
    case chemistry = "Chemistry"
    case viewer = "Viewer and workflow"

    /// The order the sections are shown in.
    public static let displayOrder: [AdvancedSection] = [
        .couplers, .halation, .grain, .glare, .preflash, .camera,
        .cameraDiffusion, .enlarger, .enlargerDiffusion, .scanner,
        .inputGamut, .outputGamut, .settings, .filmRendering, .filmOutput,
        .ioPolicy, .chemistry, .viewer,
    ]
}

// MARK: - The overrides

/// The advanced overrides of one session.
///
/// The overrides are *absolute* values: they replace the digested value of
/// the field, they are not multipliers of it.  A missing path means that the
/// digested (or the stock specific) value of the field is kept.
public struct AdvancedOverrides: Equatable, Sendable {
    public private(set) var values: [String: AdvancedValue]

    public init() {
        self.values = [:]
    }

    public init(values: [String: AdvancedValue]) {
        self.values = values
    }

    /// Whether no override is set at all (the state of a fresh session).
    public var isEmpty: Bool { values.isEmpty }

    /// The number of overrides.
    public var count: Int { values.count }

    /// The paths of the overrides.
    public var paths: Set<String> { Set(values.keys) }

    public subscript(path: String) -> AdvancedValue? { values[path] }

    /// Whether an override is set for the path.
    public func contains(_ path: String) -> Bool { values[path] != nil }

    /// Whether an override of the given section is set.
    ///
    /// The test is **positive**: it is true when at least one path of the
    /// section carries an override.  (The inverse test — the paths that
    /// remain once the section is removed — would be true for the *other*
    /// sections.)
    public func contains(section: AdvancedSection) -> Bool {
        let paths = AdvancedParams.paths(in: section)
        return values.keys.contains { paths.contains($0) }
    }

    /// Sets an override.
    ///
    /// The value is refused when the path is unknown, when the parameter is
    /// not applied by the panel, or when the value does not match the kind
    /// (or the accepted values) of the parameter.
    ///
    /// - Returns: `true` when the override was written.
    @discardableResult
    public mutating func set(_ value: AdvancedValue, for path: String) -> Bool {
        guard let spec = AdvancedParams.spec(for: path) else { return false }
        guard spec.accepts(value) else { return false }
        values[path] = value
        return true
    }

    /// Removes the override of one path.
    public mutating func remove(_ path: String) {
        values.removeValue(forKey: path)
    }

    /// Removes every override: the next `pipelineParams` is the look, the
    /// basic adjustments and the input settings, with no advanced override.
    public mutating func removeAll() {
        values.removeAll()
    }

    /// A copy without the overrides of the given paths.
    public func removing(paths: Set<String>) -> AdvancedOverrides {
        var copy = self
        for path in paths { copy.values.removeValue(forKey: path) }
        return copy
    }

    /// A copy without the overrides of one section.
    public func removing(section: AdvancedSection) -> AdvancedOverrides {
        removing(paths: AdvancedParams.paths(in: section))
    }
}

// MARK: - The report of an apply

/// The result of the application of the overrides.
public struct AdvancedApplyReport: Equatable, Sendable {
    /// The paths that were written into the engine parameters.
    public let applied: [String]
    /// The paths that were refused, with the reason of the refusal.
    public let rejected: [String: String]

    public init(applied: [String] = [], rejected: [String: String] = [:]) {
        self.applied = applied
        self.rejected = rejected
    }
}

// MARK: - The catalog

/// The catalog of the engine parameter surface and the application of the
/// advanced overrides.
public enum AdvancedParams {

    // MARK: - The catalog

    /// Every parameter of the upstream manifest, in the display order.
    public static let catalog: [AdvancedParamSpec] = buildCatalog()

    private static let catalogIndex: [String: AdvancedParamSpec] = {
        var index: [String: AdvancedParamSpec] = [:]
        for spec in catalog { index[spec.path] = spec }
        return index
    }()

    /// The specification of one path, when it is known.
    public static func spec(for path: String) -> AdvancedParamSpec? {
        catalogIndex[path]
    }

    /// The paths of one section.
    public static func paths(in section: AdvancedSection) -> Set<String> {
        Set(catalog.filter { $0.section == section }.map(\.path))
    }

    /// The specifications of one section, in the display order.
    public static func specs(in section: AdvancedSection) -> [AdvancedParamSpec] {
        catalog.filter { $0.section == section }
    }

    /// The number of parameters of the catalog (the size of the upstream
    /// manifest: 107 declared parameters plus the eleven of the second
    /// diffusion group).
    public static var count: Int { catalog.count }

    /// The number of parameters the panel writes into the engine.
    public static var appliedCount: Int {
        catalog.filter { $0.availability == .applied }.count
    }

    /// The number of parameters owned by the Adjustments sheet.
    public static var basicSheetOwnedCount: Int {
        catalog.filter { $0.availability == .basicSheet }.count
    }

    /// The number of parameters owned by the look, by the Input policy or
    /// locked to the contract of the app.
    public static var externallyOwnedCount: Int {
        catalog.filter {
            switch $0.availability {
            case .look, .inputPolicy, .locked: return true
            case .applied, .basicSheet, .unported: return false
            }
        }.count
    }

    /// The number of parameters that are not ported.
    public static var unportedCount: Int {
        catalog.filter {
            if case .unported = $0.availability { return true }
            return false
        }.count
    }

    // MARK: - Reading and writing

    /// The value of one parameter of the given engine parameters.
    ///
    /// The value is the *effective* one: the override when it is set, the
    /// digested (and basic adjusted) value otherwise.
    public static func value(of path: String, in params: PipelineParams) -> AdvancedValue? {
        catalogIndex[path]?.read?(params)
    }

    /// The effective value of one parameter, with the override applied.
    ///
    /// The override wins when there is one, even for the controls the
    /// Adjustments sheet owns: the *engine* value of those is the value of
    /// the sheet, so the callers that display the effective value read it
    /// from the final parameters with ``value(of:in:)``.
    public static func effectiveValue(
        of path: String,
        in params: PipelineParams,
        overrides: AdvancedOverrides
    ) -> AdvancedValue? {
        if let override = overrides[path] { return override }
        return value(of: path, in: params)
    }

    // MARK: - Applying the overrides

    /// Writes the overrides into the engine parameters.
    ///
    /// The overrides are written **on top of** the digested parameters and
    /// **before** the basic adjustments of `PreviewAdjustments`, so that the
    /// Adjustments sheet always wins for the controls it owns.
    ///
    /// Only the parameters the panel applies are written; an unknown path, an
    /// unported parameter and an unsupported value are refused, never
    /// silently ignored.
    ///
    /// - Parameters:
    ///   - overrides: the overrides of the session.
    ///   - params: the engine parameters, modified in place.
    /// - Returns: the paths that were written and the paths that were refused.
    @discardableResult
    public static func apply(
        _ overrides: AdvancedOverrides,
        to params: inout PipelineParams
    ) -> AdvancedApplyReport {
        var applied: [String] = []
        var rejected: [String: String] = [:]

        for spec in catalog {
            guard let value = overrides[spec.path] else { continue }
            guard spec.availability == .applied || spec.availability == .basicSheet else {
                rejected[spec.path] = "the parameter is not applied by the advanced panel"
                continue
            }
            guard let write = spec.write else {
                rejected[spec.path] = "the parameter is not applied by the advanced panel"
                continue
            }
            if write(&params, value) {
                applied.append(spec.path)
            } else {
                rejected[spec.path] = "the value is not supported by the engine"
            }
        }

        return AdvancedApplyReport(applied: applied, rejected: rejected)
    }

    // MARK: - The builders of the catalog

    private static func toggle(
        _ path: String,
        _ enginePath: String,
        _ section: AdvancedSection,
        _ title: String,
        availability: AdvancedAvailability = .applied,
        note: String? = nil,
        get: @escaping @Sendable (PipelineParams) -> Bool,
        set: @escaping @Sendable (inout PipelineParams, Bool) -> Void
    ) -> AdvancedParamSpec {
        AdvancedParamSpec(
            path: path, enginePath: enginePath, section: section, title: title,
            kind: .toggle, note: note, availability: availability,
            read: { .bool(get($0)) },
            write: { params, value in
                guard case let .bool(flag) = value else { return false }
                set(&params, flag)
                return true
            }
        )
    }

    private static func slider(
        _ path: String,
        _ enginePath: String,
        _ section: AdvancedSection,
        _ title: String,
        range: ClosedRange<Double>,
        step: Double,
        availability: AdvancedAvailability = .applied,
        note: String? = nil,
        get: @escaping @Sendable (PipelineParams) -> Double,
        set: @escaping @Sendable (inout PipelineParams, Double) -> Void
    ) -> AdvancedParamSpec {
        AdvancedParamSpec(
            path: path, enginePath: enginePath, section: section, title: title,
            kind: .slider, range: range, step: step, note: note,
            availability: availability,
            read: { .double(get($0)) },
            write: { params, value in
                guard case let .double(number) = value else { return false }
                set(&params, number)
                return true
            }
        )
    }

    private static func stepper(
        _ path: String,
        _ enginePath: String,
        _ section: AdvancedSection,
        _ title: String,
        range: ClosedRange<Double>,
        availability: AdvancedAvailability = .applied,
        note: String? = nil,
        get: @escaping @Sendable (PipelineParams) -> Int,
        set: @escaping @Sendable (inout PipelineParams, Int) -> Void
    ) -> AdvancedParamSpec {
        AdvancedParamSpec(
            path: path, enginePath: enginePath, section: section, title: title,
            kind: .stepper, range: range, step: 1, note: note,
            availability: availability,
            read: { .int(get($0)) },
            write: { params, value in
                guard case let .int(number) = value else { return false }
                set(&params, number)
                return true
            }
        )
    }

    private static func choice(
        _ path: String,
        _ enginePath: String,
        _ section: AdvancedSection,
        _ title: String,
        choices: [String],
        availability: AdvancedAvailability = .applied,
        note: String? = nil,
        get: @escaping @Sendable (PipelineParams) -> String,
        set: @escaping @Sendable (inout PipelineParams, String) -> Void
    ) -> AdvancedParamSpec {
        AdvancedParamSpec(
            path: path, enginePath: enginePath, section: section, title: title,
            kind: .choice, choices: choices, note: note, availability: availability,
            read: { .choice(get($0)) },
            write: { params, value in
                guard case let .choice(name) = value, choices.contains(name) else {
                    return false
                }
                set(&params, name)
                return true
            }
        )
    }

    private static func vector(
        _ path: String,
        _ enginePath: String,
        _ section: AdvancedSection,
        _ title: String,
        components: [AdvancedVectorComponent],
        enginePaths: [String]? = nil,
        availability: AdvancedAvailability = .applied,
        note: String? = nil
    ) -> AdvancedParamSpec {
        AdvancedParamSpec(
            path: path, enginePath: enginePath, enginePaths: enginePaths,
            section: section, title: title,
            kind: .vector, components: components, note: note,
            availability: availability,
            read: { params in
                .vector(components.map { $0.read(params) })
            },
            write: { params, value in
                guard case let .vector(values) = value,
                      values.count == components.count else { return false }
                for (index, component) in components.enumerated() {
                    component.write(&params, values[index])
                }
                return true
            }
        )
    }

    private static func unported(
        _ path: String,
        _ enginePath: String,
        _ section: AdvancedSection,
        _ title: String,
        reason: String,
        note: String? = nil
    ) -> AdvancedParamSpec {
        AdvancedParamSpec(
            path: path, enginePath: enginePath, section: section, title: title,
            kind: .slider, note: note, availability: .unported(reason: reason),
            read: nil, write: nil
        )
    }

    /// A parameter of the manifest that the engine has, but that another
    /// sheet of the app owns.
    private static func owned(
        _ path: String,
        _ enginePath: String,
        _ section: AdvancedSection,
        _ title: String,
        availability: AdvancedAvailability,
        reason: String,
        note: String? = nil
    ) -> AdvancedParamSpec {
        AdvancedParamSpec(
            path: path, enginePath: enginePath, section: section, title: title,
            kind: .slider, note: note, availability: availability,
            read: nil, write: nil
        )
    }

    private static func component(
        _ title: String,
        range: ClosedRange<Double>,
        step: Double,
        get: @escaping @Sendable (PipelineParams) -> Double,
        set: @escaping @Sendable (inout PipelineParams, Double) -> Void
    ) -> AdvancedVectorComponent {
        AdvancedVectorComponent(
            title: title, range: range, step: step, read: get, write: set
        )
    }

    // MARK: - The catalog itself

    private static func buildCatalog() -> [AdvancedParamSpec] {
        var specs: [AdvancedParamSpec] = []

        // --- the DIR couplers -----------------------------------------
        specs.append(toggle(
            "film_render.dir_couplers.active", "filmRender.dirCouplers.active",
            .couplers, "Couplers active",
            note: "The chemical coupling between the emulsion layers.",
            get: { $0.filmRender.dirCouplers.active },
            set: { $0.filmRender.dirCouplers.active = $1 }
        ))
        specs.append(slider(
            "film_render.dir_couplers.amount", "filmRender.dirCouplers.amount",
            .couplers, "Amount", range: 0...3, step: 0.05,
            note: "The global multiplier of the DIR inhibition matrix.",
            get: { $0.filmRender.dirCouplers.amount },
            set: { $0.filmRender.dirCouplers.amount = $1 }
        ))
        specs.append(slider(
            "film_render.dir_couplers.inhibition_samelayer",
            "filmRender.dirCouplers.inhibitionSamelayer",
            .couplers, "Same-layer inhibition", range: 0...2, step: 0.05,
            get: { $0.filmRender.dirCouplers.inhibitionSamelayer },
            set: { $0.filmRender.dirCouplers.inhibitionSamelayer = $1 }
        ))
        specs.append(slider(
            "film_render.dir_couplers.inhibition_interlayer",
            "filmRender.dirCouplers.inhibitionInterlayer",
            .couplers, "Inter-layer inhibition", range: 0...2, step: 0.05,
            get: { $0.filmRender.dirCouplers.inhibitionInterlayer },
            set: { $0.filmRender.dirCouplers.inhibitionInterlayer = $1 }
        ))
        specs.append(vector(
            "film_render.dir_couplers.gamma_samelayer_rgb",
            "filmRender.dirCouplers.gammaSamelayerRGB",
            .couplers, "Same-layer gamma",
            components: [
                component("R", range: 0...1, step: 0.02,
                          get: { $0.filmRender.dirCouplers.gammaSamelayerRGB[0] },
                          set: { $0.filmRender.dirCouplers.gammaSamelayerRGB[0] = $1 }),
                component("G", range: 0...1, step: 0.02,
                          get: { $0.filmRender.dirCouplers.gammaSamelayerRGB[1] },
                          set: { $0.filmRender.dirCouplers.gammaSamelayerRGB[1] = $1 }),
                component("B", range: 0...1, step: 0.02,
                          get: { $0.filmRender.dirCouplers.gammaSamelayerRGB[2] },
                          set: { $0.filmRender.dirCouplers.gammaSamelayerRGB[2] = $1 }),
            ]
        ))
        specs.append(vector(
            "film_render.dir_couplers.gamma_interlayer_r_to_gb",
            "filmRender.dirCouplers.gammaInterlayerRToGB",
            .couplers, "R inhibition onto G and B",
            components: [
                component("G", range: 0...1, step: 0.02,
                          get: { $0.filmRender.dirCouplers.gammaInterlayerRToGB[0] },
                          set: { $0.filmRender.dirCouplers.gammaInterlayerRToGB[0] = $1 }),
                component("B", range: 0...1, step: 0.02,
                          get: { $0.filmRender.dirCouplers.gammaInterlayerRToGB[1] },
                          set: { $0.filmRender.dirCouplers.gammaInterlayerRToGB[1] = $1 }),
            ]
        ))
        specs.append(vector(
            "film_render.dir_couplers.gamma_interlayer_g_to_rb",
            "filmRender.dirCouplers.gammaInterlayerGToRB",
            .couplers, "G inhibition onto R and B",
            components: [
                component("R", range: 0...1, step: 0.02,
                          get: { $0.filmRender.dirCouplers.gammaInterlayerGToRB[0] },
                          set: { $0.filmRender.dirCouplers.gammaInterlayerGToRB[0] = $1 }),
                component("B", range: 0...1, step: 0.02,
                          get: { $0.filmRender.dirCouplers.gammaInterlayerGToRB[1] },
                          set: { $0.filmRender.dirCouplers.gammaInterlayerGToRB[1] = $1 }),
            ]
        ))
        specs.append(vector(
            "film_render.dir_couplers.gamma_interlayer_b_to_rg",
            "filmRender.dirCouplers.gammaInterlayerBToRG",
            .couplers, "B inhibition onto R and G",
            components: [
                component("R", range: 0...1, step: 0.02,
                          get: { $0.filmRender.dirCouplers.gammaInterlayerBToRG[0] },
                          set: { $0.filmRender.dirCouplers.gammaInterlayerBToRG[0] = $1 }),
                component("G", range: 0...1, step: 0.02,
                          get: { $0.filmRender.dirCouplers.gammaInterlayerBToRG[1] },
                          set: { $0.filmRender.dirCouplers.gammaInterlayerBToRG[1] = $1 }),
            ]
        ))
        specs.append(slider(
            "film_render.dir_couplers.diffusion_size_um",
            "filmRender.dirCouplers.diffusionSizeUM",
            .couplers, "Diffusion size (µm)", range: 0...60, step: 5,
            note: "The sigma of the diffusion of the inhibitors (5–20 µm).",
            get: { $0.filmRender.dirCouplers.diffusionSizeUM },
            set: { $0.filmRender.dirCouplers.diffusionSizeUM = $1 }
        ))

        // --- the halation and the scatter ------------------------------
        specs.append(toggle(
            "film_render.halation.active", "filmRender.halation.active",
            .halation, "Halation and scatter",
            availability: .basicSheet,
            note: "The Adjustments sheet owns this toggle.",
            get: { $0.filmRender.halation.active },
            set: { $0.filmRender.halation.active = $1 }
        ))
        specs.append(slider(
            "film_render.halation.scatter_amount", "filmRender.halation.scatterAmount",
            .halation, "Scatter amount", range: 0...3, step: 0.05,
            get: { $0.filmRender.halation.scatterAmount },
            set: { $0.filmRender.halation.scatterAmount = $1 }
        ))
        specs.append(slider(
            "film_render.halation.scatter_spatial_scale",
            "filmRender.halation.scatterSpatialScale",
            .halation, "Scatter size", range: 0...3, step: 0.1,
            get: { $0.filmRender.halation.scatterSpatialScale },
            set: { $0.filmRender.halation.scatterSpatialScale = $1 }
        ))
        specs.append(slider(
            "film_render.halation.halation_amount", "filmRender.halation.halationAmount",
            .halation, "Halation amount", range: 0...3, step: 0.05,
            availability: .basicSheet,
            note: "The Adjustments sheet owns this control; the sheet wins.",
            get: { $0.filmRender.halation.halationAmount },
            set: { $0.filmRender.halation.halationAmount = $1 }
        ))
        specs.append(slider(
            "film_render.halation.halation_spatial_scale",
            "filmRender.halation.halationSpatialScale",
            .halation, "Halation size", range: 0...3, step: 0.1,
            get: { $0.filmRender.halation.halationSpatialScale },
            set: { $0.filmRender.halation.halationSpatialScale = $1 }
        ))
        specs.append(slider(
            "film_render.halation.boost_ev", "filmRender.halation.boostEV",
            .halation, "Highlight boost (EV)", range: 0...6, step: 0.5,
            get: { $0.filmRender.halation.boostEV },
            set: { $0.filmRender.halation.boostEV = $1 }
        ))
        specs.append(slider(
            "film_render.halation.protect_ev", "filmRender.halation.protectEV",
            .halation, "Protected range (EV)", range: 0...12, step: 0.5,
            get: { $0.filmRender.halation.protectEV },
            set: { $0.filmRender.halation.protectEV = $1 }
        ))
        specs.append(slider(
            "film_render.halation.boost_range", "filmRender.halation.boostRange",
            .halation, "Boost range", range: 0...1, step: 0.05,
            get: { $0.filmRender.halation.boostRange },
            set: { $0.filmRender.halation.boostRange = $1 }
        ))
        specs.append(vector(
            "film_render.halation.scatter_core_um", "filmRender.halation.scatterCoreUM",
            .halation, "Scatter core (µm)",
            components: [
                component("R", range: 0...20, step: 0.5,
                          get: { $0.filmRender.halation.scatterCoreUM[0] },
                          set: { $0.filmRender.halation.scatterCoreUM[0] = $1 }),
                component("G", range: 0...20, step: 0.5,
                          get: { $0.filmRender.halation.scatterCoreUM[1] },
                          set: { $0.filmRender.halation.scatterCoreUM[1] = $1 }),
                component("B", range: 0...20, step: 0.5,
                          get: { $0.filmRender.halation.scatterCoreUM[2] },
                          set: { $0.filmRender.halation.scatterCoreUM[2] = $1 }),
            ]
        ))
        specs.append(vector(
            "film_render.halation.scatter_tail_um", "filmRender.halation.scatterTailUM",
            .halation, "Scatter tail (µm)",
            components: [
                component("R", range: 0...60, step: 1,
                          get: { $0.filmRender.halation.scatterTailUM[0] },
                          set: { $0.filmRender.halation.scatterTailUM[0] = $1 }),
                component("G", range: 0...60, step: 1,
                          get: { $0.filmRender.halation.scatterTailUM[1] },
                          set: { $0.filmRender.halation.scatterTailUM[1] = $1 }),
                component("B", range: 0...60, step: 1,
                          get: { $0.filmRender.halation.scatterTailUM[2] },
                          set: { $0.filmRender.halation.scatterTailUM[2] = $1 }),
            ]
        ))
        specs.append(vector(
            "film_render.halation.scatter_tail_weight", "filmRender.halation.scatterTailWeight",
            .halation, "Scatter tail weight",
            components: [
                component("R", range: 0...1, step: 0.01,
                          get: { $0.filmRender.halation.scatterTailWeight[0] },
                          set: { $0.filmRender.halation.scatterTailWeight[0] = $1 }),
                component("G", range: 0...1, step: 0.01,
                          get: { $0.filmRender.halation.scatterTailWeight[1] },
                          set: { $0.filmRender.halation.scatterTailWeight[1] = $1 }),
                component("B", range: 0...1, step: 0.01,
                          get: { $0.filmRender.halation.scatterTailWeight[2] },
                          set: { $0.filmRender.halation.scatterTailWeight[2] = $1 }),
            ]
        ))
        specs.append(vector(
            "film_render.halation.halation_strength", "filmRender.halation.halationStrength",
            .halation, "Halation strength",
            components: [
                component("R", range: 0...1, step: 0.005,
                          get: { $0.filmRender.halation.halationStrength[0] },
                          set: { $0.filmRender.halation.halationStrength[0] = $1 }),
                component("G", range: 0...1, step: 0.005,
                          get: { $0.filmRender.halation.halationStrength[1] },
                          set: { $0.filmRender.halation.halationStrength[1] = $1 }),
                component("B", range: 0...1, step: 0.005,
                          get: { $0.filmRender.halation.halationStrength[2] },
                          set: { $0.filmRender.halation.halationStrength[2] = $1 }),
            ]
        ))
        specs.append(vector(
            "film_render.halation.halation_first_sigma_um",
            "filmRender.halation.halationFirstSigmaUM",
            .halation, "First bounce width (µm)",
            components: [
                component("R", range: 0...150, step: 1,
                          get: { $0.filmRender.halation.halationFirstSigmaUM[0] },
                          set: { $0.filmRender.halation.halationFirstSigmaUM[0] = $1 }),
                component("G", range: 0...150, step: 1,
                          get: { $0.filmRender.halation.halationFirstSigmaUM[1] },
                          set: { $0.filmRender.halation.halationFirstSigmaUM[1] = $1 }),
                component("B", range: 0...150, step: 1,
                          get: { $0.filmRender.halation.halationFirstSigmaUM[2] },
                          set: { $0.filmRender.halation.halationFirstSigmaUM[2] = $1 }),
            ]
        ))
        specs.append(stepper(
            "film_render.halation.halation_n_bounces", "filmRender.halation.halationNBounces",
            .halation, "Halation bounces", range: 1...5,
            get: { $0.filmRender.halation.halationNBounces },
            set: { $0.filmRender.halation.halationNBounces = $1 }
        ))
        specs.append(slider(
            "film_render.halation.halation_bounce_decay",
            "filmRender.halation.halationBounceDecay",
            .halation, "Bounce decay", range: 0...1, step: 0.05,
            get: { $0.filmRender.halation.halationBounceDecay },
            set: { $0.filmRender.halation.halationBounceDecay = $1 }
        ))
        specs.append(toggle(
            "film_render.halation.halation_renormalize", "filmRender.halation.halationRenormalize",
            .halation, "Renormalize the halation",
            note: "Divides by the total amplitude, so that the mid grey is preserved.",
            get: { $0.filmRender.halation.halationRenormalize },
            set: { $0.filmRender.halation.halationRenormalize = $1 }
        ))

        // --- the grain of the negative ---------------------------------
        specs.append(toggle(
            "film_render.grain.active", "filmRender.grain.active",
            .grain, "Grain",
            availability: .basicSheet,
            note: "The Adjustments sheet owns this toggle.",
            get: { $0.filmRender.grain.active },
            set: { $0.filmRender.grain.active = $1 }
        ))
        specs.append(toggle(
            "film_render.grain.sublayers_active", "filmRender.grain.sublayersActive",
            .grain, "Per-sublayer grain",
            note: "The three layer model of the upstream; off uses the single layer model.",
            get: { $0.filmRender.grain.sublayersActive },
            set: { $0.filmRender.grain.sublayersActive = $1 }
        ))
        specs.append(slider(
            "film_render.grain.particle_area_um2", "filmRender.grain.particleAreaUM2",
            .grain, "Particle area (µm²)", range: 0...2, step: 0.2,
            note: "The area of the silver halide particles (≈ 0.1 at ISO 100, 0.4 at ISO 400).",
            get: { $0.filmRender.grain.particleAreaUM2 },
            set: { $0.filmRender.grain.particleAreaUM2 = $1 }
        ))
        specs.append(vector(
            "film_render.grain.particle_scale", "filmRender.grain.particleScale",
            .grain, "Particle scale",
            components: [
                component("R", range: 0...10, step: 0.05,
                          get: { $0.filmRender.grain.particleScale[0] },
                          set: { $0.filmRender.grain.particleScale[0] = $1 }),
                component("G", range: 0...10, step: 0.05,
                          get: { $0.filmRender.grain.particleScale[1] },
                          set: { $0.filmRender.grain.particleScale[1] = $1 }),
                component("B", range: 0...10, step: 0.05,
                          get: { $0.filmRender.grain.particleScale[2] },
                          set: { $0.filmRender.grain.particleScale[2] = $1 }),
            ],
            note: "The grain strength of the Adjustments sheet multiplies this value."
        ))
        specs.append(vector(
            "film_render.grain.particle_scale_layers", "filmRender.grain.particleScaleLayers",
            .grain, "Sublayer particle scale",
            components: [
                component("R", range: 0...10, step: 0.25,
                          get: { $0.filmRender.grain.particleScaleLayers[0] },
                          set: { $0.filmRender.grain.particleScaleLayers[0] = $1 }),
                component("G", range: 0...10, step: 0.25,
                          get: { $0.filmRender.grain.particleScaleLayers[1] },
                          set: { $0.filmRender.grain.particleScaleLayers[1] = $1 }),
                component("B", range: 0...10, step: 0.25,
                          get: { $0.filmRender.grain.particleScaleLayers[2] },
                          set: { $0.filmRender.grain.particleScaleLayers[2] = $1 }),
            ]
        ))
        specs.append(vector(
            "film_render.grain.density_min", "filmRender.grain.densityMin",
            .grain, "Minimum density",
            components: [
                component("R", range: 0...0.2, step: 0.005,
                          get: { $0.filmRender.grain.densityMin[0] },
                          set: { $0.filmRender.grain.densityMin[0] = $1 }),
                component("G", range: 0...0.2, step: 0.005,
                          get: { $0.filmRender.grain.densityMin[1] },
                          set: { $0.filmRender.grain.densityMin[1] = $1 }),
                component("B", range: 0...0.2, step: 0.005,
                          get: { $0.filmRender.grain.densityMin[2] },
                          set: { $0.filmRender.grain.densityMin[2] = $1 }),
            ]
        ))
        specs.append(vector(
            "film_render.grain.uniformity", "filmRender.grain.uniformity",
            .grain, "Uniformity",
            components: [
                component("R", range: 0...1, step: 0.005,
                          get: { $0.filmRender.grain.uniformity[0] },
                          set: { $0.filmRender.grain.uniformity[0] = $1 }),
                component("G", range: 0...1, step: 0.005,
                          get: { $0.filmRender.grain.uniformity[1] },
                          set: { $0.filmRender.grain.uniformity[1] = $1 }),
                component("B", range: 0...1, step: 0.005,
                          get: { $0.filmRender.grain.uniformity[2] },
                          set: { $0.filmRender.grain.uniformity[2] = $1 }),
            ]
        ))
        specs.append(slider(
            "film_render.grain.blur", "filmRender.grain.blur",
            .grain, "Grain blur (px)", range: 0...2, step: 0.05,
            get: { $0.filmRender.grain.blur },
            set: { $0.filmRender.grain.blur = $1 }
        ))
        specs.append(slider(
            "film_render.grain.blur_dye_clouds_um", "filmRender.grain.blurDyeCloudsUM",
            .grain, "Dye cloud blur (µm)", range: 0...5, step: 0.1,
            get: { $0.filmRender.grain.blurDyeCloudsUM },
            set: { $0.filmRender.grain.blurDyeCloudsUM = $1 }
        ))
        specs.append(vector(
            "film_render.grain.micro_structure", "filmRender.grain.microStructure",
            .grain, "Micro-structure",
            components: [
                component("Blur (µm)", range: 0...2, step: 0.1,
                          get: { $0.filmRender.grain.microStructure[0] },
                          set: { $0.filmRender.grain.microStructure[0] = $1 }),
                component("Clump (nm)", range: 0...100, step: 1,
                          get: { $0.filmRender.grain.microStructure[1] },
                          set: { $0.filmRender.grain.microStructure[1] = $1 }),
            ]
        ))

        // --- the glare of the print ------------------------------------
        specs.append(toggle(
            "print_render.glare.active", "printRender.glare.active",
            .glare, "Glare",
            get: { $0.printRender.glare.active },
            set: { $0.printRender.glare.active = $1 }
        ))
        specs.append(slider(
            "print_render.glare.percent", "printRender.glare.percent",
            .glare, "Glare amount", range: 0...1, step: 0.01,
            get: { $0.printRender.glare.percent },
            set: { $0.printRender.glare.percent = $1 }
        ))
        specs.append(slider(
            "print_render.glare.roughness", "printRender.glare.roughness",
            .glare, "Glare roughness", range: 0...1, step: 0.05,
            get: { $0.printRender.glare.roughness },
            set: { $0.printRender.glare.roughness = $1 }
        ))
        specs.append(slider(
            "print_render.glare.blur", "printRender.glare.blur",
            .glare, "Glare blur (px)", range: 0...5, step: 0.1,
            get: { $0.printRender.glare.blur },
            set: { $0.printRender.glare.blur = $1 }
        ))

        // --- the chemistry (not ported) ---------------------------------
        let chemistryReason = "The print density-curve morphing is not ported: the Swift " +
            "engine has no counterpart for this group."
        specs.append(unported(
            "print_render.density_curves_morph.active",
            "printRender.densityCurvesMorph.active",
            .chemistry, "Morphing active", reason: chemistryReason
        ))
        specs.append(unported(
            "print_render.density_curves_morph.gamma_factor",
            "printRender.densityCurvesMorph.gammaFactor",
            .chemistry, "Gamma factor", reason: chemistryReason
        ))
        specs.append(unported(
            "print_render.density_curves_morph.gamma_factor_fast",
            "printRender.densityCurvesMorph.gammaFactorFast",
            .chemistry, "Gamma factor fast", reason: chemistryReason
        ))
        specs.append(unported(
            "print_render.density_curves_morph.gamma_factor_slow",
            "printRender.densityCurvesMorph.gammaFactorSlow",
            .chemistry, "Gamma factor slow", reason: chemistryReason
        ))
        specs.append(unported(
            "print_render.density_curves_morph.gamma_factor_red",
            "printRender.densityCurvesMorph.gammaFactorRed",
            .chemistry, "Gamma factor red", reason: chemistryReason
        ))
        specs.append(unported(
            "print_render.density_curves_morph.gamma_factor_green",
            "printRender.densityCurvesMorph.gammaFactorGreen",
            .chemistry, "Gamma factor green", reason: chemistryReason
        ))
        specs.append(unported(
            "print_render.density_curves_morph.gamma_factor_blue",
            "printRender.densityCurvesMorph.gammaFactorBlue",
            .chemistry, "Gamma factor blue", reason: chemistryReason
        ))
        specs.append(unported(
            "print_render.density_curves_morph.developer_exhaustion",
            "printRender.densityCurvesMorph.developerExhaustion",
            .chemistry, "Developer exhaustion", reason: chemistryReason
        ))

        // --- the preflash of the enlarger -------------------------------
        specs.append(slider(
            "enlarger.preflash_exposure", "enlarger.preflashExposure",
            .preflash, "Preflash exposure (EV)", range: 0...4, step: 0.005,
            get: { $0.enlarger.preflashExposure },
            set: { $0.enlarger.preflashExposure = $1 }
        ))
        specs.append(slider(
            "enlarger.preflash_y_filter_shift", "enlarger.preflashYFilterShift",
            .preflash, "Preflash Y filter shift", range: -40...40, step: 1,
            get: { $0.enlarger.preflashYFilterShift },
            set: { $0.enlarger.preflashYFilterShift = $1 }
        ))
        specs.append(slider(
            "enlarger.preflash_m_filter_shift", "enlarger.preflashMFilterShift",
            .preflash, "Preflash M filter shift", range: -40...40, step: 1,
            get: { $0.enlarger.preflashMFilterShift },
            set: { $0.enlarger.preflashMFilterShift = $1 }
        ))

        // --- the camera -------------------------------------------------
        specs.append(slider(
            "camera.film_format_mm", "camera.filmFormatMM",
            .camera, "Film format (mm)", range: 8...120, step: 1,
            note: "The long edge of the negative; it sets the size of a pixel of the film.",
            get: { $0.camera.filmFormatMM },
            set: { $0.camera.filmFormatMM = $1 }
        ))
        specs.append(slider(
            "camera.lens_blur_um", "camera.lensBlurUM",
            .camera, "Lens blur (µm)", range: 0...30, step: 0.05,
            get: { $0.camera.lensBlurUM },
            set: { $0.camera.lensBlurUM = $1 }
        ))
        specs.append(slider(
            "camera.exposure_compensation_ev", "camera.exposureCompensationEV",
            .camera, "Exposure compensation (EV)", range: -100...100, step: 0.25,
            availability: .basicSheet,
            note: "The Adjustments sheet owns this control; the sheet wins.",
            get: { $0.camera.exposureCompensationEV },
            set: { $0.camera.exposureCompensationEV = $1 }
        ))
        specs.append(toggle(
            "camera.auto_exposure", "camera.autoExposure",
            .camera, "Auto exposure",
            availability: .basicSheet,
            note: "The Adjustments sheet owns this control; the sheet wins.",
            get: { $0.camera.autoExposure },
            set: { $0.camera.autoExposure = $1 }
        ))
        specs.append(choice(
            "camera.auto_exposure_method", "camera.autoExposureMethod",
            .camera, "Metering method",
            choices: AutoExposure.methods,
            availability: .basicSheet,
            note: "The Adjustments sheet owns this control; the sheet wins.",
            get: { $0.camera.autoExposureMethod },
            set: { $0.camera.autoExposureMethod = $1 }
        ))

        // --- the diffusion filters --------------------------------------
        specs.append(contentsOf: diffusionSpecs(
            prefix: "camera.diffusion_filter",
            enginePrefix: "camera.diffusionFilter",
            section: .cameraDiffusion,
            get: { $0.camera.diffusionFilter },
            set: { $0.camera.diffusionFilter = $1 }
        ))
        specs.append(contentsOf: diffusionSpecs(
            prefix: "enlarger.diffusion_filter",
            enginePrefix: "enlarger.diffusionFilter",
            section: .enlargerDiffusion,
            get: { $0.enlarger.diffusionFilter },
            set: { $0.enlarger.diffusionFilter = $1 }
        ))

        // --- the enlarger ------------------------------------------------
        specs.append(choice(
            "enlarger.illuminant", "enlarger.illuminant",
            .enlarger, "Enlarger illuminant",
            choices: Resources.illuminantLabels,
            note: "The neutral print filters of the digest stay the ones of the stock's " +
                "default illuminant.",
            get: { $0.enlarger.illuminant },
            set: { $0.enlarger.illuminant = $1 }
        ))
        specs.append(slider(
            "enlarger.print_exposure", "enlarger.printExposure",
            .enlarger, "Print exposure", range: 0...4, step: 0.02,
            get: { $0.enlarger.printExposure },
            set: { $0.enlarger.printExposure = $1 }
        ))
        specs.append(toggle(
            "enlarger.print_exposure_compensation",
            "enlarger.printExposureCompensation",
            .enlarger, "Print exposure compensation",
            note: "Compensates the print exposure for the exposure of the camera.",
            get: { $0.enlarger.printExposureCompensation },
            set: { $0.enlarger.printExposureCompensation = $1 }
        ))
        specs.append(slider(
            "enlarger.y_filter_shift", "enlarger.yFilterShift",
            .enlarger, "Y filter shift", range: -200...200, step: 1,
            get: { $0.enlarger.yFilterShift },
            set: { $0.enlarger.yFilterShift = $1 }
        ))
        specs.append(slider(
            "enlarger.m_filter_shift", "enlarger.mFilterShift",
            .enlarger, "M filter shift", range: -200...200, step: 1,
            get: { $0.enlarger.mFilterShift },
            set: { $0.enlarger.mFilterShift = $1 }
        ))

        // --- the scanner -------------------------------------------------
        specs.append(slider(
            "scanner.lens_blur", "scanner.lensBlur",
            .scanner, "Scanner lens blur (px)", range: 0...5, step: 0.05,
            get: { $0.scanner.lensBlur },
            set: { $0.scanner.lensBlur = $1 }
        ))
        specs.append(toggle(
            "scanner.white_correction", "scanner.whiteCorrection",
            .scanner, "White correction",
            get: { $0.scanner.whiteCorrection },
            set: { $0.scanner.whiteCorrection = $1 }
        ))
        specs.append(slider(
            "scanner.white_level", "scanner.whiteLevel",
            .scanner, "White level", range: 0...1, step: 0.005,
            get: { $0.scanner.whiteLevel },
            set: { $0.scanner.whiteLevel = $1 }
        ))
        specs.append(toggle(
            "scanner.black_correction", "scanner.blackCorrection",
            .scanner, "Black correction",
            get: { $0.scanner.blackCorrection },
            set: { $0.scanner.blackCorrection = $1 }
        ))
        specs.append(slider(
            "scanner.black_level", "scanner.blackLevel",
            .scanner, "Black level", range: 0...1, step: 0.005,
            get: { $0.scanner.blackLevel },
            set: { $0.scanner.blackLevel = $1 }
        ))
        specs.append(vector(
            "scanner.unsharp_mask", "scanner.unsharpMaskSigma / scanner.unsharpMaskAmount",
            .scanner, "Unsharp mask",
            components: [
                component("Sigma (px)", range: 0...5, step: 0.05,
                          get: { $0.scanner.unsharpMaskSigma },
                          set: { $0.scanner.unsharpMaskSigma = $1 }),
                component("Amount", range: 0...2, step: 0.05,
                          get: { $0.scanner.unsharpMaskAmount },
                          set: { $0.scanner.unsharpMaskAmount = $1 }),
            ],
            enginePaths: ["scanner.unsharpMaskSigma", "scanner.unsharpMaskAmount"],
            note: "The engine has two fields: the sigma of the mask and its amount."
        ))

        // --- the gamut compression ---------------------------------------
        specs.append(toggle(
            "io.input_gamut_compress.active", "io.inputGamutCompress.active",
            .inputGamut, "Input gamut compression",
            note: "Compresses the input chromaticities before the spectral upsampling.",
            get: { $0.io.inputGamutCompress.active },
            set: { $0.io.inputGamutCompress.active = $1 }
        ))
        specs.append(choice(
            "io.input_gamut_compress.algorithm", "io.inputGamutCompress.algorithm",
            .inputGamut, "Input compression algorithm",
            choices: ["xy"],
            note: "Only the 'xy' algorithm is ported; 'oklch' would pass the input " +
                "through unchanged.",
            get: { $0.io.inputGamutCompress.algorithm },
            set: { $0.io.inputGamutCompress.algorithm = $1 }
        ))
        specs.append(kneeVector(
            "io.input_gamut_compress.knee", "io.inputGamutCompress.knee",
            .inputGamut, "Input compression knee",
            enginePaths: [
                "io.inputGamutCompress.knee.threshold",
                "io.inputGamutCompress.knee.limit",
                "io.inputGamutCompress.knee.power",
            ],
            get: { $0.io.inputGamutCompress.knee },
            set: { $0.io.inputGamutCompress.knee = $1 }
        ))

        specs.append(choice(
            "io.output_gamut_compress.algorithm", "io.outputGamutCompress.algorithm",
            .outputGamut, "Output compression algorithm",
            choices: ["cam16ucs", "off"],
            note: "Any other name is rejected by the engine.",
            get: { $0.io.outputGamutCompress.algorithm },
            set: { $0.io.outputGamutCompress.algorithm = $1 }
        ))
        specs.append(kneeVector(
            "io.output_gamut_compress.knee", "io.outputGamutCompress.knee",
            .outputGamut, "Output compression knee",
            enginePaths: [
                "io.outputGamutCompress.knee.threshold",
                "io.outputGamutCompress.knee.limit",
                "io.outputGamutCompress.knee.power",
            ],
            get: { $0.io.outputGamutCompress.knee },
            set: { $0.io.outputGamutCompress.knee = $1 }
        ))

        // --- the settings of the pipeline --------------------------------
        specs.append(choice(
            "settings.rgb_to_raw_method", "settings.rgbToRawMethod",
            .settings, "Spectral upsampling",
            choices: ["hanatos2025"],
            note: "Only 'hanatos2025' is ported; the engine rejects 'mallett2019'.",
            get: { $0.settings.rgbToRawMethod },
            set: { $0.settings.rgbToRawMethod = $1 }
        ))
        specs.append(toggle(
            "settings.apply_hanatos2025_adaptation_window",
            "settings.applyHanatos2025AdaptationWindow",
            .settings, "hanatos2025 adaptation window",
            get: { $0.settings.applyHanatos2025AdaptationWindow },
            set: { $0.settings.applyHanatos2025AdaptationWindow = $1 }
        ))
        specs.append(toggle(
            "settings.apply_hanatos2025_adaptation_surface",
            "settings.applyHanatos2025AdaptationSurface",
            .settings, "hanatos2025 adaptation surface",
            get: { $0.settings.applyHanatos2025AdaptationSurface },
            set: { $0.settings.applyHanatos2025AdaptationSurface = $1 }
        ))
        specs.append(slider(
            "settings.spectral_gaussian_blur", "settings.spectralGaussianBlur",
            .settings, "Spectral blur (nm)", range: 0...50, step: 0.1,
            get: { $0.settings.spectralGaussianBlur },
            set: { $0.settings.spectralGaussianBlur = $1 }
        ))

        // --- the gamma of the density curves of the negative -------------
        specs.append(slider(
            "film_render.density_curve_gamma", "filmRender.densityCurveGamma",
            .filmRendering, "Film gamma factor", range: 0...2, step: 0.05,
            note: "Below 1 the negative loses contrast, above 1 it gains it.",
            get: { $0.filmRender.densityCurveGamma },
            set: { $0.filmRender.densityCurveGamma = $1 }
        ))

        // --- the film and the print (owned by the main screen) -----------
        specs.append(owned(
            "selection.film_stock", "film",
            .filmOutput, "Film stock",
            availability: .look,
            reason: "The film is chosen on the main screen.",
            note: "Choose the film on the film strip of the main screen."
        ))
        specs.append(owned(
            "selection.print_paper", "print",
            .filmOutput, "Print paper",
            availability: .look,
            reason: "The print medium is chosen on the main screen.",
            note: "Choose the print medium in the Adjustments sheet."
        ))
        specs.append(owned(
            "io.scan_film", "io.scanFilm",
            .filmOutput, "Scan the film directly",
            availability: .look,
            reason: "The direct scan path is chosen by the film / print selection.",
            note: "A slide film is always scanned directly."
        ))

        // --- the I/O policy (owned by the Input section) ------------------
        specs.append(owned(
            "io.input_color_space", "io.inputColorSpace",
            .ioPolicy, "Input colour space",
            availability: .inputPolicy,
            reason: "The Input section of the Adjustments sheet owns the input colour space.",
            note: "The input colour space is set in the Input section; an unsupported " +
                "name is converted or refused there."
        ))
        specs.append(owned(
            "io.input_cctf_decoding", "io.inputCCTFDecoding",
            .ioPolicy, "Apply the CCTF decoding",
            availability: .inputPolicy,
            reason: "The Input section of the Adjustments sheet owns the decoding policy.",
            note: "The app always feeds linear pixels to the engine."
        ))
        specs.append(owned(
            "io.output_color_space", "io.outputColorSpace",
            .ioPolicy, "Output colour space",
            availability: .locked(
                reason: "The engine always encodes the output with the sRGB transfer " +
                    "function; the display and the export of the app are sRGB."
            ),
            reason: "The output of the app is encoded sRGB.",
            note: "The output of the app is encoded sRGB."
        ))

        // --- the viewer and the workflow of the upstream GUI ---------------
        let viewerReason = "This parameter belongs to the viewer or to the workflow of the " +
            "upstream desktop GUI; it is not a parameter of the simulation."
        specs.append(unported(
            "io.upscale_factor", "io.upscaleFactor", .viewer, "Upscale factor",
            reason: viewerReason
        ))
        specs.append(unported(
            "io.crop", "io.crop", .viewer, "Crop", reason: viewerReason
        ))
        specs.append(unported(
            "io.crop_center", "io.cropCenter", .viewer, "Crop centre", reason: viewerReason
        ))
        specs.append(unported(
            "io.crop_size", "io.cropSize", .viewer, "Crop size", reason: viewerReason
        ))
        specs.append(unported(
            "film_channel_swap", "filmChannelSwap", .viewer, "Film channel swap",
            reason: viewerReason
        ))
        specs.append(unported(
            "print_channel_swap", "printChannelSwap", .viewer, "Print channel swap",
            reason: viewerReason
        ))
        specs.append(unported(
            "use_display_transform", "useDisplayTransform", .viewer, "Use the display transform",
            reason: viewerReason
        ))
        specs.append(unported(
            "gray_18_canvas", "gray18Canvas", .viewer, "Gray 18% canvas",
            reason: viewerReason
        ))
        specs.append(unported(
            "white_padding", "whitePadding", .viewer, "White padding", reason: viewerReason
        ))
        specs.append(unported(
            "settings.preview_max_size", "settings.previewMaxSize", .viewer,
            "Preview max size", reason: viewerReason
        ))
        specs.append(unported(
            "output_interpolation", "outputInterpolation", .viewer, "Output interpolation",
            reason: viewerReason
        ))
        specs.append(unported(
            "workflow.saving_color_space", "workflow.savingColorSpace", .viewer,
            "Saving colour space", reason: viewerReason
        ))
        specs.append(unported(
            "workflow.saving_cctf_encoding", "workflow.savingCCTFEncoding", .viewer,
            "Saving CCTF encoding", reason: viewerReason
        ))
        specs.append(unported(
            "workflow.auto_preview", "workflow.autoPreview", .viewer, "Auto preview",
            reason: viewerReason
        ))

        return specs
    }

    /// The eleven parameters of a diffusion filter group.
    ///
    /// The camera and the enlarger share the same point spread function, so
    /// the two groups have the same parameters at two places of the tree.
    private static func diffusionSpecs(
        prefix: String,
        enginePrefix: String,
        section: AdvancedSection,
        get: @escaping @Sendable (PipelineParams) -> DiffusionFilterParams,
        set: @escaping @Sendable (inout PipelineParams, DiffusionFilterParams) -> Void
    ) -> [AdvancedParamSpec] {
        [
            toggle(
                "\(prefix).active", "\(enginePrefix).active", section, "Diffusion filter",
                get: { get($0).active },
                set: { params, value in
                    var filter = get(params)
                    filter.active = value
                    set(&params, filter)
                }
            ),
            choice(
                "\(prefix).filter_family", "\(enginePrefix).filterFamily", section,
                "Filter family",
                choices: ["glimmerglass", "black_pro_mist", "pro_mist", "cinebloom"],
                get: { get($0).filterFamily },
                set: { params, value in
                    var filter = get(params)
                    filter.filterFamily = value
                    set(&params, filter)
                }
            ),
            slider(
                "\(prefix).strength", "\(enginePrefix).strength", section, "Strength (stops)",
                range: 0...2, step: 0.125,
                get: { get($0).strength },
                set: { params, value in
                    var filter = get(params)
                    filter.strength = value
                    set(&params, filter)
                }
            ),
            slider(
                "\(prefix).spatial_scale", "\(enginePrefix).spatialScale", section,
                "Spatial scale", range: 0...3, step: 0.1,
                get: { get($0).spatialScale },
                set: { params, value in
                    var filter = get(params)
                    filter.spatialScale = value
                    set(&params, filter)
                }
            ),
            slider(
                "\(prefix).halo_warmth", "\(enginePrefix).haloWarmth", section, "Halo warmth",
                range: -1.5...1.5, step: 0.05,
                get: { get($0).haloWarmth },
                set: { params, value in
                    var filter = get(params)
                    filter.haloWarmth = value
                    set(&params, filter)
                }
            ),
            slider(
                "\(prefix).core_intensity", "\(enginePrefix).coreIntensity", section,
                "Core intensity", range: 0...4, step: 0.05,
                get: { get($0).coreIntensity },
                set: { params, value in
                    var filter = get(params)
                    filter.coreIntensity = value
                    set(&params, filter)
                }
            ),
            slider(
                "\(prefix).core_size", "\(enginePrefix).coreSize", section, "Core size",
                range: 0.1...4, step: 0.05,
                get: { get($0).coreSize },
                set: { params, value in
                    var filter = get(params)
                    filter.coreSize = value
                    set(&params, filter)
                }
            ),
            slider(
                "\(prefix).halo_intensity", "\(enginePrefix).haloIntensity", section,
                "Halo intensity", range: 0...4, step: 0.05,
                get: { get($0).haloIntensity },
                set: { params, value in
                    var filter = get(params)
                    filter.haloIntensity = value
                    set(&params, filter)
                }
            ),
            slider(
                "\(prefix).halo_size", "\(enginePrefix).haloSize", section, "Halo size",
                range: 0.1...4, step: 0.05,
                get: { get($0).haloSize },
                set: { params, value in
                    var filter = get(params)
                    filter.haloSize = value
                    set(&params, filter)
                }
            ),
            slider(
                "\(prefix).bloom_intensity", "\(enginePrefix).bloomIntensity", section,
                "Bloom intensity", range: 0...4, step: 0.05,
                get: { get($0).bloomIntensity },
                set: { params, value in
                    var filter = get(params)
                    filter.bloomIntensity = value
                    set(&params, filter)
                }
            ),
            slider(
                "\(prefix).bloom_size", "\(enginePrefix).bloomSize", section, "Bloom size",
                range: 0.1...4, step: 0.05,
                get: { get($0).bloomSize },
                set: { params, value in
                    var filter = get(params)
                    filter.bloomSize = value
                    set(&params, filter)
                }
            ),
        ]
    }

    /// The three parameters of a Reinhard knee.
    private static func kneeVector(
        _ path: String,
        _ enginePath: String,
        _ section: AdvancedSection,
        _ title: String,
        enginePaths: [String],
        get: @escaping @Sendable (PipelineParams) -> ReinhardKnee,
        set: @escaping @Sendable (inout PipelineParams, ReinhardKnee) -> Void
    ) -> AdvancedParamSpec {
        vector(
            path, enginePath, section, title,
            components: [
                component("Threshold", range: 0...1, step: 0.05,
                          get: { get($0).threshold },
                          set: { params, value in
                              var knee = get(params)
                              knee.threshold = value
                              set(&params, knee)
                          }),
                component("Limit", range: 0...2, step: 0.05,
                          get: { get($0).limit },
                          set: { params, value in
                              var knee = get(params)
                              knee.limit = value
                              set(&params, knee)
                          }),
                component("Power", range: 0.5...12, step: 0.05,
                          get: { get($0).power },
                          set: { params, value in
                              var knee = get(params)
                              knee.power = value
                              set(&params, knee)
                          }),
            ],
            enginePaths: enginePaths,
            note: "The default knee (0, 1, 6) is a soft full-range roll-off."
        )
    }
}
