// Settings+Beautify.swift — Beautify preferences. The typed `beautifyDefaultStyle` accessor lives in the app target
// (UI/Screenshot/BeautifySettings.swift) because BeautifyStyle is defined there; this file holds the raw storage.
import Foundation

extension Settings {
    public static let beautifyKeys: Set<String> = ["beautifyDefaultStyle", "beautifyAutoApply"]

    /// JSON of the default BeautifyStyle (nil until the user changes it).
    public var beautifyDefaultStyleJSON: Data? {
        get { defaults.data(forKey: "beautifyDefaultStyle") }
        set { if let v = newValue { defaults.set(v, forKey: "beautifyDefaultStyle") } else { defaults.removeObject(forKey: "beautifyDefaultStyle") } }
    }
    /// "Apply Beautify to every screenshot" (default off).
    public var beautifyAutoApply: Bool {
        get { defaults.object(forKey: "beautifyAutoApply") == nil ? false : defaults.bool(forKey: "beautifyAutoApply") }
        set { defaults.set(newValue, forKey: "beautifyAutoApply") }
    }
}
