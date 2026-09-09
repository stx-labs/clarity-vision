# Extraction Plan: Kernel, Interfaces, and Version Maintenance

Engineering plan for extracting Clarity into independent crates with explicit
interfaces, and the maintenance model that keeps the latest language version
free of epoch and version gating. Refines [03-architecture.md](03-architecture.md)
with file-level detail and a hackathon execution slice.

## 1. What clar2wasm already proved about the boundary

The Wasm runtime integration (`clarity/src/vm/clarity_wasm.rs` on
`feat/clarity-wasm-develop`, ~11k lines) is an *empirically discovered* engine
boundary: to run compiled Clarity, it had to enumerate every service a
contract needs from the runtime as an explicit host function. That enumeration
is the kernel interface, found by building a real second engine rather than by
speculation:

| Category | Host functions (from `link_host_functions`) |
|---|---|
| Contract data | define/get/set variable; map get/set/insert/delete; define ft/nft/map/trait/function; impl-trait; save/load constant |
| Assets | stx balance/account/burn/transfer; ft supply/balance/mint/burn/transfer; nft owner/mint/burn/transfer; allowance frames (`with_ft/nft/stx/stacking`, restrict-assets enter/exit/cleanup) |
| Transaction context | tx-sender, contract-caller, tx-sponsor, current-contract; as-contract enter/exit (incl. safe variants) |
| Chain state | block/stacks-block/tenure/burn heights and times; liquid supply; chain-id, mainnet/regtest flags; get-block-info / get-burn-block-info / get-stacks-block-info / get-tenure-info properties |
| Control flow | contract-call; begin-public-call / begin-read-only-call / commit / roll-back; at-block enter/exit; contract hash |
| Crypto *(Wasm-backend detail — not kernel ABI, see below)* | keccak256, sha512, sha512/256, secp256k1 recover/verify, secp256r1 verify, principal-of |
| Observability | print/events, logging |

Two structural lessons:

1. **Pure computation is not in the boundary.** Arithmetic, sequence ops,
   tuples, string manipulation — all compiled into the Wasm module. The
   engine owns evaluation; the runtime owns state, context, and chain access.
   The kernel interface is the table above, nothing more.
2. **The context object is concrete, not abstract.** `ClarityWasmContext`
   holds `&mut GlobalContext` (database + cost tracker + asset maps + events)
   plus sender/caller/sponsor stacks and `at-block` state. Engines don't need
   trait-object indirection for data operations — they need shared concrete
   kernel state, with dynamic dispatch only at the *cross-engine call*
   boundary. This shapes the interface design below (§3) and avoids a
   hot-path performance regression.

The crypto row is the exception that proves the rule: those host functions
exist only because reimplementing secp256k1/sha512 *inside* a Wasm module
would be absurd — they are an implementation detail of the Wasm backend, not
a runtime service. Crypto is pure computation and stays **inside Clarity**:
`clarity-primitives` provides the implementations, each engine consumes them
internally (the Wasm engine keeps exposing them to its modules as its own
internal imports), nothing crosses the kernel ABI, and stacks-core defines
none of it.

## 2. Target crate layout

```
clarity-primitives   hashes, c32, secp256k1/r1 — extracted from stacks-common
clarity-types        values, type signatures, serialization (exists today)
clarity-kernel       consensus-shared runtime: database, rollback/call
                     framing, costs, events, asset maps, host interface,
                     engine ABI. Additive-only 1.x forever once published.
clarity              the current VM, unchanged in behavior → becomes the
                     frozen legacy engine (Clarity 1–6, epoch gating intact
                     INSIDE it, forever)
clarity-vN           one crate per future language version; exactly one
                     version each; zero epoch gating, zero version gating

(stackslib)          dispatcher: epoch → engine manifest; ChainHost impls
                     over MARF/sortition DB; boot contracts; PoX hooks
```

## 3. The three interfaces

### 3.1 `ChainHost` — what the chain provides to the kernel

Replaces `HeadersDB` + `BurnStateDB`
([clarity_db.rs:158,215](../../clarity/src/vm/database/clarity_db.rs)). Scope
it by need, not by history: the get-block-info/get-burn-block-info/
get-tenure-info host functions in `clarity_wasm.rs` enumerate exactly which
lookups contracts can express — that list, plus PoX/liquid-supply state, is
the whole trait. Stacks-specific shapes (`SortitionDBRef`, tenure lookups,
reward-set structs) stay on the stackslib side of the line
([stackslib/src/clarity_vm/database/mod.rs](../../stackslib/src/clarity_vm/database/mod.rs)).

### 3.2 `TransactionContext` — what the kernel provides to engines

