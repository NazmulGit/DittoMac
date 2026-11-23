# Rich formats and paste formats (1.1)

How DittoMac keeps a copy's full formatting (headings, styles, images) and converts clips into other formats.

## What is captured

`ClipboardMonitor` always reads the core set, as in 1.0, filtered by Preferences › Types (`enabledTypes`):

| Stored type | Source |
|---|---|
| `public.utf8-plain-text` | `NSPasteboard.string(forType: .string)` |
| `public.rtf` | RTF |
| `public.html` | HTML fragment as written by the source app |
| `public.png` | PNG, or TIFF converted to PNG (the only re-encoding) |
| `public.file-url` | newline-joined file URLs |

When `Settings.keepFullFormatting` is on (the default), it also stores this set, whatever `enabledTypes` says:

| Stored type | Read from | Typical source |
|---|---|---|
| `com.apple.webarchive` | `com.apple.webarchive`, or legacy `Apple Web Archive pasteboard type` (normalised) | Safari: page HTML plus embedded images and styles |
| `com.apple.flat-rtfd` | same | Notes, TextEdit, Pages, Mail: rich text with inline images |
| `public.rtfd` | same | some apps write the package UTI with flat RTFD data |
| `public.jpeg`, `com.compuserve.gif`, `public.heic` | same | photos, animated GIFs, iPhone images |
| `com.adobe.pdf` | same | Preview selections, PDF apps |
| `public.url`, `public.url-name` | same | "Copy Link" in browsers |

Rules:
- The bytes are stored exactly as the source wrote them. Nothing is re-encoded, except TIFF→PNG in the core set.
- **Per-format cap 64 MiB** (`ClipboardMonitor.maxRichFormatBytes`): only that format is skipped and the others are
  kept.
- **Total cap**: `maxClipSizeBytes` (Preferences › Advanced) still applies. If the clip is over it, full-formatting
  extras are dropped largest first. If it is still over, the clip is rejected, as in 1.0.
- A type that is also in `enabledTypes` is stored only once.
- Copy Rules: *replace text* drops every rich-text format (RTF, RTFD, HTML, web archive) because those no longer
  match the rewritten text. *Strip to plain text* keeps the plain text only.
- **Derived plain text**: when a clip has rich formats but no plain text, text is derived and stored as
  `public.utf8-plain-text`. Sources are RTFD-only copies and HTML-only web content. The text is used for the
  description and for full-text search. RTF/RTFD are parsed by AppKit. HTML and web archives go through DittoCore's
  `HTMLToMarkdown.plainText`, in pure Swift. Inputs over 16 MiB are not parsed.
- Friends sync still sends only its allow-listed core types. Rich extras stay on this Mac.

## Paste formats (`DittoCore.PasteFormat`)

