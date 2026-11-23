# Themes

Upstream ships 12 XML themes (`Debug/Themes/*.xml`, loader `src/Theme.cpp`). Colours are `RGB(r,g,b)`.
The port embeds them as Swift values (`Theme.swift`) with the same keys, plus "System" (follows light/dark).

Keys used by the port: CaptionLeft, CaptionRight, CaptionTextColor, ListBoxOddRowsBG, ListBoxEvenRowsBG,
ListBoxOddRowsText, ListBoxEvenRowsText, ListBoxSelectedBG, ListBoxSelectedText, ClipPastedColor, MainWindowBG,
SearchTextBoxFocusBG, SearchTextBoxFocusText, SearchTextHighlight, Border, GroupTreeBG, GroupTreeText,
DescriptionWindowBG, DescriptionWindowText.

| Theme | MainBG | OddBG | EvenBG | Text | SelBG | SelText | Highlight |
|---|---|---|---|---|---|---|---|
| Classic | #F0F0F0 | #FFFFFF | #F0F0F0 | #000000 | #1E74D3 | #FFFFFF | #FF0000 |
| DarkerDitto | #000000 | #181818 | #000000 | #999999 | #404040 | #EEEEEE | #FF0000 |
| MonoDark | #444444 | #333333 | #2C2C2C | #EEEEEE | #3E4E66 | #EEEEEE | #84F099 |
| Monolight | #BBBBBB | #EEEEEE | #DDDDDD | #222222 | #B9C8DD | #222222 | #039218 |
| Nord | #313742 | #313742 | #313742 | #7CA7AA | #3B4251 | #D6DDE8 | #FF0000 |
| Selenized Black | #181818 | #181818 | #252525 | #B9B9B9 | #3B3B3B | #DEDEDE | #FF5E56 |
| Selenized Dark | #103C48 | #103C48 | #174956 | #ADBCBC | #325B66 | #CAD8D9 | #FF665C |
| Selenized Light | #FBF3DB | #FBF3DB | #E9E4D0 | #53676D | #CFCEBE | #3A4D53 | #CC1729 |
| Selenized White | #FFFFFF | #FFFFFF | #EBEBEB | #474747 | #CDCDCD | #282828 | #BF0000 |
| Terminal | #141414 | #000000 | #000000 | #0C9B0C | #000000 | #2CF129 | #FF0000 |

(Full matrix incl. caption/description colours lives in `Sources/DittoMac/UI/Theme.swift`.)

# Languages
Upstream has 29 XML language files keyed by Win32 control IDs. Win32 IDs don't map to AppKit, so v1.0 ships
English UI strings via a `L10n` table; translations are a roadmap item (see `ROADMAP.md`).
