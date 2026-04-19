# SwiftIdempotency × Hummingbird — Friction Log

Running record of every place the package gets in the way of a realistic
Hummingbird app, plus the linter-integration loop validation. Ordered by
severity.

## TL;DR

All five package-side findings from the Hummingbird road test are now
resolved; 2 linter-side notes remain in SwiftProjectLint's backlog.

- ~~**Blocker**: `#assertIdempotent` has no `async` overload~~ → **resolved**.
  `try await #assertIdempotent { ... }` now compiles and passes against a
  live Hummingbird HTTP handler.
- ~~**Refinement**: `@ExternallyIdempotent(by:)` silently accepts
  unreachable paths like `"payload.eventId"`~~ → **resolved**. Macro now
  rejects dotted paths, non-literals, and unknown parameter labels at
  expansion time with actionable diagnostics.
- ~~**Refinement**: `@IdempotencyTests` unconditionally emits `try await`
  and warns on non-throwing targets~~ → **resolved**. Expansion now
  inspects the target's effect specifiers and emits `try` / `await` only
  when the target's signature requires them.
- ~~**Doc gap**: byte-equality on HTTP responses unsafe~~ → **resolved
  by README**. "Comparing structured responses" section added to tier 3
  with the decode-then-compare pattern drawn from the spike's helpers.
- ~~**Positive layering finding**: typed `IdempotencyKey` subsumes
  `MissingIdempotencyKey` at migrated call sites~~ → **resolved by
  README**. Coordination section now explains the tier layering
  explicitly: type catches what it can earliest, lint catches the
  string-typed remainder.
- **Linter loop validated**: 3/4 planted negatives fire correctly; 1
  bypass (`"\(Date.now)"` interpolation) logged for SwiftProjectLint's
  backlog.

## Package-side findings

### 1. `#assertIdempotent` has no async variant — ~~BLOCKER~~ → Resolved

See "Resolved" section below.

### 2. `@ExternallyIdempotent(by:)` silently accepted unreachable paths — ~~finding~~ → Resolved

See "Resolved" section below.

### 3. `IdempotencyKey` subsumes `MissingIdempotencyKey` on migrated code — ~~finding~~ → Resolved

See "Resolved" section below.

### 4. Byte-equality of HTTP responses is not a safe replay check — ~~finding~~ → Resolved

See "Resolved" section below.

### 5. `@IdempotencyTests` emits spurious `try` warnings — ~~finding~~ → Resolved

See "Resolved" section below.

## Linter-side notes (deferred — not this spike)

> These are for SwiftProjectLint's backlog; the spike just catalogues them.

### L1. `"\(Date.now)"` slips past `MissingIdempotencyKey`

Visitor (`MissingIdempotencyKeyVisitor.nonStableReason`) matches direct
calls and two-level member accesses, but not string-interpolation
expressions that wrap a non-stable generator. Repro: the
`callsLegacyChargeWithDateNow` function in `SpikeNegatives.swift:27`
passes `"\(Date.now)"` and fires *nothing*, while line 24's `UUID().uuidString`
fires correctly.

Low-impact (interpolating a fresh value into a stable string is unusual),
but it's the kind of bypass that looks plausible in real code.

### L2. No `@Replayable` / `@RetrySafe` attribute in SwiftIdempotency

Effect-side has attributes (`@Idempotent`, `@NonIdempotent`, etc.), but
*context*-side has only the doc-comment form
(`/// @lint.context replayable`). The spike's Negative C uses the
doc-comment because there's no attribute to use. Worth either exposing a
symmetric attribute surface or documenting "context annotations are
doc-comment only."

## Linter-integration loop — validated

Positive cases (annotated handlers): webhook receiver, upsert, send-email
— linter produces **0 findings**. Confirms the annotations are being
parsed and the silence is real, not a miss.

Negative cases (three planted bugs):

| Rule                          | Site in `SpikeNegatives.swift` | Fired? |
|-------------------------------|--------------------------------|--------|
| `MissingIdempotencyKey`       | line 24 — `UUID().uuidString`  | ✓      |
| `MissingIdempotencyKey`       | line 27 — `"\(Date.now)"`      | ✗ (L1) |
| `IdempotencyViolation`        | line 44                        | ✓      |
| `NonIdempotentInRetryContext` | line 57                        | ✓      |

Reproducible with: `cd ~/xcode_projects/SwiftProjectLint && swift run CLI
<spike>/Sources --categories idempotency`.

## Resolved

### 1. `#assertIdempotent` async variant — shipped

**Was.** Signature was `() throws -> Result`. Every realistic Hummingbird
handler is `async throws`, so the expression macro was unusable against
the exact workload it was designed to validate.

