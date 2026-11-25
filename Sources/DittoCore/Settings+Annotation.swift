import Foundation

/// Remembered annotation tool state for the screenshot editor.
extension Settings {
    /// Raw `AnnotationTool` name ("pen", "arrow", …); nil until the user picks one.
    public var screenshotLastTool: String? {
        get { defaults.string(forKey: "screenshotLastTool") }
        set { if let newValue { defaults.set(newValue, forKey: "screenshotLastTool") } else { defaults.removeObject(forKey: "screenshotLastTool") } }
    }
    /// `#RRGGBB` / `#RRGGBBAA`; invalid stored values fall back to red.
    public var screenshotLastColor: String {
        get {
            let s = defaults.string(forKey: "screenshotLastColor") ?? "#FF3B30"
            return AnnotationMath.parseHex(s) == nil ? "#FF3B30" : s
        }
        set { if AnnotationMath.parseHex(newValue) != nil { defaults.set(newValue, forKey: "screenshotLastColor") } }
    }
    public var screenshotLastLineWidth: Double {
        get {
            let v = defaults.object(forKey: "screenshotLastLineWidth") == nil ? 3 : defaults.double(forKey: "screenshotLastLineWidth")
            return Double(AnnotationMath.clampLineWidth(CGFloat(v)))
        }
        set { defaults.set(Double(AnnotationMath.clampLineWidth(CGFloat(newValue))), forKey: "screenshotLastLineWidth") }
    }
    public var screenshotLastFontSize: Double {
        get {
            let v = defaults.object(forKey: "screenshotLastFontSize") == nil ? 18 : defaults.double(forKey: "screenshotLastFontSize")
            return Double(AnnotationMath.clampFontSize(CGFloat(v)))
        }
        set { defaults.set(Double(AnnotationMath.clampFontSize(CGFloat(newValue))), forKey: "screenshotLastFontSize") }
    }
}
