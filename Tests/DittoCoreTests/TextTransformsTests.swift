import Testing
import Foundation
@testable import DittoCore

struct SeqRNG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state }
}

@Suite struct TextTransformsTests {
    @Test func cases() {
        #expect(TextTransform.upperCase.apply("Hello") == "HELLO")
        #expect(TextTransform.lowerCase.apply("HeLLo") == "hello")
        #expect(TextTransform.capitalize.apply("hELLO wORLD foo") == "Hello World Foo")
        #expect(TextTransform.sentenceCase.apply("hello WORLD. this is. ok! yes? fine") == "Hello world. This is. Ok! Yes? Fine")
        #expect(TextTransform.invertCase.apply("Hello 1!") == "hELLO 1!")
        #expect(TextTransform.camelCase.apply("hello world  foo") == "HelloWorldFoo")
        #expect(TextTransform.plainText.apply("x Y") == "x Y")
    }

    @Test func trimAndAscii() {
        #expect(TextTransform.trimWhiteSpace.apply(" \t\r\n hi there \n") == "hi there")
        #expect(TextTransform.asciiOnly.apply("café ñ ok €") == "caf  ok ")
    }

    @Test func lineFeeds() {
        #expect(TextTransform.removeLineFeeds.apply("a\r\nb\rc\nd") == "a b c d")
        #expect(TextTransform.addOneLineFeed.apply("a") == "a\n")
        #expect(TextTransform.addTwoLineFeeds.apply("a") == "a\n\n")
    }

    @Test func currentTime() {
        var rng = SeqRNG(state: 1)
        let out = TextTransform.addCurrentTime.apply("x", now: Date(timeIntervalSince1970: 0), rng: &rng)
        #expect(out.hasPrefix("x\n"))
        #expect(out.count > 4)
    }

    @Test func typoglycemia() {
        var rng = SeqRNG(state: 42)
        let out = TextTransform.typoglycemia.apply("The quick, brownish fox.", slugSeparator: "-", now: Date(), rng: &rng)
        let words = out.split(separator: " ")
        #expect(words.count == 4)
        #expect(words[0] == "The")
        #expect(words[1].first == "q" && words[1].last == ",")
        #expect(words[1].dropLast().sorted() == "quick".sorted())
        #expect(words[2].first == "b" && words[2].last == "h" && words[2].sorted() == "brownish".sorted())
        #expect(words[3] == "fox.")
    }

    @Test func slugify() {
        #expect(TextTransform.slugify.apply("  Héllo, Wörld!! Foo__Bar  ") == "hello-world-foo-bar")
        var rng = SeqRNG(state: 1)
        #expect(TextTransform.slugify.apply("A b", slugSeparator: "_", now: Date(), rng: &rng) == "a_b")
    }

    @Test func titles() {
        #expect(TextTransform.upperCase.title == "UPPER CASE")
        #expect(TextTransform.addTwoLineFeeds.title == "Paste + Two Line Feeds")
        #expect(TextTransform.allCases.count == 15)
    }

    @Test func multiPaste() {
        #expect(MultiPaste.join(["a", "b", "c"], separator: "[LF]", reverse: false) == "a\nb\nc")
        #expect(MultiPaste.join(["a", "b", "c"], separator: "[TAB]", reverse: true) == "c\tb\ta")
        #expect(MultiPaste.join(["a", "b"], separator: "[CR][LF]", reverse: false) == "a\r\nb")
        #expect(MultiPaste.join([], separator: ",", reverse: true) == "")
    }

    @Test func rtf() {
        #expect(RTFTransform.removeLineFeeds("{\\rtf1 a\\par b\\par\nc\\pard d}") == "{\\rtf1 a b c\\pard d}")
    }
}
