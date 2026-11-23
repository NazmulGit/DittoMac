import Foundation
import Testing
@testable import DittoCore

@Suite struct SearchQueryTests {
    let like = "Main.mText LIKE ? ESCAPE '\\'"

    @Test func termsAreAndedByDefault() {
        let w = SearchQuery("foo bar").sqlWhere()
        #expect(w.sql == "((" + like + ") AND (" + like + "))")
        #expect(w.binds == ["%foo%", "%bar%"])
    }

    @Test func orAndNotOperators() {
        let terms = SearchQuery.parseTerms("a OR b AND c NOT d !e")
        #expect(terms.map(\.text) == ["a", "b", "c", "d", "e"])
        #expect(terms.map(\.connector) == [.and, .or, .and, .and, .and])
        #expect(terms.map(\.negated) == [false, false, false, true, true])

        let w = SearchQuery("foo OR bar").sqlWhere()
        #expect(w.sql == "((" + like + ") OR (" + like + "))")
        let n = SearchQuery("!foo").sqlWhere()
        #expect(n.sql == "(NOT (" + like + "))")
        #expect(n.binds == ["%foo%"])
        // lowercase "or" is a normal term; dangling operators are ignored
        #expect(SearchQuery.parseTerms("this or that").map(\.text) == ["this", "or", "that"])
        #expect(SearchQuery.parseTerms("OR foo NOT").map(\.text) == ["foo"])
        #expect(SearchQuery.parseTerms("! foo").map(\.negated) == [false])
    }

    @Test func quotedPhrases() {
        let terms = SearchQuery.parseTerms("\"hello world\" x !\"not this\" \"OR\" \"unterminated phrase")
        #expect(terms.map(\.text) == ["hello world", "x", "not this", "OR", "unterminated phrase"])
        #expect(terms.map(\.negated) == [false, false, true, false, false])
        #expect(SearchQuery("\"hello world\"").sqlWhere().binds == ["%hello world%"])
    }

    @Test func escapingOfLikeMetacharacters() {
        #expect(SearchQuery("100%_a\\b").sqlWhere().binds == ["%100\\%\\_a\\\\b%"])
        #expect(SearchQuery("a*b").sqlWhere().binds == ["%a%b%"])
        // quotes are just data in binds; the SQL text never contains user input
        let w = SearchQuery("it's \"x'y\" ';DROP").sqlWhere()
        #expect(w.binds == ["%it's%", "%x'y%", "%';DROP%"])
        #expect(!w.sql.contains("DROP") && !w.sql.contains("it's"))
    }

    @Test func prefixesForceScope() {
        var q = SearchQuery("/q key")
        q.searchFullText = true
        let w = q.sqlWhere()
        #expect(w.sql == "((Main.QuickPasteText LIKE ? ESCAPE '\\'))")
        #expect(w.binds == ["%key%"])
        let f = SearchQuery("\\f body").sqlWhere()
        #expect(f.sql.contains(SearchQuery.fullTextColumn) && !f.sql.contains("Main.mText"))
        #expect(SearchQuery("\\f body").usesFullText)
        #expect(SearchQuery("\\Q key").sqlWhere().sql.contains("QuickPasteText"))
        #expect(!SearchQuery("/qkey").sqlWhere().sql.contains("QuickPasteText"))
    }

    @Test func multipleScopesOrTogether() {
        var q = SearchQuery("x")
        q.searchFullText = true
        q.searchQuickPaste = true
        let w = q.sqlWhere()
        #expect(w.sql == "((Main.mText LIKE ? ESCAPE '\\' OR " + SearchQuery.fullTextColumn
                + " LIKE ? ESCAPE '\\' OR Main.QuickPasteText LIKE ? ESCAPE '\\'))")
        #expect(w.binds == ["%x%", "%x%", "%x%"])
        var none = SearchQuery("x"); none.searchDescription = false
        #expect(none.sqlWhere().sql.contains("Main.mText"))
    }

    @Test func containsAndRegexModes() {
        let c = SearchQuery("foo OR *bar", mode: .contains).sqlWhere()
        #expect(c.sql == "((" + like + "))")
        #expect(c.binds == ["%foo OR *bar%"])
        let r = SearchQuery("^a.*b$", mode: .regex).sqlWhere()
        #expect(r.sql == "((Main.mText REGEXP ?))")
        #expect(r.binds == ["(?i)^a.*b$"])
        var rc = SearchQuery("^A", mode: .regex); rc.caseInsensitive = false
        #expect(rc.sqlWhere().binds == ["^A"])
    }

    @Test func caseSensitiveUsesEscapedGlob() {
        var q = SearchQuery("a*b?[c")
        q.caseInsensitive = false
        let w = q.sqlWhere()
        #expect(w.sql == "((Main.mText GLOB ?))")
        #expect(w.binds == ["*a*b[?][[]c*"])
    }

    @Test func emptyQueryMatchesAll() {
        #expect(SearchQuery("   ").sqlWhere().sql == "1")
        #expect(SearchQuery("/q ").sqlWhere().binds.isEmpty)
        #expect(SearchQuery("NOT OR").sqlWhere().sql == "1")
        #expect(SearchQuery("").isEmpty)
    }

    @Test func regexFunctionIsBounded() {
        let cache = RegexCache()
        #expect(cache.matches(pattern: "b+", value: "abbbc"))
        #expect(!cache.matches(pattern: "(", value: "("))
        let long = String(repeating: "a", count: RegexCache.maxInputUTF16) + "Z"
        #expect(!cache.matches(pattern: "Z", value: long))
        for i in 0..<100 { _ = cache.matches(pattern: "p\(i)", value: "x") }   // eviction path
    }
}