A **concrete kernel struct** (following `ClarityWasmContext`'s design), owning
transaction-scoped shared state:

```rust
pub struct TransactionContext<'a> {
    pub db: &'a mut ClarityDatabase<'a>,     // shared rollback tx
    pub costs: &'a mut dyn CostTracker,      // shared budget
    pub assets: &'a mut AssetMap,            // post-condition data
    pub events: &'a mut Vec<StacksTransactionEvent>,
    pub caller: CallerContext,               // tx-sender/caller/sponsor,
                                             // as-contract & at-block stacks,
                                             // call depth
    dispatcher: &'a mut dyn ContractDispatcher,  // the ONLY dyn boundary
}

/// Cross-engine calls re-enter the host dispatcher, which routes to the
/// engine for the callee's declared language version. Reentrancy, depth,
/// and call framing (begin/commit/rollback) are enforced here, uniformly.
pub trait ContractDispatcher {
    fn call_contract(
        &mut self,
        ctx: /* reborrowed context */,
        contract: &QualifiedContractIdentifier,
        function: &ClarityName,
        args: &[Value],
    ) -> Result<Value, KernelError>;
}
```

Data/asset/chain-state operations are inherent methods on kernel types —
statically dispatched, same cost as today's direct `ClarityDatabase` calls.
Only `contract-call?` pays for dynamic dispatch, where it already pays for
far more than that.

### 3.3 `Engine` — what engines provide to the host

```rust
pub trait Engine {
    fn language_version(&self) -> LanguageVersion;

    /// Parse + check. Produces the kernel-format ContractAnalysis that
    /// OTHER engines read when type-checking calls into this contract.
    fn analyze(&self, contract: &QualifiedContractIdentifier, source: &str,
               ctx: &mut AnalysisContext) -> Result<ContractAnalysis, EngineError>;

    /// Deploy: evaluate top-level forms, persist contract state.
    fn initialize(&self, contract: &QualifiedContractIdentifier, source: &str,
                  tx: &mut TransactionContext) -> Result<(), EngineError>;

    /// Execute one function call. Values in, Value out.
    fn call(&self, contract: &QualifiedContractIdentifier, function: &ClarityName,
            args: &[Value], tx: &mut TransactionContext) -> Result<Value, EngineError>;
}
```

The legacy engine implements this by wrapping its existing entry points
(today's `initialize_contract` / `execute_contract` machinery behind
[clarity/src/vm/clarity.rs](../../clarity/src/vm/clarity.rs)'s
`TransactionConnection`). clar2wasm implements it as an alternative backend
for the same language versions — its `ClarityWasmContext` is rebuilt on top of
`TransactionContext`. The stored `ContractAnalysis` format becomes
kernel-owned and frozen: it is how engines see each other's interfaces without
sharing type checkers.

## 4. Version maintenance: pins, not branches

The rule that keeps the latest engine clean:

> **Every runtime `if epoch >= X` / `if version >= N` branch becomes a diff
> between two pinned releases.**

- **One crate = one language version.** No version gating can exist by
  construction.
- **Engines are epoch-blind.** No engine ever sees an epoch ID. Behavior
  changes ship as new releases of the engine crate; the epoch manifest in
  stackslib maps each epoch to the engine releases that define it:

```toml
[epoch.4_0]                       # conceptual; encoded in the dispatcher
clarity-legacy = "7"              # engine majors, linked side by side
clarity-v7     = "1"

[epoch.4_1]
clarity-legacy = "7"
clarity-v7     = "2"              # consensus fix, active from 4.1 only;
                                  # 4.0 replay still links major 1
```

- **Consensus fixes are semver-major bumps.** Cargo unifies semver-compatible
  versions to a single copy, so two releases of an engine can only be linked
  side by side (under renamed identifiers:
  `clarity_v7_e40 = { package = "clarity-v7", version = "1" }`) if they are
  different *majors*. That is semantically honest anyway — a consensus
  behavior change is the most breaking change there is. Patch/minor releases
  within a major are reserved for changes that provably cannot alter
  consensus behavior (docs, diagnostics, performance).
- **The kernel is the one place runtime gating survives — by necessity.**
  There is exactly one linked copy of `clarity-kernel`: its types *are* the
  ABI, and two copies would mean two incompatible `Value`s. So kernel
  behavior cannot be version-pinned per epoch; a consensus-relevant kernel
  change (database semantics, serialization edge case, cost accounting
  mechanics) is gated internally by a kernel-owned ruleset id that the host
  maps epochs onto. The discipline is to keep the kernel's consensus surface
  as small as possible so this gating stays rare; pins-not-branches governs
  the engines, where the code volume lives.
- **The legacy engine (`clarity` crate) keeps its internal epoch gating
  forever** — those branches encode Clarity 1–6 history and are frozen with
  it. Future fixes to it get the same major-bump pin treatment: today's
  ~589 gated sites never grow again.

### Binary size: measured and bounded

Linking one engine copy per language version (plus per consensus fix) sounds
alarming; the numbers say it isn't:

- **Per-copy cost is single-digit MB.** The entire current VM — parser, two
  type checkers, evaluator, costs, database — contributes a few MB of code to
  a release binary (the crate's *debug* rlib is ~73 MB, but that is
  debuginfo; release-linked code is far smaller). Future engines are smaller
  than that: one language version, no epoch branches, and the heavyweight
  shared machinery (values, serialization, database) lives in the
  singly-linked kernel, never duplicated.
- **The multiplier grows slowly.** New engines arrive roughly with new
  language versions — historically every 1–2 years — and consensus fixes to
  frozen engines are rarer still. A decade out, that's plausibly 6–8 linked
  copies: tens of MB in a node binary already that order of size, running on
  server hardware.
- **Tip validation needs fewer copies than replay.** At the chain tip, only
  the *current* major of each engine executes; superseded majors
  (pre-consensus-fix releases) are needed solely for replaying historical
  blocks. Non-archival builds can feature-gate old majors out, so the worst
  case falls only on nodes that already opted into storing full history.
- **The honest comparison is the status quo.** All epoch variants already
  live in today's binary as interleaved runtime branches. Pins-not-branches
  mostly *reorganizes* that code; true duplication (the shared skeleton of an
  engine appearing in two majors) is the price paid for deleting the gating,
  and it buys compile-time wins elsewhere: frozen engines compile once and
  cache forever, while today every clarity edit rebuilds everything
  downstream of one giant crate.

Track it in CI (a size budget per release), but this is a non-problem at
realistic scale.

## 5. Extraction sequence

Ordering principle: **structure first, decoupling second, relocation third.**
Every step lands with bit-identical behavior (full test suite; replay checks
for the riskier steps). The `stacks-common` dependency is *not* the critical
path — the kernel can depend on it transitionally; it must be gone only
before crates.io publication.

**Step 1 — Carve out `clarity-kernel` (mechanical).** New workspace crate.
Move from `clarity`: `vm/database/*` (ClarityDatabase, rollback/KV wrappers,
`ClarityBackingStore`, structures), `vm/costs/*` (ExecutionCost, trackers,
limits), `vm/events.rs`, `AssetMap` (out of `contexts.rs`), and the shared
error types. `clarity` re-exports everything from its old paths
(`pub use clarity_kernel::...`) so stackslib, pox-locking, and tests don't
change. No behavior change possible — it's file motion.

**Step 2 — Define the ABI in the kernel.** `Engine`, `TransactionContext`,
`ContractDispatcher`, `ChainHost`, `AnalysisContext` (§3), with the
`clarity_wasm.rs` host-function table as the completeness checklist: every
row must be expressible through kernel types.

**Step 3 — Wrap the legacy engine.** `impl Engine` for the current VM: the
engine constructs its `GlobalContext`/`Environment` from `TransactionContext`
parts, and its `contract-call?` implementation routes through
`ContractDispatcher` instead of self-recursion. Build the dispatcher and a
minimal harness (clarity-cli or a test embedder) that runs contracts entirely
through the ABI.

**Step 4 — Route stackslib through the dispatcher.**
`ClarityBlockConnection`/`ClarityTransactionConnection`
([stackslib/src/clarity_vm/clarity.rs](../../stackslib/src/clarity_vm/clarity.rs))
construct `TransactionContext` and call `Engine` methods instead of the VM
directly. Replay validation gate.

**Step 5 — Decouple.** Epoch inversion (kernel-owned ruleset id; the
epoch→ruleset map and `default_for_epoch` move to stackslib);
`clarity-primitives` extraction from `stacks-common`; `ChainHost` replaces
`HeadersDB`/`BurnStateDB`; pox-locking hook becomes a generic registration.

**Step 6 — Repo split, publish, freeze.** Kernel + legacy engine + types +
primitives move to the language repo; publish; declare the legacy engine
frozen; stacks-core adopts the manifest/pinning mechanism at the next epoch
boundary. clar2wasm and Clarinet migrate to published crates.

**Step 7 — First clean engine.** `clarity-v7` (vNEXT), built from the spec
([04-spec-plan.md](04-spec-plan.md)), zero gating, validating the ABI as its
second-ever consumer before kernel 1.0 is frozen.

## 6. Hackathon slice

Target: Steps 1–3, with Step 4 or a mixed-engine demo as stretch. Sized for
2–3 days by someone who knows this code well.

**Day 1 — Step 1.** Create `clarity-kernel`, move database/costs/events/
AssetMap, fix imports, re-export from old paths. Success = `cargo test -p
clarity -p stackslib` green with zero source changes outside the moves.
Tedious but low-risk; getting it done first makes everything after it honest
(the ABI gets defined in a crate that genuinely doesn't depend on the VM).

**Day 2 — Steps 2–3.** Write the ABI (the design in §3 plus the
`clarity_wasm.rs` checklist), implement `Engine` for the interpreter, build
the dispatcher, and stand up a small embedder binary that deploys and calls
contracts purely through `Engine`/`TransactionContext` — no stackslib.

**Day 3 / stretch — one of:**
- *Mixed-engine demo*: register the clar2wasm runtime (from
  `feat/clarity-wasm-develop`) as a second `Engine`, and run one transaction
  where an interpreted contract `contract-call?`s a Wasm-compiled contract
  through the dispatcher. This is the Model B thesis running live, and it's
  the strongest possible validation that the ABI is real.
- *Step 4*: route stackslib through the dispatcher and show the node's test
  suite green over the new boundary.

**Demo narrative** (for an "unexciting" refactor, this lands well):
1. `git diff --stat` — the VM crate no longer contains the runtime; a kernel
   crate exists with a documented ABI.
2. The standalone embedder: ~100 lines, no stacks-core, running real
   contracts — "Clarity is now an embeddable language, not a module of one
   node implementation."
3. If the stretch lands: **one transaction, two engines, one kernel** — an
   interpreted contract calling a Wasm contract mid-transaction. Follow with
   the manifest slide: this same mechanism is how old epochs pin old crate
   versions and how Clarity 7 ships with zero epoch gating.

**Scope traps:**
- Don't start with the `stacks-common`/epoch decoupling (Step 5) — it's the
  most invasive step and blocks nothing structural. Kernel keeping a
  transitional `stacks-common` dependency is fine all week.
- Don't redesign `GlobalContext` — let the legacy engine assemble it from
  `TransactionContext` parts internally, however inelegantly. The clean
  context is vNEXT's job.
- `AssetMap` extraction from `contexts.rs` may drag `Environment` coupling
  with it; if it fights back, leave it for later and note it — database +
  costs + events are the load-bearing moves.
- If the clar2wasm engine fights the ABI on Day 3, that's not failure —
  every mismatch found is exactly the ABI feedback Phase 4 needs. Write them
  down; they're deliverables too.

## 7. Status log

### Step 1, first pass (hackathon day 1) — DONE

`clarity-kernel` exists in the workspace. Moved with all old paths preserved
via re-exports (workspace compiles with zero warnings, no downstream source
changes):

- `vm/events.rs` → `clarity_kernel::events`.
- The pure cost layer → `clarity_kernel::costs`: `execution_cost.rs`,
  `errors.rs`, `constants.rs`, `cost_functions.rs` (`ClarityCostFunction`,
  `CostValues`, `linear`/`logn`/`nlogn`), `costs_1..5`, plus `CostTracker`
  (+ the `()` impl, which the orphan rule forces to travel with the trait),
  `MemoryConsumer`, `runtime_cost`, `analysis_typecheck_cost`,
  `CLARITY_MEMORY_LIMIT`.
- **Seam invented**: the pure cost functions now return a kernel-owned
  `CostFunctionError { Arithmetic(String), NotImplemented }`;
  `clarity` converts it back into the *exact* legacy `VmExecutionError`
  values via `From` (including the historical `Some(vec![])` stack-trace
  quirk on the arithmetic path), so error strings and matching behavior are
  bit-identical.
- **Stayed in `clarity`** (interpreter-coupled, by design):
  `LimitedCostTracker`, `DefaultVersion`, `ClarityCostFunctionReference`
  (cost-contract evaluation runs through the interpreter), and `vm/errors`
  (wraps parser/type-checker error kinds — engine territory).

### Step 1, second pass (hackathon day 2) — error tower + database — DONE

Two more moves, both replay-safe by construction (paths preserved via
re-exports; the few real seams listed below):

**Error tower.** The database layer's pervasive dependency was its error
vocabulary, so it moved first: `vm/diagnostic.rs` → `clarity_kernel::diagnostic`,
`vm/analysis/errors.rs` → `clarity_kernel::errors::analysis`, and
`vm/errors.rs` → `clarity_kernel::errors`. Two pieces stayed engine-side:
`ast/errors.rs` (embeds lexer `Token` types — genuinely parser-shaped) and
`ClarityEvalError` (the one enum wrapping `ParseError`), which remains in
`clarity`'s shim `vm/errors.rs`. Note for the vNEXT ABI: kernel-hosting the
legacy check-error vocabulary is *transitional* — the frozen kernel ABI gets
its own `EngineError` design in Step 2.

**Database.** `vm/database/{clarity_db,clarity_store,key_value_wrapper,sqlite,structures}.rs`
→ `clarity_kernel::database`, including `HeadersDB`/`BurnStateDB` and the
rollback machinery. Four seams, as planned:

1. **`SpecialCaseHandler` is now an opaque token**
   (`&'static (dyn Any + Send + Sync)`). The engine defines the concrete
   `SpecialCaseHandlerFn` newtype (fn-pointer over `GlobalContext`);
   stackslib wraps its PoX handler in a `static SPECIAL_CASE_HANDLER` and the
   interpreter downcasts at the single invocation site. Trap discovered: a
   bare `&fn` *also* coerces to `&dyn Any`, so unwrapped return sites compile
   but fail the downcast at runtime (hard error, not silent) — the
   conformance/test suite covers this path.
2. **The execution cache is an opaque engine slot**:
   `ClarityDatabase.execution_cache: Option<&mut dyn Any>` with
   accessors; `ClarityExecutionCache` (which holds interpreter-shaped
   `Contract`s) stays engine-side and is downcast by the extension trait.
   stackslib's `with_cache(&mut cache)` call sites coerce unchanged.
3. **Contract/analysis-typed methods became `ClarityDatabaseExt`** (in
   `clarity::vm::database`): `get_contract`, `insert_contract`,
   `get_contract_size`, `load_contract_analysis`. Pure-metadata helpers
   (`read_contract_size`, `has_pending_metadata_for_contract`,
   `fetch_metadata`, `insert_metadata`) stayed in the kernel as `pub`.
   Callers outside `clarity` needed only trait imports (4 stackslib files,
   2 pox-locking files).
4. **Foreign impls relocated**: `ClaritySerializable` for
   `ContractContext`/`ContractAnalysis` moved to the clarity shim (orphan
   rule); the `u32` impls moved *into* the kernel (same rule, opposite
   direction). Inherent `as_analysis_db` constructors became a blanket
   `AsAnalysisDb` extension trait.

**War story worth remembering — `cfg!` does not survive crate moves.**
`ClarityDatabase::is_in_regtest()` was `cfg!(test)`: true when the `clarity`
crate compiles under `cfg(test)`, false always in dependents (dependencies
never get `cfg(test)`). Moved verbatim into the kernel, it silently became
*always false* — caught by a single failing test out of 10,762
(`test_is_mainnet`). A feature-flag translation would have been wrong in the
other direction (stackslib test builds enable `clarity/testing`, flipping
behavior there). The faithful fix: the method moved to the
`ClarityDatabaseExt` trait so `cfg!(test)` keeps evaluating in the `clarity`
crate. Generalized lesson for the remaining steps: audit every `cfg!`/
`#[cfg]` in moved code for *which crate's* compilation context it was
implicitly reading, and prefer test coverage over inspection for these —
this one compiled cleanly in every configuration.

### Steps 2–3 first pass (hackathon day 3) — engine ABI + legacy wrap + embedder — DONE

- **`AssetMap` moved to `clarity_kernel::assets`** (the last transaction-
  scoped state above the kernel): pure data over kernel types, extracted
  from `contexts.rs` with path-preserving re-exports.
- **The v0 engine ABI exists** (`clarity_kernel::engine`): the `Engine`
  trait (`deploy_contract` / `execute_call` / `eval_read_only`), a concrete
  `TransactionContext` carrying the owned `ClarityDatabase` (explicit
  `take_db`/`restore_db` hand-off, since the legacy `GlobalContext` owns its
  database by value), `DeployOutcome`/`ExecutionOutcome` (value + `AssetMap`
  + events), and `EngineError` (parse failures cross as `Diagnostic`s —
  lexer/parser error types stay engine-internal). `ContractDispatcher` is
  defined as part of the ABI but not yet wired.
- **`LegacyEngine`** (`clarity::vm::engine`): the interpreter behind the
  ABI, assembling an `OwnedEnvironment` from context parts per interaction.
- **The standalone embedder runs** (`clarity/examples/embedder.rs`,
  `cargo run -p clarity --example embedder`): deploys and calls a contract
  purely through `dyn Engine` and kernel types — no stackslib, no MARF.
  This is the "Clarity is an embeddable language" proof artifact.

v0 caveats, documented in the ABI rustdoc, in dependency order: analysis is
not persisted at deploy (needs the `ContractAnalysis` stored/working split);
costs are metered free per-call (needs the shared kernel cost-budget
handle); `contract-call?` stays engine-internal (dispatcher wiring is the
mixed-engine milestone); `TransactionContext` still carries `StacksEpochId`
(epoch inversion is Step 5). These four items are the natural next passes,
and each is now a *small, local* change to a defined interface rather than
an excavation.

### ABI v0.5 (hackathon day 3, cont.) — metered costs + real deploys — DONE

The first two v0 caveats are resolved:

- **Cost budgets are real.** `TransactionContext` gained
  `CostBudget::{Free, Limited(ExecutionCost)}` (`with_budget`) and an
  engine-state slot; outcomes report cumulative consumed cost. The legacy
  engine builds a `LimitedCostTracker` from the budget on first use, parks
  it in the context between interactions, and charges parse, analysis, and
  evaluation against it — so one budget spans a whole transaction, exactly
  like node-side accounting. (A kernel-*typed* tracker handle — one budget
  spanning *different* engines — remains future work and is what the
  `LimitedCostTracker`-in-`Any`-slot design points toward.)
- **Deploys run the full pipeline.** `LegacyEngine::deploy_contract` now
  parses, runs static analysis *persisted to the metadata store*, and only
  then evaluates — trait-using contracts work through the ABI, and
  ill-typed contracts are rejected with `EngineError::Static` before any
  evaluation. Enabled by two additive kernel APIs:
  `RollbackWrapper::into_store` and
  `ClarityDatabase::{get_headers_db, get_burn_state_db}`, which let the
  engine take the database apart (analysis wraps the bare store) and
  reassemble it.
- **The ABI has its own test suite** (`clarity/src/vm/engine.rs::tests`):
  metered deploy/call/read flow, analysis persistence, budget exhaustion
  (context stays usable), static rejection, parse diagnostics.
- Discovered en route: `LimitedCostTracker::new` on a fresh store requires
  the stored Clarity epoch to be ≥ 4.0 (cost functions become Rust-native
  boot defaults there; earlier epochs try to load deployed cost contracts).
  The embedder sets the epoch in the store first — hosts without boot
  contracts should do the same.

### Stored-interface format (hackathon day 4) — kernel-owned — DONE

The third v0 caveat is resolved: the kernel now owns the format through
which engines see each other's contracts.

- **`FunctionType` vocabulary moved to `clarity_kernel::signatures`**
  (`FunctionType`, `FixedFunction`, `FunctionArg`, `FunctionSignature`,
  arg/return signature enums, plus their data-adjacent methods like
  `canonicalize`). These types are serialized inside the stored analysis, so
  their serde shape is kernel-owned. The *checking rules* stayed engine-side:
  the three `impl FunctionType` blocks in the type checkers became extension
  traits (`FunctionTypeExt` / `FunctionTypeExtV21` / `FunctionTypeExtV205`),
  following the `TypeSignatureExt` precedent already in the codebase. The
  type-repr parser (`TypeSignatureExt`) also stayed engine-side — it depends
  on v2.1 checker constants and cost metering.
- **`ContractInterface` (the JSON ABI types) moved to
  `clarity_kernel::contract_interface`**; `build_contract_interface` (which
  consumes the engine's analysis) stayed.
- **`clarity_kernel::analysis::StoredContractAnalysis`** is the stored
  record: a serde-exact mirror of the legacy `ContractAnalysis`'s
  serialized subset (same fields, same order — the file documents the
  never-change contract). The legacy engine converts at the storage
  boundary (`to_stored`/`from_stored`); its working state (`type_map`,
  `cost_track`, `expressions`) never touches the kernel.
  `StoredContractAnalysis::load` gives any engine (or host) engine-agnostic
  read access to a deployed contract's interface.
- **Byte-identity is enforced by test** (`stored_format_is_byte_identical`):
  direct serde of the legacy analysis vs. the stored route must be equal,
  over a contract exercising functions, maps, variables, both token kinds,
  traits, and a built interface; plus a lossless round-trip check.

The remaining v0 caveat at this point was `ContractDispatcher` wiring (the
mixed-engine milestone). Phase C, part 4 below resolves it against the host
manifest before a second engine is added, making the first Clarity 7 engine a
new manifest target instead of requiring another transaction-state refactor.

### Step 4 phase A (post-hackathon) — ABI v1: production semantics — DONE

The prerequisite for routing stackslib through the ABI: the `Engine` trait
now expresses the node's real transaction flow, modeled directly on the
battle-tested `TransactionConnection` surface.

- **Abort callbacks** (`AbortCallback = &mut dyn FnMut(&AssetMap, &mut
  ClarityDatabase) -> Option<String>`): after a successful execution, the
  host inspects asset movements *before commit* — this is how Stacks
  post-conditions work. The legacy engine implements it by holding an outer
  rollback layer open across the interaction. Rejection surfaces as
  `EngineError::AbortedByCallback` carrying output/assets/events for
  receipt-building, exactly mirroring `ClarityError::AbortedByCallback`.
- **The deploy pipeline is phased like production**: `analyze_contract`
  (parse + checks, nothing persisted; returns the stored-interface record;
  parks AST + working analysis in the engine-state slot) →
  `initialize_contract` (consumes the parked AST; abort hook before commit)
  → `save_analysis` (persists the parked analysis) — same phases, same
  order as `process_transaction`'s smart-contract path. `deploy_contract`
  remains as a provided convenience method composing the three.
- **`ResourceBudget` moved to the kernel** (`clarity_kernel::resource_limiter`,
  std + alloc-tracker only) and is threaded through analyze/initialize/
  execute — hosts pass real wall-clock/allocation budgets on
  block-assembly/validation paths and `unlimited()` on replay/commit.
- The engine's inter-interaction state consolidated into one `EngineState`
  (cost tracker + pending deploy) in the context slot.
- New ABI tests: abort-rollback (call succeeds, host rejects, state
  restored), phased deploy, aborted-initialize-persists-nothing,
  save-without-analyze errors.

### Step 4 phase B, part 1 — shaping the ABI to the host — DONE

Scouting `ClarityTransactionConnection` before writing any re-route code
turned up two blockers, both now fixed. Neither was visible from the ABI
side; both came from how the *host* actually holds state.

**Blocker 1 — a latent correctness bug (fixed).** The connection does not
hold a live `ClarityDatabase`: it holds a **persisted rollback log** with an
open block-level savepoint (`commit()` asserts `depth() == 1`), and
reconstitutes a database from it per interaction. Our `analyze_contract` /
`save_analysis` swapped `ClarityDatabase` for `AnalysisDatabase` via
`db.destroy().into_store()` — dropping to the *bare backing store*, which
discards the rollback wrapper and every uncommitted edit with it. Harmless
for the embedder (committed store, no open layer), silently destructive for
a real block connection. Both phases now hand the `RollbackWrapper` across
(`AnalysisDatabase::new_with_rollback_wrapper` → `destroy()` →
`ClarityDatabase::new_with_rollback_wrapper`). Regression test:
`analysis_preserves_uncommitted_rollback_state` — verified to fail before
the fix and pass after.

**Blocker 2 — deploy-phase state must be host-held (ABI revised).** The node
does not keep one long-lived object across the deploy phases: the *caller*
(`process_transaction`) holds the `ContractAST` and `ContractAnalysis`
between `analyze_smart_contract`, `initialize_smart_contract`, and
`save_analysis`, and passes them back in. The connection cannot hold a
`TransactionContext` across those calls either — the context borrows the
store, which the connection owns as `&mut`. So context-parked pending-deploy
state was the wrong model. `analyze_contract` now returns an
**`AnalyzedContract`** handle: kernel-format `interface` on the outside, the
producing engine's private payload (the legacy engine's AST + working
analysis) opaque inside, rejected with a clear error if handed to a
different engine. `initialize_contract`/`save_analysis` take it by
reference. This matches the host's real shape *and* is a cleaner ABI —
phases compose without hidden state, and the signatures shrank.

**Also added**: `LegacyEngine::install_cost_tracker`/`take_cost_tracker`, so
a host can thread its own longer-lived tracker (a block's budget, borrowed
by the connection as `&mut Option<LimitedCostTracker>`) instead of the
engine building one per context from `CostBudget`.

### Step 4 phase B, part 2 — contract calls routed through the ABI — DONE

`ClarityTransactionConnection::run_contract_call` now executes through
`Engine::execute_call` instead of the trait's `with_abort_callback` default.
**No call sites changed** (all 48 of them): the method's signature was
already entirely kernel types — `&[Value]` in, `(Value, AssetMap,
Vec<StacksTransactionEvent>)` out — so only the body moved. This is the
highest-traffic Clarity path in the node (every contract call in every
block).

Mechanics, in `with_engine`: rebuild the `ClarityDatabase` from the
persisted rollback log with the per-tx cache attached, wrap it in a
`TransactionContext`, lend the block's `LimitedCostTracker` via
`install_cost_tracker`, call the engine, then recover tracker and database
and tear the database back down to a log — the same take/replace discipline
(and `using!` panic-safety) as the method it replaces. Memory reset stays in
the connection's `commit()`/`Drop`, untouched. `engine_error_to_clarity`
routes `EngineError::Execution` through `ClarityError::from`, which is what
preserves the cost-budget and resource-budget classifications block
processing depends on.

One deliberate ABI tweak: `execute_call` takes the function name as `&str`
rather than `&ClarityName`, matching the VM's own `execute_transaction` and
avoiding a fallible conversion plus a per-call regex on the hot path.

### Step 4 phase B, part 3 — deploy initialization and persistence routed — DONE; REPLAY GATE

The state-changing deploy phases now cross the ABI. After analysis succeeds,
the production smart-contract transaction path wraps the legacy
`ContractAST` + `ContractAnalysis` in one immutable `AnalyzedContract`, calls
`Engine::initialize_contract`, then calls `Engine::save_analysis`. The same
`with_engine` bridge used by contract calls preserves the persisted rollback
log, transaction cache, block cost tracker, execution resource budget, and
post-condition abort callback.

`AnalyzedContract` now binds its source as well as its stored interface and
opaque engine payload. Its fields are private, identity and language version
come directly from the stored interface, and initialization no longer accepts
a second source string. This makes it impossible for a host to analyze one
source/identity/version and accidentally initialize another. A transitional
`LegacyEngine::from_legacy_parts` bridge lets the production caller enter the
opaque ABI after successful legacy analysis; the handle is consumed afterward
to recover the receipt's legacy `ContractAnalysis`.

**Deliberate exception: analysis itself still enters through
`TransactionConnection::analyze_smart_contract`.** The block-processing code
inspects the legacy parser and static-check error variants to decide whether a
failure is rejectable in a given epoch. `EngineError::Parse` intentionally
exposes engine-neutral diagnostics, which cannot reconstruct that consensus
classification. Routing analysis before the ABI carries equivalent structured
rejectability data would silently change invalid-block behavior. Keeping this
small bridge preserves consensus semantics while still putting both mutating
deploy phases behind the new boundary.

Regression coverage now includes successful deploy + call consensus tests,
analysis/syntax failures, top-level runtime failures, and a production-path
post-condition rejection that verifies the contract and asset transfer both
roll back while receipt analysis remains available. The stored-interface
loader was also hardened to treat only `NoSuchContract` as absence; storage
and corruption failures are no longer swallowed as `None`.

**Replay checkpoint:** phase B's contract-call path and both state-changing
deploy phases are now routed. This is the point at which the 5–6 hour mainnet
block replay is worth running. A bit-identical replay remains the merge gate.
`stx-transfer` transactions, `run_poison_microblock`, and the block-connection
lifecycle deliberately stay off the ABI (no contract involved); whether they
should get host-level ABI equivalents is a separate design question.

### Step 4 phase B replay — DONE

The full mainnet block replay completed successfully against commit
`ef8aa6b14d` (`refactor: route calls and deploys through engine ABI`) on
2026-08-08: every mainnet block executed without divergence. This validates
the production contract-call path and both mutating deploy phases over the
complete historical epoch/version matrix.

### Step 4 phase C, part 1 — host engine manifest — DONE

`stackslib::clarity_vm::engine::ClarityEngineManifest` now owns the explicit
two-dimensional selection rule:

```text
(current execution epoch, contract Clarity version) -> engine revision
```

Top-level contract calls resolve the deployed contract's stored language
version; deploy initialization and persistence use the immutable analyzed
handle's version. At this checkpoint all valid cells selected `LegacyV1`,
preserving the replay-proven behavior while establishing the insertion point
for another engine revision. Part 6 below supersedes that initial mapping for
Clarity 6. The manifest rejects Clarity before epoch 2.0 and language
versions newer than an epoch permits, and tests cover every historical
epoch/version combination. The transitional `LegacyV1` selection deliberately
spans epochs 4.0 and 4.1 even though shared serialization behavior changed at
4.1: unlike future gate-free engines, the frozen legacy engine retains its
historical epoch gates internally. The 4.1 strict typed-tuple deserialization
change belongs to the separate kernel-ruleset inventory because it lives in
the shared value/serialization layer, not a language evaluator.

The manifest made the next blocker concrete: its selected-engine adapter
still installed and recovered a legacy `LimitedCostTracker` through the
transaction context's opaque engine-state storage. That blocker is addressed
in phase C, part 2 below.

### Step 4 phase C, part 2 — kernel-owned cumulative cost handle — DONE

`CostTrackerHandle` is now a kernel-owned, type-erased wrapper around the
transaction's concrete cost schedule. `TransactionContext` owns the handle;
engines take it together with the database for one interaction and must
restore both on every return path. The legacy tracker can still contain
interpreter-shaped historical cost contracts, preserving cost-voting replay,
without making either the kernel or future engines depend on its type.

`GlobalContext` now executes against this shared handle, including temporary
free execution for historical contract-call short circuits and PoX event
synthesis. Compatibility constructors and destructors still accept and return
`LimitedCostTracker`, so the existing node/embedder APIs remain unchanged.
stackslib installs and recovers its block-wide tracker directly through the
kernel context; the epoch manifest no longer contains legacy-specific cost
adapters. A kernel test verifies that metering and concrete tracker state
survive type erasure and recovery, while the existing engine ABI tests verify
that cumulative production-style metering is unchanged.

The next blocker is the rest of the live nested-call frame. During evaluation,
the database, asset/event stacks, read-only/rollback depth, caller authority,
and call stack are still assembled inside the legacy `GlobalContext`. These
must become a reborrowable kernel runtime frame before `ContractDispatcher`
can suspend one engine, select another through the manifest, and execute the
callee over the same transaction state.

### Step 4 phase C, part 3 — kernel transaction frame — DONE

The in-memory rollback state now lives in
`clarity_kernel::transaction::TransactionFrame`: nested asset maps, event
batches and their cumulative size limit, and inherited read-only state.
`CallStack` moved alongside it because `FunctionIdentifier` was already a
kernel type; recursion detection, function depth, expression/apply depth, and
developer stack traces therefore no longer require a legacy-engine type.

The legacy `GlobalContext` delegates begin/commit/rollback and event insertion
to the kernel frame while retaining database savepoint orchestration. Its
compatibility constructors still build a fresh frame, but ABI execution takes
the existing frame and call stack out of `TransactionContext`, executes, and
restores them on every success, abort, and error path. PoX handlers now append
events through the frame instead of reaching into a legacy `event_batches`
field.

The next step is a borrowed kernel runtime view over the database, cost handle,
transaction frame, and call stack. That view is what `ContractDispatcher`
must receive at a nested `contract-call?`; it allows the host to select the
callee engine without moving or rebuilding the outer engine's live state.

### Step 4 phase C, part 4 — nested engine dispatch — DONE

`clarity_kernel::engine::RuntimeContext` is now the borrowed view over the
active database, cumulative cost handle, transaction frame, call stack, and
execution resource-limit baseline. Its `RuntimeSlot`s allow the outer engine
to suspend those owned components, run the selected engine through an ordinary
`TransactionContext`, and restore every component before resuming. The nested
engine entry point receives sender, caller, and sponsor separately, preserving
`tx-sender`, `contract-caller`, and sponsorship across engine boundaries.

Production `ClarityTransactionConnection`s install a
`ClarityEngineDispatcher`. At every nested `contract-call?`, it reads the
callee's stored Clarity version and applies the same `(current epoch, contract
version) -> engine revision` manifest as a top-level call. The selected engine
then runs over the already-open rollback frame; no new host transaction or
post-condition boundary is introduced. Historical free-cost short circuits
carry the temporary free tracker through the same route. Standalone legacy
embedders that do not install a dispatcher retain the direct interpreter path.

The routed-path test crosses the dispatcher and verifies shared state writes,
events, caller authority, rollback depth, and cumulative metering. The
production transaction suite covers success, runtime error, sponsored calls,
post-condition aborts, traits, and PoX over the installed dispatcher.

This is a full-replay checkpoint: nested calls now exercise the manifest and
engine ABI on every production contract-call path. At this checkpoint, the
remaining seam was stored executable contract data:
`ClarityDatabase` still returned the legacy interpreter's
`ContractContext`/`DefinedFunction`. Part 5 below addresses that seam.

The full replay against `2cef753fe7` was started on 2026-08-08. The storage
work below proceeds on the assumption that it will preserve the already
established replay parity; record the result here when the run finishes.

### Step 4 phase C, part 5 — opaque executable contract storage — DONE

`clarity-kernel::database::ContractArtifact` is now the kernel's executable
contract storage boundary. It is deliberately only an opaque textual payload:
the selected engine owns its encoding and decoding. The kernel persists it
under the historical `contract` metadata key without adding a wrapper or
normalizing its contents, so it can hold both the legacy interpreter JSON and
a future Clarity 7 representation.

The legacy `ClarityDatabaseExt` adapter still exposes `Contract` to legacy
interpreter code, but now serializes and deserializes that value on its side of
the artifact boundary. A byte-identity test guards that this adapter writes
exactly the historical `ContractContextWrapper` JSON. A kernel test separately
guards that an arbitrary future-engine payload round-trips byte-for-byte.

Nested host dispatch no longer loads the executable artifact to discover the
callee's version. It loads the engine-neutral `StoredContractAnalysis`, selects
the engine from the epoch/version manifest, and leaves artifact decoding to
that engine. Analysis-less contracts created by legacy deployment helpers
fall back directly to `LegacyV1`; future engines must persist analysis to be
selectable. Consequently, a future Clarity 7 engine does not need to expose
its executable object model to the kernel, stackslib, or the legacy crate.

This resolves the last representation blocker identified below and makes it
possible to extract an existing, replayable language version as the ABI's
second engine.

### Step 4 phase C, part 6 — replayable Clarity 6 engine revision — DONE

`clarity-v6` now exists as a separately linkable workspace crate and is the
second consumer of the kernel `Engine` ABI. The manifest maps Clarity 6 to
`EngineRevision::Clarity6V1` in epochs 4.0 and 4.1; Clarity 1–5 remain on
`LegacyV1`, and Clarity 6 remains unavailable before epoch 4.0. Consequently,
real mainnet Clarity 6 deployments, top-level calls, and nested calls now
exercise the new engine boundary.

At this checkpoint, revision 1 was intentionally a behavior-parity bootstrap.
It delegated evaluation to the legacy interpreter while wrapping the
interpreter's analyzed handle in a Clarity-6-owned opaque payload. The
production deploy
path uses the selected engine's wrapper after successful legacy analysis and
recovers the legacy working analysis only when constructing the receipt. The
legacy engine cannot initialize the wrapped handle directly, and the host
never observes its private representation.

Clarity 6 pins engine-local semantics to the epoch-4.0 baseline. The known
epoch-4.1 strict typed-tuple deserialization change remains a kernel ruleset
choice in `clarity-types`; both epochs therefore select the same
`Clarity6V1`, while the shared kernel applies the current execution epoch's
serialization rule. No combined language/epoch version is required.

Tests compare deploy, public call, state mutation, event/asset output, and
read-only results against the legacy Clarity 6 path in both epochs 4.0 and
4.1. The production transaction matrix additionally drives actual Clarity 6
deploys and calls through stackslib. This is now a safe seam for incremental
de-gating: move or reimplement one semantic subsystem at a time inside
`clarity-v6`, replace the corresponding delegated operation, and validate it
against both targeted parity tests and mainnet replay. Until all runtime
semantics are owned by `clarity-v6`, its dependency on `clarity` is explicitly
transitional.

### Step 4 phase C, part 7 — Clarity 6-owned engine runtime — DONE

`clarity-v6` no longer delegates any production ABI operation to
`LegacyEngine`. It now owns the engine-side transaction lifecycle directly:
cost-tracker acquisition and restoration, database and shared-frame handoff,
outer rollback/commit, host abort callbacks, parser and analyzer invocation,
its parsed/analyzed contract payload, initialization, top-level and nested
calls, read-only evaluation, and analysis persistence. `LegacyEngine` appears
in the crate only as the differential-test oracle.

This extraction identified one remaining ABI leak: nested environment teardown
was crate-private to `clarity`. It is now public so any external engine can
return the database, cumulative tracker, transaction frame, and call stack to
a suspended caller without requiring the nested savepoint stack to be empty.

The dependency cleanup and production-analysis migration described at this
checkpoint were completed in part 8.

### Step 4 phase C, part 8 — independent Clarity 6 interpreter — DONE

`clarity-v6` now owns its parser, AST passes, analyzer, type checker, evaluator,
native functions, runtime contexts, database adapter, and cost implementation.
It has no normal dependency on the legacy `clarity` crate; that crate is a
dev-dependency only, used as the differential-test oracle.

The fork is a single semantic point rather than a historical interpreter:
Clarity 6 native lookup, parser v2, type checker 2.1, Costs 5, and all
post-Epoch-4.0 interpreter fixes are selected directly. The parser v1 and
pre-2.1 type checker sources were not retained. Historical language-version
and engine-owned epoch dispatches have been collapsed to their Clarity 6 /
Epoch 4.0 result.

The live epoch still crosses the ABI where consensus-shared values require it.
In particular, type admission, value sanitization/deserialization, transaction
frame commit, asset-map merging, and stored-analysis access use the kernel
epoch/ruleset input. This is intentional: Epoch 4.1's exact typed-tuple rule is
a shared value-format rule, not a new interpreter revision. Epochs 4.0 and 4.1
therefore both select `Clarity6V1`; no language-version-by-epoch crate matrix is
needed.

Production Clarity 6 deployment analysis now runs through the selected engine
ABI as well as initialization and calls. Parser failures carry both diagnostics
and their consensus rejection classification across the ABI; parser cost
exhaustion retains the legacy block-cost-overflow classification. Receipts
store the kernel-owned `StoredContractAnalysis`, so stackslib does not depend
on an engine's working analysis representation. The kernel cost-tracker handle
is shared directly during analysis, avoiding a cross-crate downcast to either
interpreter's concrete tracker type.

The retained focused differential tests cover Epoch 4.0 and the Epoch 4.1
kernel rule. Stackslib transaction tests cover real Clarity 6 deployment and
execution through the dispatcher. A mainnet replay remains the final
consensus-parity validation for this source-level extraction.

### Step 4 phase C, part 9 — Clarity 6 conformance scenarios — DONE

The Clarity 6 crate now runs engine-ABI-only differential scenarios against
the frozen legacy Clarity 6 implementation in both Epoch 4.0 and Epoch 4.1.
The scenarios compare stored analysis interfaces, diagnostics and rejection
classification, cumulative costs, returned values, state, FT asset maps,
events, host aborts, runtime failures, and rollback results. This is the first
step toward a standalone conformance-vector format rather than copying the
legacy interpreter's internal unit-test suite.

Stackslib also exercises nested calls across the engine boundary in both
directions (`Clarity5 -> Clarity6` and `Clarity6 -> Clarity5`) and verifies
that a write performed by the inner engine rolls back when the outer engine
fails. The harness explicitly installs the host-owned cumulative tracker, as
production does; legacy analysis still requires its concrete tracker behind
the kernel handle at this checkpoint. Part 11 removes that final downcast.

### Step 4 phase C, part 10 — serialized vectors and generated coverage — DONE

`clarity-conformance` is now an engine-neutral test-support crate built only on
the kernel ABI. Its versioned JSON schema describes analysis, initialization,
analysis persistence, calls, read-only evaluation, host aborts, and their exact
observations. Stored interfaces are pinned by canonical JSON SHA-256; costs,
diagnostics, rejection classification, returned values, asset maps, events, and
errors remain reviewable in the file. Call arguments use consensus-serialized
hex instead of Rust serde, preserving the entire Clarity value domain including
`u128` and compound values.

The checked-in `clarity6-v1.json` corpus covers Epochs 4.0 and 4.1 and runs
directly against `Clarity6Engine` without consulting an oracle in the runner.
A separate test verifies the same goldens against the frozen legacy Clarity 6
implementation, and an explicit ignored recorder is the only path that
refreshes them. Golden changes are therefore visible consensus diffs, not
expectations silently computed by the implementation under test.

A fixed-seed generated test round-trips generated cases through the serialized
schema and checks a stateful contract against a small Rust model across both
epochs. A standalone `cargo-fuzz` target feeds arbitrary UTF-8 source through
Clarity 6 parsing, analysis, diagnostic normalization, and cost restoration,
again without a legacy-engine dependency. This gives future engines three
layers: reviewable historical goldens, cheap deterministic generation in CI,
and unbounded fuzz exploration outside CI.

### Step 5, part 1 — engine-neutral analysis metering — DONE

Legacy analysis working state and both historical type checkers now carry the
kernel-owned `CostTrackerHandle`, matching the independent Clarity 6 analyzer.
Parsing, every analysis pass, success and error recovery, and cumulative cost
accounting operate through the kernel traits without downcasting to either
engine's `LimitedCostTracker`. The concrete tracker and its historical cost
schedule remain unchanged inside the handle.

The direct legacy `TransactionConnection` compatibility path still recovers
its own tracker at its outer host boundary, where the concrete type is part of
that pre-ABI API. The engine ABI itself is now neutral: a transaction can run
Clarity 6 analysis first and then legacy analysis, or the reverse, without a
host preinstalling the legacy tracker. Mixed-engine tests exercise both orders;
the full legacy analysis matrix continues to cover every historical epoch and
language-version pairing.

Making analysis working state uniquely own the shared handle also removed
`Clone` from the legacy analysis and the tooling result wrappers that contain
it. No repository caller cloned these values; duplicating a live cumulative
meter would be semantically invalid in any case.

### Step 5, part 2 — explicit kernel rulesets — DONE

`clarity-kernel` now owns the append-only `KernelRuleset` identifier. Its four
historical profiles encode the cumulative shared transitions relevant to the
current boundary: value sanitization, the epoch 3.4 `at-block` shutdown, and
epoch 4.1 exact typed-tuple decoding. `TransactionContext` carries both this
ruleset and, transitionally, `StacksEpochId`: the ruleset governs shared
behavior, while the full epoch remains available to the frozen legacy engine's
unmigrated language and cost gates.

The production epoch-to-ruleset map lives in stackslib beside the engine
manifest. It maps every historical epoch explicitly. Epochs 4.0 and 4.1 still
select the same `Clarity6V1` engine revision but select `KernelRuleset::V3` and
`V4` respectively, proving that no combined epoch/language engine version is
required.

The first consumers have been inverted. Legacy `at-block` analysis and runtime
availability consult the host-selected ruleset instead of comparing epochs.
Both engines' `from-consensus-buff?` paths and the shared database value path
use ruleset-selected serialization, including write sanitization and strict
typed-tuple reads. Epoch-aware serialization and environment constructors
remain as pre-ABI compatibility adapters; production ABI execution installs
the explicit ruleset on the database and preserves it across nested engine
calls and database reconstruction.

Regression tests deliberately mismatch epoch and ruleset to demonstrate that
these migrated behaviors follow only the ruleset. Separate tests exhaustively
cover the host map and confirm that mixed-engine nested calls retain the same
ruleset. The next inversion batches can now migrate additional genuinely
shared gates one at a time without expanding the engine revision matrix.

### Step 5, part 3 — host-owned language availability — DONE

The epoch-to-default-language table now lives beside the engine manifest in
stackslib. It exhaustively maps every protocol epoch and represents Epoch 1.0
as `None`, so availability validation and engine selection use one host-owned
policy. Transaction validation, relay checks, block checks, node tests, and
the bundled command-line tools all consume that mapping.

`clarity-types::ClarityVersion` is once again only a language identity: it no
longer imports `StacksEpochId` or exposes `default_for_epoch`. The frozen
legacy interpreter retains a private copy solely for its pre-ABI standalone
environment helpers and historical gate-consistency tests. The independently
linked Clarity 6 interpreter does not retain that compatibility mapping; its
test-only top-level constructor pins `Clarity6` directly.

This intentionally leaves the full epoch in `TransactionContext` for the next
inversion slices. Its remaining Clarity 6 consumers are stored-analysis/type
canonicalization and host error classification, plus the legacy-shaped
`GlobalContext`/transaction framing. Those are transitional kernel/host
inputs, not language-version selection. They should be replaced by narrow
ruleset or host-policy values one subsystem at a time, with differential
vectors and replay at each consensus-sensitive cut.

### Step 5, part 4 — pinned Clarity 6 cost profile — DONE

The Clarity 6 fallback meter is now a direct Costs-5 implementation. The
copied historical machinery for Costs 1–4 selection, cost-voting state,
on-chain cost-function evaluation, voted contract-call circuit overrides, and
the tracker's stored execution epoch has been deleted. Limited construction no
longer reads or mutates `ClarityDatabase`; it builds the one Rust cost table
that defines the Clarity 6 / Epoch 4.0 baseline.

Production behavior remains host-owned: stackslib creates the cumulative block
tracker for the current protocol epoch and lends that erased handle through
`TransactionContext`, so all engines in a transaction charge one meter. The
Clarity 6 tracker exists for standalone ABI hosts and tests when no tracker is
installed. A regression constructs it over deliberately different database
epochs and proves identical costs and an untouched rollback stack; the
existing Epoch 4.0/4.1 differential and serialized conformance suites continue
to compare exact cumulative costs against the frozen legacy engine.

The legacy tracker is intentionally unchanged. It still selects historical
cost contracts and cost-voting behavior by epoch because replay of Clarity
1–5 requires those profiles. Future clean engines should follow Clarity 6:
one engine revision owns one cost implementation, while the host supplies the
single cumulative budget shared across cross-engine calls.

### Step 5, part 5 — pinned Clarity 6 parser and analyzer profile — DONE

Clarity 6 now names its one engine-local semantic point explicitly as
`CLARITY6_BASELINE_EPOCH` (Epoch 4.0). Production parser entry points no longer
accept a language version or execution epoch: they always use the Clarity 6
grammar, AST passes, and depth limits. Parser rejection classification is also
revision-owned; the pre-Epoch-3.4 depth-error branch was deleted rather than
being reachable through a mismatched host context.

The analyzer makes the same separation. Its production pipeline no longer
accepts a language version, and its read-only, type, and trait passes run under
the fixed baseline profile even when a direct embedder supplies a different
host epoch. The host epoch is still written into
`StoredContractAnalysis` and its nested `ContractInterface`, however. Those
fields are part of the historical serialized record, so removing or rewriting
them would change receipt/metadata bytes even though they no longer select
Clarity 6 semantics. Naming the analysis argument `recorded_epoch` makes that
role visible at the boundary.

Regression tests deliberately analyze under host epochs older and newer than
the Clarity 6 baseline. After normalizing only the two recorded epoch fields,
the complete stored interfaces are identical. A separate over-depth parse test
proves that rejection policy follows the engine revision rather than the host
epoch. The remaining full-epoch inputs in Clarity 6 are now confined to this
recorded metadata and the legacy-shaped runtime/database frame; the latter is
resolved in part 6 below.

### Step 5, part 6 — semantic runtime profile vs. host routing epoch — DONE

The copied interpreter frame no longer treats the current block epoch as its
semantic epoch. `GlobalContext` now carries two deliberately different values:
`semantic_epoch`, always the Clarity 6 / Epoch 4.0 baseline, and `host_epoch`,
the actual block epoch. All copied runtime helpers—including type admission,
list/value construction, database type checks, stacking asset-map accumulation,
and transaction-frame merges—see only `semantic_epoch`. Every normal and
compatibility environment constructor pins it; a direct embedder cannot select
an older Clarity semantic profile by supplying an old host epoch.

`host_epoch` has one job: nested engine dispatch places it in the kernel
`RuntimeContext`, so a Clarity 6 caller entering a frozen legacy callee gives
that callee the actual current epoch. Kernel rules remain a separate explicit
input. This preserves the three identities at the boundary: engine revision,
kernel ruleset, and host routing epoch.

Regression coverage deliberately runs the same deploy, public call, state
read, asset/event observation, and cost accounting under host Epochs 2.0 and
4.1 while holding the kernel ruleset constant; the complete runtime outcomes
are identical. A structural regression additionally proves the environment
retains the mismatched host epoch for dispatch while exposing only the fixed
baseline to interpreter semantics.

`StacksEpochId` still appears inside copied helper signatures because
`clarity-types` and the interpreter APIs historically use an epoch-shaped
parameter to choose their post-2.1 algorithms. It is now a constant engine
profile rather than live host state. The next cleanup can specialize those
helpers for Clarity 6 without changing the host ABI. Part 7 first removes the
stateful representation entirely.

### Step 5, part 7 — synthetic runtime epoch removed — DONE

`GlobalContext::semantic_epoch` and `ExecutionState::epoch()` have been
deleted. Runtime code can no longer obtain an epoch-shaped semantic selector
from mutable transaction state. Every remaining copied call into a historical
type/value/database API supplies the crate's compile-time
`CLARITY6_BASELINE_EPOCH` directly, including contract-call argument
sanitization, NFT and data-map persistence, sequence construction, function
argument admission, post-condition allowance checks, and asset-map merging.

This is an intermediate source-compatibility layer, not a new behavior model:
the shared APIs still accept an epoch because the frozen legacy engine uses
the same `clarity-types` and kernel database interfaces. The important
invariant is now structural: the only live block epoch inside a Clarity 6
environment is `host_epoch`, and its sole consumer is the kernel nested-call
`RuntimeContext`. The next batch can put thin Clarity 6-specific adapters over
the remaining epoch-shaped shared helpers, reducing the visible constant
plumbing without modifying the legacy engine or shared ABI.

### Step 5, part 8 — epoch-free Clarity 6 service adapters — DONE

The Clarity 6 evaluator now consumes revision-owned adapters for every shared
service whose compatibility API still has an epoch-shaped parameter: type
admission and canonicalization, value sanitization and list construction,
sequence operations, database values and NFTs, asset-map stacking, and
transaction-frame commits. The adapters pin the Clarity 6 baseline in one
place. Evaluator modules cannot select a historical type/value algorithm and
no longer contain `CLARITY6_BASELINE_EPOCH` plumbing.

This remains a thin specialization rather than a fork of shared state. The
legacy engine continues to call the same kernel and `clarity-types` entry
points with its live historical epoch. Clarity 6 calls them through an
epoch-free surface. The database kernel was tightened at the same seam: APIs
that accept an explicit epoch now use that input consistently for both type
admission and serialization instead of silently consulting the epoch stored in
the database for one half of the operation. A regression test deliberately
pairs an Epoch 2.0 database with an Epoch 4.0 admission input and proves the
explicit engine profile wins.

The sequence evaluator also dropped its unreachable pre-Clarity-6 `map` and
binary `concat` implementations. This is the intended duplication policy in
practice: historical alternatives remain untouched in the frozen legacy
engine, while a clean revision contains only the algorithm it can execute.

The only live block epoch retained by the Clarity 6 runtime is still
`host_epoch`, used exclusively when nested dispatch selects the callee engine.
Static analysis retains `recorded_epoch` only for byte-compatible persisted
metadata. Kernel ruleset selection remains host-owned and independent from
both values. No combined language-version-by-epoch crate is introduced.

### Database move — discovered entanglements and seam plan (pre-move notes)

The `vm/database` move is *not* pure file motion. Found while scouting:

1. **Contract storage is interpreter-shaped.**
   `ClarityDatabase::{insert,get}_contract` traffic in
   `Contract { contract_context: ContractContext }`, whose
   `DefinedFunction`s are the interpreter's own representation. **Resolved:**
   option (b) was selected. The kernel stores an opaque `ContractArtifact`,
   while the legacy extension trait owns the `ContractContext` codec. This
   changed only the engine/kernel storage seam and preserved the historical
   serialized bytes.
2. **`ContractAnalysis` is two things wearing one struct.** Its serialized
   form (function/map/trait types, epoch, version) is exactly the
   kernel-owned stored-interface format from §3.3 — kernel-clean. But it
   also carries `#[serde(skip)]` *working state*: `type_map` (type checker)
   and `cost_track: Option<LimitedCostTracker>` (interpreter). Seam: split
   the stored analysis (kernel) from the engine's working wrapper, or
   genericize the skip fields. `AnalysisDatabase` moves with the stored
   half.
3. **`SpecialCaseHandler` leaks `GlobalContext` into the store layer**
   (`clarity_store.rs`: `&'static dyn Fn(&mut GlobalContext, ...)`) — this
   is the pox-locking hook. Its real fix is the `TransactionContext` ABI
   (§3.2); until that exists, the alias should move last or be
   parameterized.
4. **`StacksEpochId` in stored data** (`ContractAnalysis.epoch`, various
   `ClarityDatabase` methods) — accepted transitionally; the kernel keeps a
   `stacks-common` dependency until the Step 5 ruleset inversion.