**Fix.** Added a second `assertIdempotent` macro declaration with an
`() async throws -> Result` signature, implemented by a new
`AssertIdempotentAsyncMacro` type that emits calls to a new
`__idempotencyAssertRunTwiceAsync` runtime helper (`async rethrows`,
otherwise identical to the sync helper). Swift's overload resolution
picks the sync overload for closures without `await` and the async
overload when the closure contains `await` — adopters don't choose
explicitly; they just write `try #assertIdempotent { ... }` or
`try await #assertIdempotent { ... }` depending on their closure.

**Verification:**
- Package: 6 new tests in `AssertIdempotentMacroTests.swift` — 3 macro
  expansion shape, 3 runtime behaviour (idempotent, throwing,
  sync-still-resolves-to-sync). 43/43 total pass.
- Spike: previously-commented `webhookIdempotentViaMacroHTTP` test now
  uses `try await #assertIdempotent` against a real Hummingbird HTTP
  handler via HummingbirdTesting. 6/6 spike tests pass, 10/10 stable
  across reruns.

**Files touched:**
- `Sources/SwiftIdempotency/AssertIdempotent.swift` — added async macro
  declaration + async runtime helper
- `Sources/SwiftIdempotencyMacros/AssertIdempotentMacro.swift` — added
  `AssertIdempotentAsyncMacro` type, factored closure-extraction into a
  shared helper
- `Sources/SwiftIdempotencyMacros/IdempotentMacro.swift` — registered the
  new macro in `providingMacros`
- `Tests/SwiftIdempotencyTests/AssertIdempotentMacroTests.swift` — 6 new
  tests

### 2. `@ExternallyIdempotent(by:)` argument validation — shipped

**Was.** The macro accepted any string value unconditionally. An adopter
writing `@ExternallyIdempotent(by: "payload.eventId")` — intending a
key path into a decoded request body — got a clean compile *and* no
linter finding (the linter's `MissingIdempotencyKey` rule only verifies
top-level parameter labels, not dotted paths). False safety shipped.

The road-test surfaced this concretely: the spike's own
`handleWebhook(payload:, store:)` was annotated
`@ExternallyIdempotent(by: "eventId")` (where `eventId` is a field of
`WebhookPayload`, not a parameter label). Pre-fix, this compiled silently.
Post-fix, the macro flagged it as an error and the spike had to adopt the
split-handler pattern — putting `@ExternallyIdempotent(by:
"idempotencyKey")` on the downstream `processCharge(idempotencyKey:)`
function, where `idempotencyKey` is a real parameter label.

**Fix.** `ExternallyIdempotentMacro` now validates `by:` at expansion
time and emits three distinct diagnostics:

1. **Dotted key paths** — `by: "payload.eventId"` is rejected with a
   message pointing at the split-handler pattern and explaining why the
   rejection is happening (neither the macro nor the linter verifier can
   resolve nested paths today).
2. **Non-literal expressions** — `by: someVariable` and interpolated
   string literals are rejected, because the linter's `MissingIdempotencyKey`
   visitor reads the value statically.
3. **Unknown parameter labels** — `by: "wrongName"` on a function whose
   external parameter labels are `["amount", "key"]` is rejected with
   the available labels listed. Wildcard-named parameters (`_ k:
   String`) contribute no external label, so `by: "k"` correctly won't
   reach them.

