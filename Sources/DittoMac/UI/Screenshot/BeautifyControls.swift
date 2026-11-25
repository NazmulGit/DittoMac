// BeautifyControls.swift — SwiftUI controls for a BeautifyStyle: preset grid with rendered thumbnails, sliders,
// background/frame/aspect/outline pickers. Used in the capture popover and in Preferences.
// (`@State` is unavailable with Command Line Tools only, so local state uses the project's `@LState`.)
import SwiftUI
import AppKit
import DittoCore

// MARK: - colour ↔ hex

extension Color {
    /// `#RRGGBB` (or `#RRGGBBAA`) → SwiftUI colour in sRGB.
    init(beautifyHex hex: String, fallback: Color = .gray) {
        if let c = HexColor(hex) { self = Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: c.a) } else { self = fallback }
    }
    /// SwiftUI colour → `#RRGGBB` (`#RRGGBBAA` when translucent), converted through sRGB.
    var beautifyHex: String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? NSColor.gray.usingColorSpace(.sRGB)!
        return HexColor(r: Double(ns.redComponent), g: Double(ns.greenComponent), b: Double(ns.blueComponent), a: Double(ns.alphaComponent)).hex
    }
}

// MARK: - thumbnails

@MainActor
enum BeautifyThumbnails {
    private static var cache: [String: NSImage] = [:]
    private static let sample: CGImage? = BeautifySample.make(pointSize: CGSize(width: 220, height: 140), scale: 1)

    static func image(for style: BeautifyStyle) -> NSImage? {
        let key = (try? JSONEncoder().encode(style)).map { String(decoding: $0, as: UTF8.self) } ?? style.name
        if let c = cache[key] { return c }
        guard let sample else { return nil }
        // Scale padding/shadow down so the 220 pt sample looks like the real thing at thumbnail size.
        let out = BeautifyRenderer.render(sample, pixelScale: 1, style: style)
        let img = NSImage(cgImage: out, size: NSSize(width: out.width, height: out.height))
        if cache.count > 300 { cache.removeAll() }
        cache[key] = img
        return img
    }

    /// Live preview of a style on the sample screenshot.
    static func preview(for style: BeautifyStyle) -> NSImage? {
        guard let s = BeautifySample.make(pointSize: CGSize(width: 320, height: 200), scale: 1) else { return nil }
        let out = BeautifyRenderer.render(s, pixelScale: 1, style: style)
        return NSImage(cgImage: out, size: NSSize(width: out.width, height: out.height))
    }
}

// MARK: - controls

/// Preset picker + sliders for a BeautifyStyle (embedded in the capture popover and in Preferences).
struct BeautifyControls: View {
    @Binding var style: BeautifyStyle

    private enum Kind: String, CaseIterable, Identifiable {
        case gradient = "Gradient", solid = "Solid", transparent = "Transparent"
        var id: String { rawValue }
    }

    private var kind: Kind {
        switch style.background { case .gradient: return .gradient; case .solid: return .solid; case .transparent: return .transparent }
    }

    /// Binding that marks the style as "Custom" when the user edits a value by hand.
    private func edit<T>(_ kp: WritableKeyPath<BeautifyStyle, T>) -> Binding<T> {
        Binding(get: { style[keyPath: kp] }, set: { v in style[keyPath: kp] = v; style.name = "Custom" })
    }

    private var gradientParts: (start: String, end: String, angle: Double) {
        if case .gradient(let a, let b, let angle) = style.background { return (a, b, angle) }
        return ("#7F7FD5", "#86A8E7", 135)
    }
    private var solidHex: String {
        if case .solid(let h) = style.background { return h }
        return gradientParts.start
    }

    private func setKind(_ k: Kind) {
        switch k {
        case .gradient: let g = gradientParts; style.background = .gradient(start: g.start, end: g.end, angle: g.angle)
        case .solid: style.background = .solid(solidHex)
        case .transparent: style.background = .transparent
        }
        style.name = "Custom"
    }

