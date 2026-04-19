import Hummingbird
import SwiftIdempotency

/// Minimal in-memory store standing in for a real database.
/// The spike is about ergonomics of the package, not persistence.
public actor PaymentStore {
    private var processed: [String: ChargeResult] = [:]

    public init() {}

    public func recordIfAbsent(
        key: String,
        result: ChargeResult
    ) -> ChargeResult {
        if let existing = processed[key] { return existing }
        processed[key] = result
        return result
    }
}

public struct ChargeResult: Codable, Equatable, ResponseEncodable, Sendable {
    public let status: String
    public let amount: Int
    public let key: String
}

public struct WebhookPayload: Codable, Sendable {
    public let eventId: String
    public let amount: Int
}

/// Webhook receiver — the outer half of the split-handler pattern. Decodes
/// the payload, extracts the idempotency key from a nested field, and
/// forwards to the key-consuming worker. `@ExternallyIdempotent(by:)` can't
/// name `payload.eventId` directly (dotted key paths aren't supported — see
/// finding #2 in FRICTION.md), so the external-idempotency annotation
/// lives on the downstream `processCharge`. This function is `@Idempotent`
/// because re-invoking it with the same `WebhookPayload` produces the
/// same `ChargeResult` with no additional external effects.
@Idempotent
func handleWebhook(
    payload: WebhookPayload,
    store: PaymentStore
) async throws -> ChargeResult {
    let key = IdempotencyKey(fromAuditedString: payload.eventId)
    return try await processCharge(
        amount: payload.amount,
        idempotencyKey: key,
        store: store
    )
}

/// Charge worker — the inner half of the split-handler pattern. Takes
/// `IdempotencyKey` directly, so the type system rejects `UUID()` at call
/// sites and `@ExternallyIdempotent(by:)` can point to a real parameter
/// label, enabling the linter's `MissingIdempotencyKey` rule on
/// un-migrated adopters that pass raw strings.
@ExternallyIdempotent(by: "idempotencyKey")
func processCharge(
    amount: Int,
    idempotencyKey: IdempotencyKey,
    store: PaymentStore
) async throws -> ChargeResult {
    let result = ChargeResult(
        status: "succeeded",
        amount: amount,
        key: idempotencyKey.rawValue
    )
    return await store.recordIfAbsent(key: idempotencyKey.rawValue, result: result)
}

// MARK: - Upsert endpoint — parameterised @Idempotent
//
// Parameterised `@Idempotent` is exactly the case the peer-macro can't
// auto-generate a test for (round-8 design constraint). The marker still
// provides the lint signal; the test has to be hand-rolled or use
// `#assertIdempotent` — which is sync-only today, so this handler relies
// on the manual twice-call pattern in tests.

public struct UserProfile: Codable, Equatable, ResponseEncodable, Sendable {
    public let userId: String
    public let displayName: String
}

public actor ProfileStore {
    private var profiles: [String: UserProfile] = [:]
    public init() {}

    public func upsert(_ profile: UserProfile) -> UserProfile {
        profiles[profile.userId] = profile
        return profile
    }
}

@Idempotent
func upsertProfile(
    _ profile: UserProfile,
    store: ProfileStore
) async -> UserProfile {
    await store.upsert(profile)
}

// MARK: - Non-idempotent endpoint — @NonIdempotent
//
// Documentation + lint signal only. Every call re-sends; retrying it in
// a replayable context is a bug the linter should catch.

@NonIdempotent
func sendWelcomeEmail(to userId: String) async throws {
    // Pretend-delivery. The real one would hit an SMTP relay.
    _ = userId
}

public func buildRouter(
    store: PaymentStore,
    profiles: ProfileStore
) -> Router<BasicRequestContext> {
    let router = Router()
    router.post("/webhook") { request, context -> ChargeResult in
        let payload = try await request.decode(
            as: WebhookPayload.self,
            context: context
        )
        return try await handleWebhook(payload: payload, store: store)
    }
    router.put("/profiles") { request, context -> UserProfile in
        let profile = try await request.decode(
            as: UserProfile.self,
            context: context
        )
        return await upsertProfile(profile, store: profiles)
    }
    router.post("/welcome/:userId") { _, context -> HTTPResponse.Status in
        let userId = try context.parameters.require("userId")
        try await sendWelcomeEmail(to: userId)
        return .accepted
    }
    return router
}

@main
struct SpikeApp {
    static func main() async throws {
        let store = PaymentStore()
        let profiles = ProfileStore()
        let app = Application(
            router: buildRouter(store: store, profiles: profiles),
            configuration: .init(address: .hostname("127.0.0.1", port: 8080))
        )
        try await app.runService()
    }
}
