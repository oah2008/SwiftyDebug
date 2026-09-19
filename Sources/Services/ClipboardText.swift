//
//  ClipboardText.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 19/09/2026.
//

import Foundation

/// The last thing every copied payload passes through. (See COPY.)
///
/// ## The bug this closes
///
/// A copied request body arrived with an invisible leading character, and
/// pasting it into Algolia's console failed. `trimmingCharacters(in:
/// .whitespacesAndNewlines)` was already being applied and did nothing, because
/// that character set does not contain the characters actually at fault:
/// `CharacterSet.whitespacesAndNewlines.contains("\u{FEFF}")` is **false**.
///
/// Measured, so the claim is the right one: Darwin's `String(data:encoding:)`
/// does strip a SINGLE leading UTF-8 BOM while decoding, so a plain BOM-prefixed
/// body is not the case that survives. What survives is everything else — a
/// double BOM, a space followed by a BOM (the old trim removed the space and
/// stopped), a zero-width space, and the bidi marks U+200E/U+200F/U+061C, which
/// decoding never touches and which this SDK's Arabic-facing users see
/// constantly. The other, and likeliest, source is the JSON viewer's WKWebView:
/// its copy button is a third-party web component whose output used to reach the
/// pasteboard verbatim.
///
/// Trimming is **both ends and outside only**. A body whose interior contains a
/// zero-width joiner or a newline inside a JSON string value must copy
/// byte-for-byte; only the affixes are noise.
enum ClipboardText {

    /// Invisible scalars that are legal in a payload, produce no glyph, and break
    /// a paste into a parser that is not expecting them.
    ///
    /// None of these are in `.whitespacesAndNewlines`, which is precisely why the
    /// previous trim could not remove them.
    static let invisibleAffixes = CharacterSet(charactersIn:
        "\u{FEFF}"      // zero width no-break space / BOM
        + "\u{200B}"    // zero width space
        + "\u{200C}"    // zero width non-joiner
        + "\u{200D}"    // zero width joiner
        + "\u{2060}"    // word joiner
        + "\u{00AD}"    // soft hyphen
        + "\u{180E}"    // mongolian vowel separator
        + "\u{200E}"    // left-to-right mark
        + "\u{200F}"    // right-to-left mark
        + "\u{061C}"    // arabic letter mark
        + "\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}"          // bidi embedding/override
        + "\u{2066}\u{2067}\u{2068}\u{2069}"                  // bidi isolates
    )

    /// Everything stripped from the ends of a copied payload: real whitespace,
    /// control characters (the `\u{8}\u{1e}` bodies this SDK already special-cases
    /// elsewhere), and the invisibles above.
    static let strippableAffixes = CharacterSet.whitespacesAndNewlines
        .union(.controlCharacters)
        .union(invisibleAffixes)

    /// `text` with every strippable scalar removed from both ends.
    ///
    /// Scalar-by-scalar rather than `trimmingCharacters(in:)` so the rule is the
    /// one written above rather than Foundation's, and so a multi-scalar grapheme
    /// (an emoji with a ZWJ inside it) is never cut in half — the loop only ever
    /// removes a *leading* or *trailing* scalar that is itself invisible.
    static func normalized(_ text: String) -> String {
        var scalars = Substring(text).unicodeScalars
        while let first = scalars.first, strippableAffixes.contains(first) {
            scalars = scalars.dropFirst()
        }
        while let last = scalars.last, strippableAffixes.contains(last) {
            scalars = scalars.dropLast()
        }
        return String(String.UnicodeScalarView(scalars))
    }

    /// True when `text` would come back different — i.e. it currently carries an
    /// affix that breaks a paste. Exists so a test can assert the defect itself
    /// rather than only the repaired value.
    static func hasStrippableAffix(_ text: String) -> Bool {
        normalized(text) != text
    }
}
