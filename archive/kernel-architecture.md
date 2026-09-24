# Architecture: Kernel + Frozen Engine Crates

This document describes the target architecture ("Model B"): a stable kernel
crate, one frozen engine crate per language version, and a host-side
dispatcher. It also describes the pragmatic path from today's single
epoch-gated crate to that architecture.

## 1. The constraint that shapes everything

Contracts live forever. A Clarity 1 contract deployed in 2021 must be
executable at every future epoch, and **a single transaction can traverse
contracts of different language versions in one call stack** (a new contract
`contract-call?`s an old one, or vice versa). Therefore:

- Every validating node must link an engine for *every* language version that
  has ever existed. Engines are never removed, only frozen.
- Cross-version calls cross crate boundaries **mid-transaction**, sharing
  database state, cost budget, asset tracking, and events. That shared
  machinery must live in a crate all engines agree on: the **kernel**.
- The kernel's types and stored data formats are consensus-critical and shared
  across all engine crates simultaneously, so the kernel must be **eternally
  additive-only** (`1.x` forever). This is the single most important semver
  rule in the design.

## 2. Crate layout

```
clarity-kernel        eternally stable; additive-only 1.x forever
├── values & types    Value, TypeSignature, principals, sequences
├── serialization     consensus wire format (SIP-005), stored analysis
│                     metadata, database key/value layout
├── database          ClarityDatabase, rollback wrapper, backing-store trait
├── costs             cost & memory accounting (ExecutionCost, trackers,
│                     limits) — shared budget across engines in one tx
├── events/assets     event batches, asset maps (post-condition inputs)
├── host interface    what a chain must provide: block info, burn info,
│                     tx sender context, special-contract hooks
└── interop ABI       Engine trait + TransactionContext trait: the
                      cross-version call boundary

clarity-legacy        Clarity 1–6: today's clarity crate, wrapped to
                      implement the kernel Engine trait. Behavior frozen;
                      implementation-defined semantics; consensus-fix
                      patches only. Epoch gating stays inside, untouched.

clarity-vNEXT         the first spec-first engine (working name; likely
                      "Clarity 7" in the version enum). Clean-room
                      implementation from the spec. Frozen at release.

clarity-vNEXT+1, ...  each subsequent language version: its own crate,
                      designed against the spec of its version, frozen at
                      release. No obligation to resemble its predecessor.

(host side, in stackslib)
clarity-dispatch      epoch → engine-set manifest; routes each contract to
                      the engine for its declared version; implements the
                      host interface over Stacks chainstate; owns boot
                      contracts, PoX hooks, cost contract selection.
```

Supporting crates: `clarity-primitives` (hashes, c32/principal encoding,
secp256k1/r1 verification — the pieces currently pulled from `stacks-common`)
either stands alone or folds into the kernel.

## 3. The interop boundary

The kernel defines two traits; engines see the world only through them.

```rust
/// Implemented by every engine crate. Object-safe; kernel types only.
pub trait Engine {
    fn language_version(&self) -> LanguageVersion;

    /// Parse + type-check + analyze. Produces the stored contract
    /// interface (kernel-stable format) that other engines read when
    /// type-checking calls into this contract.
    fn analyze(
        &self,
        contract: &ContractIdentifier,
        source: &str,
        ctx: &mut dyn AnalysisContext,
    ) -> Result<ContractAnalysis, EngineError>;

    /// Deploy: evaluate top-level forms, persist metadata.
    fn initialize(
        &self,
        contract: &ContractIdentifier,
        source: &str,
        tx: &mut dyn TransactionContext,
    ) -> Result<(), EngineError>;

    /// Execute one public/read-only function call.
    fn call(
        &self,
        contract: &ContractIdentifier,
        function: &str,
        args: &[Value],
        tx: &mut dyn TransactionContext,
    ) -> Result<Value, EngineError>;
}

/// Handed to an engine for the duration of one call frame. Carries all
/// transaction-scoped shared state.
pub trait TransactionContext {
    fn db(&mut self) -> &mut ClarityDatabase;          // shared rollback tx
    fn costs(&mut self) -> &mut dyn CostTracker;       // shared budget
    fn assets(&mut self) -> &mut AssetMap;             // post-condition data
    fn emit(&mut self, event: ClarityEvent);
    fn caller_context(&self) -> &CallerContext;        // tx-sender, caller,
                                                       // sponsor, call depth

    /// Cross-contract call. Re-enters the dispatcher, which looks up the
    /// callee's declared version and routes to the right engine — possibly
    /// a different crate. Reentrancy and depth checks happen here, in the
    /// kernel, uniformly for all versions.
    fn call_contract(
        &mut self,
        contract: &ContractIdentifier,
        function: &str,
        args: &[Value],
    ) -> Result<Value, EngineError>;
}
```

Key properties of this boundary:

- **Values are the only data that cross.** Arguments and returns are kernel
  `Value`s in the frozen serialization model. An engine's internal
  representation (interpreted AST, Wasm, whatever) never leaks.
- **Trait/interface compatibility is checked against stored metadata.** When a
  vNEXT contract calls a Clarity 2 contract, its type checker reads the
  callee's `ContractAnalysis` (kernel format) — it never needs the legacy
  engine's type checker. Cross-version trait semantics are specified at the
  kernel level.
- **Reentrancy, call depth, and cost enforcement live in the kernel**, so no
  engine can get them wrong and all versions agree.
- **clar2wasm becomes an alternative `Engine` implementation** for a given
  language version, conformance-tested against the reference engine. The
  architecture is exactly the pluggability clar2wasm needs today.

## 4. Epoch pinning