| Format | Pasteboard content |
|---|---|
| `original` — "Original (keep all formatting)" | every stored format, byte for byte (`PasteContent.pasteboardItems`); the target app picks the richest it understands |
| `plainText` | plain text only (same as the Plain Text transform / ⇧Return) |
| `richText` — "Rich Text (no images)" | `public.rtf` + plain text. Source: stored RTF, else RTFD with its attachments removed, else sanitised HTML (`SafeRichText.html`) |
| `markdown` | plain text holding Markdown. Source: HTML (`public.html`, else the web archive's main HTML) via `HTMLToMarkdown`; else RTF/RTFD via `RTFToMarkdown`; else the plain text |
| `htmlSource` | plain text holding HTML markup: stored HTML, else the web archive's main HTML, else HTML generated locally from RTF/RTFD (`NSAttributedString` `.html` export), else escaped text |

- **Default paste** means Return, double-click, ⌘1–⌘0, the global last-ten hotkeys, global clip hotkeys and in-popup
  clip shortcuts. It uses `Settings.defaultPasteFormat` (default `original`). If the paste target matches
  `Settings.plainTextApps` (`;`-separated wildcards on bundle id or app name, matched with `CopyRuleEngine.wildcardMatch`),
  it uses plain text instead. ⇧Return is always plain text and ⌥⇧Return is always Markdown.
- **Multi-clip paste**: `original` and `plainText` work as in 1.0 (joined text, or files for file-only selections).
  `markdown` and `htmlSource` join each clip's converted text with the multi-paste separator, honouring reverse
  order. `richText` joins the attributed strings into one RTF. *Save multi-paste* stores what was written.
- Text transforms (Special Paste) still work on the plain text, as before.

## HTML → Markdown (`Sources/DittoCore/HTMLToMarkdown.swift`)

- A forgiving tokenizer builds a tree. Implied end tags are handled for `p`, `li`, `dt`/`dd`, `tr`/`td`/`th`,
  headings and `a`. Depth is capped at 200 (deeper content is flattened) and the node count at 200 000. Input is
  truncated to 2 MiB.
- Dropped with their content: `head`, `script`, `style`, `title`, `noscript`, `template`, `iframe`, `svg`, `math`,
  form controls and media.
- Output is GitHub-flavoured Markdown:
  - `h1`–`h6` → `#`…`######`; `strong`/`b` → `**`; `em`/`i` → `*`; `del`/`s` → `~~`.
  - `code` → backticks; `pre` → a fenced block (language taken from `language-*`, and the fence is longer than any
    backtick run inside).
  - Lists nest, with `ol start` numbering; `blockquote` → `>`; `hr` → `---`; tables → pipe tables (the first row is
    the header, ragged rows are padded, `|` is escaped).
  - `br` → hard break.
- Whitespace collapses as in a browser. Entities are decoded: named (common set), decimal and hex, with the
  Windows-1252 C1 mapping; invalid code points become U+FFFD. Markdown punctuation in text is backslash-escaped, so
  `&lt;script&gt;` can't turn into live inline HTML.
- Links: `[text](url)` only when `LinkPolicy.isSafeToOpen` allows the URL (http/https with a host, or mailto).
  Otherwise only the text is kept. Images: `![alt](src)` only for http/https sources; otherwise the alt text.
- The renderer runs on a private thread with a 16 MiB stack, so nesting depth never depends on the caller's
  thread. Swift-testing coverage includes malformed input, deep nesting, oversize input and seeded fuzzing.

## RTF/RTFD → Markdown (`Sources/DittoMac/Services/RichFormats.swift`, AppKit)

- Body size is the most common font size, weighted by characters. A paragraph of 300 characters or fewer is a
  heading when its largest font is ≥ 1.6× the body size (`#`), ≥ 1.3× (`##`) or ≥ 1.15× (`###`).
- Inline styles come from font traits: bold → `**`, italic → `*`, monospace → code. Strikethrough → `~~`. `.link` is
  kept only if `LinkPolicy` allows it.
- Lists come from `NSParagraphStyle.textLists`: nesting level is the number of lists. Decimal, alpha and roman
  markers become numbered items; the "\t•\t" marker text is removed.
- Attachments (inline images) are omitted from Markdown.

## Save Clip As… (⌘⇧S)

| Choice | File |
|---|---|
| Rich Text Document | `.rtfd` package when the stored RTFD has attachments; else `.rtf` (stored RTF, or converted from RTFD/HTML/text) |
| Web Archive | the stored `com.apple.webarchive` bytes (only offered when present) |
| HTML | stored / web-archive HTML, or HTML generated from RTF/RTFD |
| Markdown, Plain Text | as the paste formats |
| Image (PNG) | stored PNG, or another stored image converted (only if `ImageProbe.isSafeToDecode`) |

With several clips selected, one file is written per clip into a chosen folder. Names come from
`ImportExport.textFileName`, and existing files are never overwritten (" (n)" is added).

## Security notes

- **No WebKit for web archives.** A web archive is never handed to `NSAttributedString(.webArchive)` or a web view.
  Its main HTML is extracted with `PropertyListSerialization` (`DittoCore.WebArchive`, 64 MiB cap). From there it
  goes either to the allow-list `HTMLSanitizer` (previews, Rich Text) or to the pure-Swift converter (Markdown, plain
  text).
- **No remote fetching.** The sanitiser removes `img` and any markup that could load a resource before WebKit's HTML
  importer sees the input. The Markdown converter only emits remote image URLs as text and never loads them.
  Previews and conversions make no network requests.
- **Links**: only http(s) with a host, or mailto, survive in rendered text (`SafeRichText.removingUnsafeLinks`) and
  in Markdown.
- **RTFD previews** (`SafeRichText.rtfd`):
  - Only image attachments are kept.
  - An image whose header says it is too large to decode (`ImageProbe.maxDecodePixels`) is replaced by a
    downsampled thumbnail.
  - Any other attachment (files, bundles, scripts) is replaced by inert `[name]` text, so nothing in a preview can
    be opened.
- **Caps**:
  - 64 MiB per captured format; total clip cap honoured.
  - Parsing: 16 MiB RTF, 64 MiB RTFD, 2 MiB HTML (sanitiser and converter).
  - Text derivation for descriptions: 16 MiB.
- **Hostile input**: malformed HTML, unterminated tags, comments and entities, deep nesting and private-use
  sentinel characters are covered by tests (`HTMLToMarkdownTests`). Every tokenizer loop always advances.
- SQL is unchanged: formats are stored through `ClipStore` with bound parameters.
