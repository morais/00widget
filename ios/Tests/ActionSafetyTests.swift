import Foundation
import Testing
@testable import ZeroZeroWidgetApp

/// `ActionDefinition.isSafeFromWidget` is the enforcement point for the rule
/// that destructive actions never run from a widget.
/// `RunDashboardActionIntent` consults it before every call and silently
/// no-ops when it says no.
///
/// A regression here is a security regression rather than a cosmetic one: a
/// widget tap runs in the extension, authenticates with the shared-Keychain
/// credential, and has no foreground context in which to confirm anything. The
/// rule is written down in AGENTS.md and was, until this suite, enforced only
/// by reading.
@Suite("Widget action safety gate")
struct ActionSafetyTests {

    @Test("Only a normal action needing no confirmation runs from a widget")
    func gateAdmitsOnlyNormalUnconfirmed() {
        #expect(action(.normal, confirm: false).isSafeFromWidget)
        #expect(!action(.normal, confirm: true).isSafeFromWidget)
        #expect(!action(.destructive, confirm: false).isSafeFromWidget)
        #expect(!action(.destructive, confirm: true).isSafeFromWidget)
    }

    /// The interesting half of the decoder. A role this build predates decodes
    /// as `.destructive`, which is what separates "a producer adds a role and
    /// every widget quietly runs it" from "a producer adds a role and widgets
    /// decline it until the app catches up".
    @Test("An unrecognised role decodes as destructive, so it cannot run from a widget")
    func unknownRoleFailsClosed() throws {
        let decoded = try decode(#"{"id":"a","label":"Run","role":"nuclear"}"#)
        #expect(decoded.role == .destructive)
        #expect(!decoded.isSafeFromWidget)
    }

    /// The producer-facing contract: omitting both fields is the ordinary,
    /// safe case, so a minimal action published by an agent is runnable.
    @Test("An absent role decodes as normal and an absent confirm as false")
    func absentFieldsTakeTheSafeOrdinaryDefaults() throws {
        let decoded = try decode(#"{"id":"a","label":"Run"}"#)
        #expect(decoded.role == .normal)
        #expect(decoded.confirm == false)
        #expect(decoded.isSafeFromWidget)
    }

    @Test("confirm alone withholds an otherwise runnable action")
    func confirmAloneWithholds() throws {
        let decoded = try decode(#"{"id":"a","label":"Run","role":"normal","confirm":true}"#)
        #expect(decoded.role == .normal)
        #expect(!decoded.isSafeFromWidget)
    }

    @Test("A destructive action stays withheld even without confirm")
    func destructiveAloneWithholds() throws {
        let decoded = try decode(#"{"id":"a","label":"Delete","role":"destructive"}"#)
        #expect(decoded.confirm == false)
        #expect(!decoded.isSafeFromWidget)
    }

    // MARK: - Helpers

    private func action(_ role: ActionDefinition.Role, confirm: Bool) -> ActionDefinition {
        ActionDefinition(id: "a", label: "Run", role: role, confirm: confirm)
    }

    private func decode(_ json: String) throws -> ActionDefinition {
        try JSONDecoder().decode(ActionDefinition.self, from: Data(json.utf8))
    }
}
