import Testing
@testable import SwiftIdempotencyHummingbirdSpike
import SwiftIdempotency

// Exercises the `@IdempotencyTests` extension macro — the round-8 redesign
// where the peer-role moved from `@Idempotent` (which is now marker-only)
// to a suite-level extension macro. For every `@Idempotent`-marked
// zero-argument member, the macro should emit one `@Test` method in an
// extension of the annotated suite type.
//
// In practice, realistic Hummingbird handlers are parameterised. The only
// honest zero-arg cases are status pings, cache-flush-type maintenance
// routines, or introspection endpoints. Those *do* exist in real apps,
// just at low density.

@Suite
@IdempotencyTests
struct SpikeHealthChecks {

    @Idempotent
    func currentServiceStatus() -> Int { 200 }

    @Idempotent
    func readinessHash() -> String { "ready" }

    /// Intentionally unmarked — should NOT appear in the generated tests.
    func forbiddenHelper() -> Int { 42 }
}
