import Testing
import Foundation
import Hummingbird
import HummingbirdTesting
@testable import SwiftIdempotencyHummingbirdSpike
import SwiftIdempotency
import SwiftIdempotencyTestSupport

@Suite struct WebhookIdempotencyTests {

    // MARK: - Handler-level manual replay (baseline)

    /// Manual twice-call baseline — what every Hummingbird handler test has
    /// to fall back to today because `#assertIdempotent` is sync-only.
    @Test func webhookReturnsSameResultOnReplay() async throws {
        let store = PaymentStore()
        let payload = WebhookPayload(eventId: "evt_spike_1", amount: 100)

        let first = try await handleWebhook(payload: payload, store: store)
        let second = try await handleWebhook(payload: payload, store: store)

        #expect(first == second)
    }

    // MARK: - HTTP round-trip replay (HummingbirdTesting)

    /// Live HTTP test via HummingbirdTesting's `.router` framework. Exercises
    /// decoding, routing, response encoding — the surface a handler-level
    /// call skips.
    ///
    /// Replay safety is confirmed by decoding both responses back to
    /// `ChargeResult` and comparing structurally. **Not** by byte-equality:
    /// Hummingbird's default response encoder produces non-deterministic
    /// JSON key ordering across calls, so byte-diff tests are flaky even
    /// when the handler is genuinely idempotent. See FRICTION.md finding 4.
    @Test func webhookIsReplaySafeOverHTTP() async throws {
        let store = PaymentStore()
        let profiles = ProfileStore()
        let app = Application(
            router: buildRouter(store: store, profiles: profiles)
        )
        let payload = WebhookPayload(eventId: "evt_spike_http", amount: 250)
        let body = try JSONEncoder().encode(payload)

        try await app.test(.router) { client in
            let first = try await postAndDecode(
                client, uri: "/webhook", body: body,
                as: ChargeResult.self
            )
            let second = try await postAndDecode(
                client, uri: "/webhook", body: body,
                as: ChargeResult.self
            )
            #expect(first == second)
        }
    }

    /// Upsert endpoint — PUT twice, compare structurally. This is the
    /// parameterised `@Idempotent` case the peer-macro can't auto-generate
    /// a test for; confirming replay safety here has to be hand-rolled.
    @Test func upsertIsReplaySafeOverHTTP() async throws {
        let store = PaymentStore()
        let profiles = ProfileStore()
        let app = Application(
            router: buildRouter(store: store, profiles: profiles)
        )
        let profile = UserProfile(userId: "user_1", displayName: "Alice")
        let body = try JSONEncoder().encode(profile)

        try await app.test(.router) { client in
            let first = try await putAndDecode(
                client, uri: "/profiles", body: body,
                as: UserProfile.self
            )
            let second = try await putAndDecode(
                client, uri: "/profiles", body: body,
                as: UserProfile.self
            )
            #expect(first == second)
        }
    }

    // MARK: - HTTP helpers
    //
    // Wrapping the request dance in small helpers keeps the tests focused
    // on the replay assertion. Both helpers decode the response body back
    // through `JSONDecoder` — the canonical-form comparison pattern that
    // sidesteps Hummingbird's non-deterministic JSON key ordering.

    private func postAndDecode<T: Decodable>(
        _ client: any TestClientProtocol,
        uri: String,
        body: Data,
        as: T.Type
    ) async throws -> T {
        try await client.execute(
            uri: uri,
            method: .post,
            headers: [.contentType: "application/json"],
            body: ByteBuffer(data: body)
        ) { response in
            #expect(response.status == .ok)
            return try JSONDecoder().decode(T.self, from: Data(buffer: response.body))
        }
    }

    private func putAndDecode<T: Decodable>(
        _ client: any TestClientProtocol,
        uri: String,
        body: Data,
        as: T.Type
    ) async throws -> T {
        try await client.execute(
            uri: uri,
            method: .put,
            headers: [.contentType: "application/json"],
            body: ByteBuffer(data: body)
        ) { response in
            #expect(response.status == .ok)
            return try JSONDecoder().decode(T.self, from: Data(buffer: response.body))
        }
    }

    // MARK: - Async #assertIdempotent against a real Hummingbird handler
    //
    // Previously finding #1 in FRICTION.md (async variant missing). Now
    // resolved by the async overload in SwiftIdempotency. Compares
    // structurally (decode → Equatable) to dodge finding #4 (JSON key
    // ordering non-determinism).
    @Test func webhookIdempotentViaMacroHTTP() async throws {
        let store = PaymentStore()
        let profiles = ProfileStore()
        let app = Application(
            router: buildRouter(store: store, profiles: profiles)
        )
        let payload = WebhookPayload(eventId: "evt_macro_1", amount: 999)
        let body = try JSONEncoder().encode(payload)

        try await app.test(.router) { client in
            let result = try await #assertIdempotent {
                try await client.execute(
                    uri: "/webhook",
                    method: .post,
                    headers: [.contentType: "application/json"],
                    body: ByteBuffer(data: body)
                ) { response -> ChargeResult in
                    #expect(response.status == .ok)
                    return try JSONDecoder().decode(
                        ChargeResult.self,
                        from: Data(buffer: response.body)
                    )
                }
            }
            #expect(result.status == "succeeded")
            #expect(result.amount == 999)
        }
    }
}