The existing quiet paths are preserved: no `by:` argument *and* `by: ""`
both skip validation and emit no diagnostic (the documented "annotation
granted lattice trust without key-routing verification" behaviour).

**Verification:**
- Package: 11 new tests in `ExternallyIdempotentMacroTests.swift` — 5
  quiet-path positives, 6 diagnostic negatives including the
  dotted-path, unknown-label, wildcard-only, non-literal, and
  interpolated-literal cases. 54/54 total pass.
- Spike: build caught the pre-existing `@ExternallyIdempotent(by:
  "eventId")` bug on my own `handleWebhook`, which was the exact shape
  described in the original finding. Fixed via split-handler pattern.
  All 6 spike tests pass. Linter's 3 expected negatives still fire at
  the same line numbers.

**Files touched:**
- `Sources/SwiftIdempotencyMacros/IdempotentMacro.swift` — added
  validation logic, parameter-extraction helpers, and a
  `ExternallyIdempotentDiagnostic` struct with three diagnostic factories
- `Tests/SwiftIdempotencyTests/ExternallyIdempotentMacroTests.swift` —
  new test file
- Spike: `SwiftIdempotencyHummingbirdSpike.swift` — moved
  `@ExternallyIdempotent(by: "idempotencyKey")` from the webhook decoder
  to the inner `processCharge`; webhook decoder is now `@Idempotent`.
  `SpikeNegatives.swift` — removed the now-invalid `probeKeyPathForm`
  and replaced with a note explaining the diagnostic.

### 5. `@IdempotencyTests` effect-aware expansion — shipped

**Was.** `@IdempotencyTests` unconditionally emitted `try await` around
the helper call and bare `fn()` inside the closure, regardless of the
target function's actual effect specifiers. For non-throwing zero-arg
functions — by far the most common shape for the zero-arg idempotent
case — Swift emitted a warning on the generated code:

```swift
let (__first, __second) = try await SwiftIdempotency.__idempotencyInvokeTwice {
    currentServiceStatus()
}
// warning: no calls to throwing functions occur within 'try' expression
```

The warning lived in macro-expanded code, which the package's own
SwiftSyntax-assertion tests don't compile, so it was invisible until the
Hummingbird road test actually built an adopter's test target.

**Fix.** The macro now extracts each target's
`signature.effectSpecifiers`, reads `asyncSpecifier` and `throwsClause`,
and emits one of four shapes:

| target effects | inner body | outer helper call |
|---|---|---|
| `()` | `fn()` | `await __helper { ... }` |
| `() throws` | `try fn()` | `try await __helper { ... }` |
| `() async` | `await fn()` | `await __helper { ... }` |
| `() async throws` | `try await fn()` | `try await __helper { ... }` |

The outer `await` stays unconditional because `__idempotencyInvokeTwice`
is `async`. The outer `try` appears only when the body can throw
(helper is `rethrows`). The test method stays `async throws` regardless
— Swift doesn't warn on declared-but-unused `throws`, only on `try`
over non-throwing expressions.

**Verification:**
- Package: 4 new tests in `IdempotencyTestsMacroTests.swift`, one per
  effect combination, each locking in the exact emitted `try` / `await`
  pattern. Existing 5 tests updated to the new shape (sync
  non-throwing targets lost their spurious `try`). 58/58 total pass.
- Spike: clean rebuild of the entire test target emits zero
  `"no calls to throwing functions occur within 'try' expression"`
  warnings. The `SpikeHealthChecks` suite's two auto-generated tests
  (`testIdempotencyOfCurrentServiceStatus`,
  `testIdempotencyOfReadinessHash`) continue to pass. 6/6 spike tests
  green.

**Files touched:**
- `Sources/SwiftIdempotencyMacros/IdempotencyTestsMacro.swift` — added
  effect-specifier inspection to `generateTestMember`; the
  function now accepts the full `FunctionDeclSyntax` instead of just a
  name, and composes inner/outer effect prefixes from the matrix above
- `Tests/SwiftIdempotencyTests/IdempotencyTestsMacroTests.swift` —
  updated existing expansions to drop spurious `try`, added 4 new
  effect-combination tests

### 3 + 4. README: tier layering and structured-response guidance — shipped

Both findings are adopter-onboarding content; neither required code
changes. Bundled into one README pass.

**Finding 3 (tier layering).** The Coordination-with-SwiftProjectLint
section gains a bullet explaining how the three tiers don't overlap
wastefully: `IdempotencyKey` rejects `UUID()` at migrated call sites at
compile time, so `MissingIdempotencyKey` can't fire there — but it still
carries its weight on call sites where the key is typed as `String`.
Both tiers pull, at different seams.

**Finding 4 (structured-response comparison).** Tier 3 of the README
gains a "Comparing structured responses" subsection that covers the
`#assertIdempotent<Result: Equatable>` footgun on raw response bytes
(JSON key ordering isn't deterministic, so two semantically-equal
responses can diverge on the wire). The fix is the spike's own pattern:
decode inside the closure before handing the typed value to the
assertion. An example drawn directly from the spike's HummingbirdTesting
test shows the full shape.

**Other README cleanup folded in.** While there, corrected stale
references to the round-7 peer-macro shape (`@Idempotent` emitting a
test) throughout the "What this package does", "What this package does
NOT do", and "Status" sections — the source of truth is now
`@IdempotencyTests` as the round-8 extension macro.

**Verification:** 58/58 package tests pass (pure doc, no code change);
6/6 spike tests pass; 10/10 reruns stable.

**Files touched:**
- `README.md` — rewrote tier 3 section for round-8 shape + sync/async
  `#assertIdempotent` examples + "Comparing structured responses"
  subsection; added tier-layering bullet to Coordination section; fixed
  three stale `@Idempotent`-as-generator references in design-boundaries
  and status sections.
