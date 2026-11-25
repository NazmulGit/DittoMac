import Testing
import Foundation
@testable import DittoCore

@Suite struct ShareLinksTests {
    let link = URL(string: "https://i.example.com/a/b.png?x=1&y=2#frag")!

    @Test func exactURLs() {
        let l = "https%3A%2F%2Fi.example.com%2Fa%2Fb.png%3Fx%3D1%26y%3D2%23frag"
        #expect(ShareLinks.url(for: .x, link: link)?.absoluteString == "https://x.com/intent/post?url=\(l)")
        #expect(ShareLinks.url(for: .facebook, link: link)?.absoluteString == "https://www.facebook.com/sharer/sharer.php?u=\(l)")
        #expect(ShareLinks.url(for: .pinterest, link: link)?.absoluteString == "https://www.pinterest.com/pin/create/button/?url=\(l)&media=\(l)")
        #expect(ShareLinks.url(for: .vk, link: link)?.absoluteString == "https://vk.com/share.php?url=\(l)")
        #expect(ShareLinks.url(for: .reddit, link: link)?.absoluteString == "https://www.reddit.com/submit?url=\(l)")
        #expect(ShareLinks.url(for: .linkedin, link: link)?.absoluteString == "https://www.linkedin.com/sharing/share-offsite/?url=\(l)")
        #expect(ShareLinks.url(for: .telegram, link: link)?.absoluteString == "https://t.me/share/url?url=\(l)")
        #expect(ShareLinks.url(for: .whatsapp, link: link)?.absoluteString == "https://wa.me/?text=\(l)")
        #expect(ShareLinks.similarImageSearch(link: link)?.absoluteString == "https://lens.google.com/uploadbyurl?url=\(l)")
    }

    @Test func titleEncodingOfTrickyCharacters() {
        let u = ShareLinks.url(for: .x, link: URL(string: "https://i.example.com/p.png")!, title: "a&b=c #1 100% é 日本 +plus")!
        #expect(u.absoluteString == "https://x.com/intent/post?url=https%3A%2F%2Fi.example.com%2Fp.png&text=a%26b%3Dc%20%231%20100%25%20%C3%A9%20%E6%97%A5%E6%9C%AC%20%2Bplus")
        // Round trip: the query items decode back to the originals and nothing leaked into extra parameters.
        let items = URLComponents(url: u, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(items.map(\.name) == ["url", "text"])
        #expect(items[1].value == "a&b=c #1 100% é 日本 +plus")
    }

    @Test func emailUsesEncodedSubjectAndBody() {
        let u = ShareLinks.url(for: .email, link: URL(string: "https://i.example.com/p.png")!, title: "Bug & fix #2")!
        #expect(u.scheme == "mailto")
        #expect(u.absoluteString == "mailto:?subject=Bug%20%26%20fix%20%232&body=Bug%20%26%20fix%20%232%0Ahttps%3A%2F%2Fi.example.com%2Fp.png")
        let noTitle = ShareLinks.url(for: .email, link: URL(string: "https://i.example.com/p.png")!)!
        #expect(noTitle.absoluteString == "mailto:?subject=Screenshot&body=https%3A%2F%2Fi.example.com%2Fp.png")
    }

    @Test func whatsappJoinsTitleAndLink() {
        let u = ShareLinks.url(for: .whatsapp, link: URL(string: "https://i.example.com/p.png")!, title: "Look")!
        #expect(u.absoluteString == "https://wa.me/?text=Look%20https%3A%2F%2Fi.example.com%2Fp.png")
    }

    @Test func rejectsUnsafeLinks() {
        let bad = ["http://i.example.com/p.png", "file:///etc/passwd", "javascript:alert(1)", "data:text/html,hi", "ftp://x.example/p",
                   "https://user:pw@i.example.com/p.png", "https:///nohost", "mailto:a@b.c"]
        for s in bad {
            guard let u = URL(string: s) else { continue }
            for n in ShareNetwork.allCases { #expect(ShareLinks.url(for: n, link: u) == nil, "\(s) \(n)") }
            #expect(ShareLinks.similarImageSearch(link: u) == nil, "\(s)")
        }
        let long = URL(string: "https://i.example.com/" + String(repeating: "a", count: 2100))!
        #expect(ShareLinks.url(for: .x, link: long) == nil)
    }

    @Test func titlesAreUnique() {
        #expect(Set(ShareNetwork.allCases.map(\.title)).count == ShareNetwork.allCases.count)
    }
}
