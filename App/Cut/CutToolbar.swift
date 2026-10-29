import SwiftUI
import SyllaBeatCore

/// Werkzeugleiste des Schnitts: Stil (Preset und Regler), Neu würfeln, Varianten.
struct CutToolbar: View {
    var project: Project
    var cut: CutController
    @State private var showsSliders = false

    private var style: CutStyle { project.style }

    var body: some View {
        HStack(spacing: 6) {
            Menu {
                Picker("Stil", selection: Binding(get: { style.preset }, set: { cut.setStyle(style.applying($0)) })) {
                    ForEach(CutStyle.Preset.allCases, id: \.rawValue) { preset in Text(preset.title).tag(preset) }
                }
                .pickerStyle(.inline)
                Divider()
                Picker(
                    "Refrains",
                    selection: Binding(
                        get: { style.refrainMode },
                        set: { mode in cut.setStyle(changed { $0.refrainMode = mode }) })
                ) {
                    ForEach(CutStyle.RefrainMode.allCases, id: \.rawValue) { mode in Text(mode.title).tag(mode) }
                }
                Toggle(
                    "Schnitte auf Wortanfänge",
                    isOn: Binding(
                        get: { style.alignToWords }, set: { value in cut.setStyle(changed { $0.alignToWords = value }) }
                    ))
                Toggle(
                    "Refrain schneller",
                    isOn: Binding(
                        get: { style.chorusFaster }, set: { value in cut.setStyle(changed { $0.chorusFaster = value }) }
                    ))
            } label: {
                Text("Stil: \(style.preset.title)")
            }
            .fixedSize()
            .help("Schnitttempo und Verhalten in Refrains; fixierte Einstellungen bleiben stehen")
            .accessibilityIdentifier("cut.style")

            Button("Regler", systemImage: "slider.horizontal.3") { showsSliders.toggle() }
                .help("Schnittdichte, Variation, Mindestdauer und Energie fein einstellen")
                .popover(isPresented: $showsSliders, arrowEdge: .bottom) {
                    StyleSliders(style: style) { cut.setStyle($0) }
                }
                .accessibilityIdentifier("cut.sliders")

            Button(project.cut == nil ? "Schneiden" : "Neu würfeln", systemImage: "dice") {
                if project.cut == nil { cut.generate() } else { cut.reroll() }
            }
            .labelStyle(.titleAndIcon)
            .disabled(!cut.canCut)
            .help(project.cut == nil ? "Ersten Schnitt erstellen" : "Neuer Zufall, fixierte Einstellungen bleiben (⌘R)")
            .accessibilityIdentifier("cut.reroll")

            Menu {
                Button("Drei Varianten erzeugen") { cut.createVariants() }
                if !project.variants.isEmpty {
                    Divider()
                    ForEach(project.variants) { variant in
                        Toggle(
                            variant.name,
                            isOn: Binding(
                                get: { project.cut?.id == variant.id }, set: { _ in cut.selectVariant(variant.id) }))
                    }
                }
            } label: {
                Label("Varianten", systemImage: "square.stack.3d.up")
            }
            .fixedSize()
            .disabled(!cut.canCut)
            .help("Drei Schnitte mit verschiedenem Zufall nebeneinander; per Klick wählen")
            .accessibilityIdentifier("cut.variants")
        }
    }

    private func changed(_ change: (inout CutStyle) -> Void) -> CutStyle {
        var copy = style
        change(&copy)
        return copy
    }
}

/// Feinabstimmung des Stils. Werte werden beim Loslassen übernommen (ein Undo-Schritt je Änderung).
private struct StyleSliders: View {
    var style: CutStyle
    var apply: (CutStyle) -> Void
    @State private var draft: CutStyle

    init(style: CutStyle, apply: @escaping (CutStyle) -> Void) {
        self.style = style
        self.apply = apply
        _draft = State(initialValue: style)
    }

    var body: some View {
        Form {
            Stepper("Strophe: \(draft.verseBeats) Beats je Einstellung", value: $draft.verseBeats, in: 1...16)
                .onChange(of: draft.verseBeats) { commit() }
            Stepper("Refrain: \(draft.chorusBeats) Beats je Einstellung", value: $draft.chorusBeats, in: 1...16)
                .onChange(of: draft.chorusBeats) { commit() }
            Picker("Variation", selection: $draft.variation) {
                Text("Gering").tag(CutStyle.Variation.low)
                Text("Mittel").tag(CutStyle.Variation.medium)
                Text("Hoch").tag(CutStyle.Variation.high)
            }
            .onChange(of: draft.variation) { commit() }
            LabeledContent("Mindestdauer") {
                HStack {
                    Slider(value: $draft.minimumDuration, in: 0.2...3, step: 0.1) { editing in if !editing { commit() }
                    }
                    Text("\(draft.minimumDuration.formatted(.number.precision(.fractionLength(1)))) s")
                        .monospacedDigit().frame(width: 44, alignment: .trailing)
                }
            }
            LabeledContent("Energie folgen") {
                Slider(value: $draft.followEnergy, in: 0...1) { editing in if !editing { commit() } }
            }
            .help("Wie stark laute Stellen schneller geschnitten werden")
        }
        .formStyle(.grouped)
        .frame(width: 360)
        .onChange(of: style) { _, new in draft = new }
    }

    private func commit() {
        guard draft != style else { return }
        apply(draft)
    }
}
