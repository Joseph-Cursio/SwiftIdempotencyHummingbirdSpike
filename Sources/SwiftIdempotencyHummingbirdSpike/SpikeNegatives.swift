import Foundation
import SwiftIdempotency

// Deliberate-violation endpoints. Every function here is shaped to trigger
// a specific linter rule; FRICTION.md records whether each one actually
// fires when `swift run CLI` is pointed at the spike.
//
// Kept in-target so `swift build` sees them — the compile-time surface is
// fine; only the lint-time surface is supposed to fail.

// MARK: - Negative A — MissingIdempotencyKey
//
// "Legacy" shape: the callee hasn't migrated to `IdempotencyKey` yet and
// takes a plain `String`. The `@ExternallyIdempotent(by:)` annotation
// still works, and the call site passes `UUID().uuidString` — exactly
// what the visitor flags.

@ExternallyIdempotent(by: "token")
func legacyCharge(amount: Int, token: String) async throws -> String {
    "charge:\(amount):\(token)"
}

func callsLegacyChargeWithFreshUUID() async throws -> String {
    try await legacyCharge(amount: 50, token: UUID().uuidString)
}

func callsLegacyChargeWithDateNow() async throws -> String {
    try await legacyCharge(amount: 50, token: "\(Date.now)")
}

// MARK: - Negative B — IdempotencyViolation
//
// An `@Idempotent` function that calls into a `@NonIdempotent` one
// without routing through a deduplication key. Linter should flag the
// contract breach.

@NonIdempotent
func writeAuditRow(_ message: String) async throws {
    _ = message
}

@Idempotent
func reconcileAccount(_ accountId: String) async throws {
    try await writeAuditRow("reconcile:\(accountId)")
}

// MARK: - Negative C — NonIdempotentInRetryContext
//
// A function marked as a retry-safe / replayable context that calls a
// `@NonIdempotent` routine directly. Uses the doc-comment annotation
// form because the attribute surface doesn't currently expose a
// `@Replayable` / `@RetrySafe` marker — which is itself a finding for
// FRICTION.md.

/// @lint.context replayable
func retryScopedJob() async throws {
    try await writeAuditRow("retry-loop-body")
}

// MARK: - Finding #2 probe — resolved
//
// The original probe here attached `@ExternallyIdempotent(by: "payload.eventId")`
// to a handler whose parameters were `payload` and `store` (no `eventId`
// or `payload.eventId` label). Pre-fix, the macro accepted the argument
// silently, resulting in false safety.
//
// Post-fix, the same code produces a compile-time diagnostic:
//
//     @ExternallyIdempotent(by: "payload.eventId") contains a dotted key
//     path, which is not supported. The `by:` argument must name a top-
//     level parameter label of the annotated function. To route a key
//     from a nested field, split the handler: decode the payload in one
//     function, then forward to a downstream function whose parameter
//     carries the key, and attach @ExternallyIdempotent there.
//
// The split-handler pattern the diagnostic recommends is exactly what
// `processCharge` implements in the main spike source — it takes
// `idempotencyKey: IdempotencyKey` directly, and the webhook handler
// extracts `payload.eventId` before forwarding. See FRICTION.md's
// "Resolved" section for the full fix writeup.