Each stacks-core epoch pins a **manifest** that maps every contract language
version to an exact engine revision. Selection uses the epoch of the block
currently being executed — not the contract's deployment epoch:

```toml
# conceptual — the dispatcher encodes this mapping
[epoch.3_2]
clarity.1-through-4 = "clarity-legacy@7"

[epoch.4_0]
clarity.1-through-6 = "clarity-legacy@8" # epoch-4.0 fixes to old contracts
clarity.7           = "clarity-v7@1"
```

This is a two-dimensional lookup — `(current epoch, contract Clarity
version) -> engine revision` — but not a crate for every cell. Epochs reuse
the same engine revision until that engine's behavior actually changes. A
future epoch that changes only Clarity 7 selects `clarity-v7@2` while
continuing to select the same legacy revision; an epoch with no relevant
semantic change reuses the whole preceding manifest.

- Cargo links multiple **majors** of the same package under renamed
  identifiers (`clarity_legacy_e32 = { package = "clarity-legacy",
  version = "7" }`), so historical replay uses the exact code that was
  consensus at that epoch. Cargo unifies semver-compatible versions, so
  **consensus fixes to a frozen engine are always major bumps** — honest
  semver, since consensus changes are maximally breaking. Patch/minor
  releases are reserved for provably non-consensus changes (docs,
  diagnostics, performance). "Frozen" means *no semantic drift within an
  epoch*, not "never patched."
- The current epoch, rather than deployment epoch, is required for historical
  epoch gates that intentionally changed already-deployed contracts. For
  example, pre-3.4 Clarity 1–4 contracts contain `at-block`, but calls made at
  epoch 3.4 and later must use the post-3.4 legacy revision where it is
  unavailable; replaying their earlier calls selects the earlier revision.
- **The kernel is singly linked and cannot be pinned per epoch**: its types
  are the ABI, and two kernel copies would mean two incompatible `Value`s.
  Every engine major compiles against the same additive-only
  `clarity-kernel 1.x`. The corollary: rare consensus-relevant kernel
  changes (database semantics, serialization edge cases, cost accounting
  mechanics) are gated internally by a kernel-owned ruleset id mapped from
  epochs by the host — the one place runtime gating legitimately survives,
  kept small by keeping the kernel's consensus surface small.

Costs of this model, accepted deliberately: binary size and compile time grow
with each language version and consensus fix (engine copies are single-digit
MB of release code each, compiled once and cached; expect a new engine every
1–2 years, not every release — see the sizing analysis in
[extraction-plan.md](extraction-plan.md)). Every validating node
carries the current major of every engine forever (unavoidable — old
contracts are callable at the current epoch); *superseded* majors are needed
only for historical replay and can be feature-gated out of non-archival
builds.

## 5. Migration path from today's code

Today: one `clarity` crate ([clarity/](../../../clarity/)) with ~589 runtime
epoch branches, depending on `stacks-common`; `clarity-types` already split
out; DB traits (`HeadersDB`, `BurnStateDB` in
[clarity_db.rs](../../../clarity/src/vm/database/clarity_db.rs)) shaped around
Stacks chainstate; boot contracts and cost contracts in stackslib;
`pox-locking` injecting special-case handlers.

Order of operations (details and sizing in [05-roadmap.md](../05-roadmap.md)):

1. **Carve out the kernel in place.** Inside the existing workspace, move
   values/serialization/database/costs/events into `clarity-kernel` (growing
   from today's `clarity-types`). The existing VM keeps working against it.
   Replay-validated at every step.
2. **Cut the stacks-core dependencies.** Extract needed primitives from
   `stacks-common`; replace `StacksEpochId` inside the VM with a
   kernel-owned ruleset identifier (the host maps epochs to rulesets);
   replace `HeadersDB`/`BurnStateDB` with the minimal specified host
   interface; make the pox-locking hook a generic registration API.
3. **Wrap the legacy engine.** Implement `Engine` for the current VM
   (versions 1–6), build the dispatcher in stackslib, route all execution
   through the kernel boundary. At this point behavior is still identical —
   the boundary is load-bearing but the code behind it is unchanged.
4. **Extract to a separate repo and publish.** Kernel + legacy engine move
   out; stacks-core, clar2wasm, and Clarinet consume from crates.io. The
   legacy engine is declared frozen.
5. **Build vNEXT from the spec** as the first true per-version engine crate,
   activated by a future epoch through the manifest.

## 6. Risks

| Risk | Mitigation |
|---|---|
| Kernel ABI turns out to be wrong after freezing | Kernel is additive-only, so mistakes are permanent surface area. Mitigate by validating the ABI with *two* real engines (legacy + vNEXT) and one alternative backend (clar2wasm) before declaring 1.0 |
| Consensus drift during extraction | Full-history mainnet replay in CI on every step; conformance vectors captured from mainnet transactions; no step ships without bit-identical replay |
| Dispatcher/kernel overhead on the hot path | The cross-engine boundary replaces existing dynamic dispatch that is already present (`contract-call?` machinery); benchmark against the existing criterion suites before/after |
| Binary size / compile time growth | One new engine per language version (rare); engines compile once; measure and, if needed, split archival-replay pins behind a feature for non-archival tooling (validators always carry all engines) |
| Downstream churn (Clarinet, clar2wasm, API) | They gain a published crate with semver instead of git-pinning stacks-core; coordinate before the repo split, not after |
| Kernel hosts two type worlds (legacy quirks vs. vNEXT cleanups) | The kernel models *values and storage*, not each version's static type system; engines own their type checkers. Only the value model and stored interface format are shared |