    private func colorBinding(get: @escaping () -> String, set: @escaping (String) -> Void) -> Binding<Color> {
        Binding(get: { Color(beautifyHex: get()) }, set: { set($0.beautifyHex); style.name = "Custom" })
    }

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, unit: String = "pt", format: String = "%.0f") -> some View {
        HStack {
            Text(title).frame(width: 96, alignment: .leading)
            Slider(value: value, in: range)
            Text(String(format: format, value.wrappedValue) + (unit.isEmpty ? "" : " \(unit)"))
                .monospacedDigit().foregroundColor(.secondary).frame(width: 52, alignment: .trailing)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("Beautify this screenshot", isOn: $style.enabled)

            Text("Presets").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96, maximum: 140), spacing: 10)], spacing: 10) {
                ForEach(BeautifyPresets.all, id: \.name) { p in
                    Button {
                        var s = p; s.enabled = true; style = s
                    } label: {
                        VStack(spacing: 3) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.12))
                                if let img = BeautifyThumbnails.image(for: p) {
                                    Image(nsImage: img).resizable().scaledToFit().padding(2)
                                }
                            }
                            .frame(height: 64)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(style.name == p.name ? Color.accentColor : Color.clear, lineWidth: 2))
                            Text(p.name).font(.caption2).lineLimit(2).multilineTextAlignment(.center).frame(minHeight: 26, alignment: .top)
                                .foregroundColor(style.name == p.name ? .accentColor : .primary)
                        }
                    }
                    .buttonStyle(.plain)
                    .help(p.name)
                    .accessibilityLabel(Text("Preset \(p.name)"))
                }
            }

            Divider()
            Text("Background").font(.headline)
            Picker("", selection: Binding(get: { kind }, set: { setKind($0) })) {
                ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            switch kind {
            case .gradient:
                HStack(spacing: 16) {
                    ColorPicker("Start", selection: colorBinding(get: { gradientParts.start },
                                                                 set: { style.background = .gradient(start: $0, end: gradientParts.end, angle: gradientParts.angle) }))
                    ColorPicker("End", selection: colorBinding(get: { gradientParts.end },
                                                               set: { style.background = .gradient(start: gradientParts.start, end: $0, angle: gradientParts.angle) }))
                }
                slider("Angle", Binding(get: { gradientParts.angle },
                                        set: { style.background = .gradient(start: gradientParts.start, end: gradientParts.end, angle: $0); style.name = "Custom" }),
                       0...360, unit: "°")
            case .solid:
                ColorPicker("Colour", selection: colorBinding(get: { solidHex }, set: { style.background = .solid($0) }))
            case .transparent:
                Text("The background stays transparent (PNG keeps the transparency).")
                    .font(.caption).foregroundColor(.secondary)
            }

            Divider()
            Text("Shape & shadow").font(.headline)
            slider("Padding", edit(\.padding), 0...160)
            slider("Corner radius", edit(\.cornerRadius), 0...40)
            slider("Shadow blur", edit(\.shadowRadius), 0...80)
            slider("Shadow opacity", Binding(get: { style.shadowOpacity * 100 }, set: { style.shadowOpacity = $0 / 100; style.name = "Custom" }), 0...100, unit: "%")
            slider("Shadow offset", edit(\.shadowOffsetY), 0...40)

            Divider()
            Text("Frame & canvas").font(.headline)
            HStack {
                Picker("Window frame", selection: edit(\.windowFrame)) {
                    ForEach(BeautifyStyle.WindowFrame.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Aspect", selection: edit(\.aspect)) {
                    ForEach(BeautifyStyle.Aspect.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
            HStack {
                Text("Outline").frame(width: 96, alignment: .leading)
                Slider(value: edit(\.outlineWidth), in: 0...12)
                Text(String(format: "%.1f pt", style.outlineWidth)).monospacedDigit().foregroundColor(.secondary).frame(width: 52, alignment: .trailing)
                ColorPicker("", selection: colorBinding(get: { style.outlineColor }, set: { style.outlineColor = $0 }), supportsOpacity: true)
                    .labelsHidden().disabled(style.outlineWidth == 0)
            }
        }
    }
}

// MARK: - Preferences section

/// Preferences section: default style + "auto-apply to every screenshot".
struct BeautifyDefaultsView: View {
    @LState private var style: BeautifyStyle = DittoCore.Settings.shared.beautifyDefaultStyle
    @LState private var autoApply: Bool = DittoCore.Settings.shared.beautifyAutoApply

    private func save() {
        DittoCore.Settings.shared.beautifyDefaultStyle = style
        NotificationCenter.default.post(name: .dittoSettingsChanged, object: nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Apply Beautify to every screenshot", isOn: Binding(
                get: { autoApply },
                set: { autoApply = $0; DittoCore.Settings.shared.beautifyAutoApply = $0
                    NotificationCenter.default.post(name: .dittoSettingsChanged, object: nil) }))
            Text("When on, new screenshots get the default look below. You can still switch it off for one capture.")
                .font(.caption).foregroundColor(.secondary)

            HStack(alignment: .top, spacing: 16) {
                ScrollView { BeautifyControls(style: $style).padding(.trailing, 8) }
                    .frame(minWidth: 320, maxHeight: 360)
                VStack(spacing: 8) {
                    Text("Preview").font(.headline)
                    ZStack {
                        RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.15))
                        if let img = BeautifyThumbnails.preview(for: style) {
                            Image(nsImage: img).resizable().scaledToFit().padding(6)
                        }
                    }
                    .frame(width: 240, height: 190)
                    Button("Reset") {
                        style = BeautifyPresets.defaultStyle
                        autoApply = false
                        DittoCore.Settings.shared.beautifyAutoApply = false
                        save()
                    }
                }
            }
        }
        .onChange(of: style) { _ in save() }
    }
}
