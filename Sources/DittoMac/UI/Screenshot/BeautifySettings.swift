// BeautifySettings.swift — typed accessor for the default Beautify style (BeautifyStyle lives in the app target,
// the raw JSON storage and `beautifyAutoApply` live in DittoCore/Settings+Beautify.swift).
import Foundation
import DittoCore

extension DittoCore.Settings {
    /// The default look, stored as JSON in `beautifyDefaultStyle`. Falls back to the first preset when nothing valid is stored.
    var beautifyDefaultStyle: BeautifyStyle {
        get {
            guard let data = beautifyDefaultStyleJSON, data.count < 4096,
                  let style = try? JSONDecoder().decode(BeautifyStyle.self, from: data) else { return BeautifyPresets.defaultStyle }
            return style
        }
        set { beautifyDefaultStyleJSON = try? JSONEncoder().encode(newValue) }
    }
}
