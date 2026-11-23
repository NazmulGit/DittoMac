import Testing
import Foundation
@testable import DittoCore

@Suite struct CopyRulesTests {
    @Test func wildcard() {
        #expect(CopyRuleEngine.wildcardMatch("", "x"))
        #expect(CopyRuleEngine.wildcardMatch("*", "x"))
        #expect(CopyRuleEngine.wildcardMatch("com.apple.*", "COM.Apple.Safari"))
        #expect(CopyRuleEngine.wildcardMatch("a?c", "abc"))
        #expect(!CopyRuleEngine.wildcardMatch("a?c", "abbc"))
        #expect(CopyRuleEngine.wildcardMatch("foo;bar*", "barista"))
        #expect(!CopyRuleEngine.wildcardMatch("foo;bar", "baz"))
        #expect(CopyRuleEngine.wildcardMatch("*1password*", "com.agilebits.1Password7"))
    }

    @Test func ignoreByApp() {
        let r = CopyRule(name: "n", appPattern: "*password*;Keychain*", action: .ignore)
        let o = CopyRuleEngine.evaluate(rules: [r], text: "x", appBundleID: "com.x", appName: "Keychain Access")
        #expect(o.ignore)
        let o2 = CopyRuleEngine.evaluate(rules: [r], text: "x", appBundleID: "com.x", appName: "Notes")
        #expect(!o2.ignore)
    }

    @Test func disabledSkipped() {
        let r = CopyRule(enabled: false, action: .ignore)
        #expect(!CopyRuleEngine.evaluate(rules: [r], text: "x", appBundleID: "", appName: "").ignore)
    }

    @Test func regexIgnoreAndReplaceChain() {
        let rules = [
            CopyRule(textRegex: "(\\d+)-(\\d+)", action: .replaceRegex, replacement: "$2/$1"),
            CopyRule(textRegex: "^20/10$", action: .makeTopSticky),
            CopyRule(textRegex: "secret", action: .ignore),
        ]
        let o = CopyRuleEngine.evaluate(rules: rules, text: "10-20", appBundleID: "", appName: "")
        #expect(o.text == "20/10")
        #expect(o.makeTopSticky)
        #expect(!o.ignore)
        let o2 = CopyRuleEngine.evaluate(rules: rules, text: "My SECRET", appBundleID: "", appName: "")
        #expect(o2.ignore)
    }

    @Test func invalidRegexNoMatch() {
        let r = CopyRule(textRegex: "([", action: .ignore)
        #expect(!CopyRuleEngine.evaluate(rules: [r], text: "([", appBundleID: "", appName: "").ignore)
    }

    @Test func regexNeedsText() {
        let r = CopyRule(textRegex: "a", action: .ignore)
        #expect(!CopyRuleEngine.evaluate(rules: [r], text: nil, appBundleID: "", appName: "").ignore)
    }

    @Test func flagsAndGroup() {
        let rules = [CopyRule(action: .stripToPlainText), CopyRule(action: .neverAutoDelete),
                     CopyRule(action: .makeLastSticky), CopyRule(action: .moveToGroup, groupName: "Work")]
        let o = CopyRuleEngine.evaluate(rules: rules, text: "t", appBundleID: "", appName: "")
        #expect(o.stripToPlain && o.neverAutoDelete && o.makeLastSticky)
        #expect(o.groupName == "Work")
    }

    @Test func hugeInputBounded() {
        let big = String(repeating: "a", count: 300_000) + "ZZZ"
        let r = CopyRule(textRegex: "ZZZ", action: .ignore)
        #expect(!CopyRuleEngine.evaluate(rules: [r], text: big, appBundleID: "", appName: "").ignore)
    }

    @Test func codable() throws {
        let rules = [CopyRule(name: "a", appPattern: "x*", textRegex: "y", action: .replaceRegex, replacement: "z", groupName: "g")]
        let data = try JSONEncoder().encode(rules)
        #expect(try JSONDecoder().decode([CopyRule].self, from: data) == rules)
        #expect(CopyRuleEngine.defaultRules().isEmpty && CopyRule.defaultRules().isEmpty)
    }
}
