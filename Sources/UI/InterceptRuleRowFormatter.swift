//
//  InterceptRuleRowFormatter.swift
//  SwiftyDebug
//
//  Created by Omar Hariri on 30/07/2026.
//

import UIKit

/// The single place that decides how an intercept rule is described in a LIST.
///
/// Three screens render rule rows — the standalone rule list, the App tab's
/// INTERCEPT RULES section, and the export / import screens — and each used to
/// build its own one-line summary by counting header and query-parameter
/// overrides. A rule that ONLY mocked, ONLY held a breakpoint, ONLY rewrote a
/// response or ONLY redirected counted zero of each and rendered as
/// **"Empty rule"**, so three rules doing three different things were three
/// identical rows. That is the reported "mock, breakpoint and rewrite do not
/// have names that make it easier to know which is which".
///
/// Everything here is PURE — it reads the rule it is handed and nothing else:
/// no store, no disk, no singletons, no dates, no locale-dependent formatting.
/// Same rule in, same strings out, so it is safe to call from `cellForRowAt`
/// (house rule: no disk reads in `cellForRowAt`) and can be tested exhaustively.
enum InterceptRuleRowFormatter {

    // MARK: - Title

    /// The line a row leads with.
    ///
    /// The user's own `name` when they typed one, otherwise `armedSummary` —
    /// what the rule actually does on the wire.
    ///
    /// Deliberately NOT `rule.derivedName`. `derivedName` appends the scope
    /// ("Mock 404 · /cart"), and every row in this SDK prints `scopeText`
    /// immediately underneath, so using it would print the endpoint twice in
    /// two adjacent lines. Named rules and unnamed rules therefore differ only
    /// in the first line, never in what the row tells you about scope.
    static func title(for rule: InterceptRule) -> String {
        let typed = rule.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty ? rule.armedSummary : typed
    }

    // MARK: - Scope

    /// Where the rule applies, worded so two rules that differ ONLY in host can
    /// never render the same string.
    ///
    ///     "/product/{id} on api.example.com"
    ///     "/product/{id} on any host"
    ///     "Every request to api.example.com, cdn.example.com"
    ///     "Every request, on every host"
    ///
    /// An endpoint rule with no host pin is the behaviour every rule written
    /// before host pinning existed has, and it is a real, deliberate choice —
    /// so it says "on any host" out loud rather than saying nothing and letting
    /// it read as "host unknown".
    static func scopeText(for rule: InterceptRule) -> String {
        switch rule.matchMode {
        case .global:
            return "Every request, on every host"

        case .host:
            let hosts = InterceptRule.canonicalHosts(rule.matchHosts)
            // A `.host` rule with no hosts matches nothing. Say so: a rule that
            // silently does nothing is exactly what this file exists to stop.
            guard !hosts.isEmpty else { return "No hosts set — matches nothing" }
            return "Every request to " + hosts.joined(separator: ", ")

        case .exact, .normalized:
            let path = rule.matchEndpoint.isEmpty ? "(no path)" : rule.matchEndpoint
            let pin = InterceptRule.canonicalHost(rule.matchHost)
            return pin.isEmpty ? path + " on any host" : path + " on " + pin
        }
    }

    // MARK: - Detail line

    /// The secondary line: the scope, plus anything that stops the rule taking
    /// effect. Never empty.
    ///
    /// - Parameter includeEnabledState: pass `true` on screens with no
    ///   enable/disable control of their own (the transfer/import lists), where
    ///   "disabled" would otherwise be invisible. The rule list and the App tab
    ///   both show a switch, so they pass `false` and do not repeat themselves.
    static func detailText(for rule: InterceptRule, includeEnabledState: Bool = false) -> String {
        var parts = [scopeText(for: rule)]
        if isInert(rule) { parts.append(inertNote) }
        if includeEnabledState && !rule.isEnabled { parts.append("Disabled") }
        return parts.joined(separator: "  ·  ")
    }

    /// Plain wording for a rule that genuinely has nothing armed. Reserved for
    /// exactly that case — never shown for a rule that mocks, blocks, redirects,
    /// breakpoints or rewrites.
    static let inertNote = "Nothing armed — this rule changes nothing"

    /// True when the rule would not touch a single request.
    ///
    /// Asks the MODEL what "nothing armed" looks like instead of re-deriving it:
    /// a freshly-built rule arms nothing by definition, so whatever `armedSummary`
    /// calls that state is the string to compare against. Re-implementing the
    /// "is anything armed?" test here is how a UI ends up labelling a live rule
    /// "does nothing" after someone adds a fifth kind of change to the model.
    static func isInert(_ rule: InterceptRule) -> Bool {
        return rule.armedSummary == emptyArmedSummary
    }

    private static let emptyArmedSummary = InterceptRule(matchEndpoint: "").armedSummary

    // MARK: - Mode badge

    static func badge(for mode: EndpointMatchMode) -> String {
        switch mode {
        case .exact:      return "EXACT"
        case .normalized: return "PATTERN"
        case .host:       return "HOST"
        case .global:     return "GLOBAL"
        }
    }

    static func color(for mode: EndpointMatchMode) -> UIColor {
        switch mode {
        case .exact:      return .systemOrange
        case .normalized: return DebugTheme.accentColor
        case .host:       return .systemPurple
        case .global:     return .systemPink
        }
    }

    /// Colour for the row's leading line: red for a rule that blocks, dimmed for
    /// one that arms nothing, plain white otherwise.
    static func titleColor(for rule: InterceptRule) -> UIColor {
        if rule.isBlocked { return .systemRed }
        return isInert(rule) ? UIColor(white: 0.55, alpha: 1) : .white
    }

    /// "EXACT  Mock 404" — the mode badge tinted, then the rule's name.
    /// Used by the App tab and by both transfer screens so a rule looks the same
    /// wherever it is listed.
    static func attributedTitle(for rule: InterceptRule) -> NSAttributedString {
        let out = NSMutableAttributedString(
            string: badge(for: rule.matchMode) + "  ",
            attributes: [
                .font: UIFont.systemFont(ofSize: 9, weight: .bold),
                .foregroundColor: color(for: rule.matchMode),
            ]
        )
        out.append(NSAttributedString(
            string: title(for: rule),
            attributes: [
                .font: UIFont.systemFont(ofSize: 14, weight: .semibold),
                .foregroundColor: titleColor(for: rule),
            ]
        ))
        return out
    }

    /// Paths and hosts read better monospaced, and the detail line is nothing but
    /// paths and hosts.
    static var detailFont: UIFont {
        UIFont(name: "Menlo", size: 11) ?? .monospacedSystemFont(ofSize: 11, weight: .regular)
    }
}
