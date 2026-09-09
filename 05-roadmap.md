# Roadmap

Phases overlap where noted; the ordering constraint that matters is that
**replay/conformance infrastructure precedes any consensus-adjacent
refactor**, and the **kernel ABI is not frozen until two engines and one
alternative backend have validated it**.

## Phase 0 — Alignment and safety net *(start immediately)*

- Circulate these documents; get explicit buy-in on Model B, the
  legacy-engine freeze, and the "spec vNEXT only" scope — these are the
  decisions everything else builds on.
- **Mainnet replay CI**: full-history replay with bit-identical state roots,
  runnable against any branch. This gates every later step.
- **Legacy anchor vectors**: capture mainnet transaction corpora
  (inputs → values/events/costs) as regression vectors for `clarity-legacy`.
- Inventory the ~589 epoch-gated sites in [clarity/src/](../../clarity/src/)
  and the full `stacks-common` import surface; classify what moves to the
  kernel, what stays engine-internal, and what becomes host interface.

Deliverable: replay CI green on `main`; classification doc; sign-off on goals.

## Phase 1 — Kernel extraction *(the long pole)*

In-place, within the stacks-core workspace, replay-validated per step:

1. Grow `clarity-types` into `clarity-kernel`: move value serialization,
   `ClarityDatabase`/rollback wrapper, cost accounting, events/asset maps.
2. Extract `clarity-primitives` from `stacks-common` (hashes, c32,
   secp256k1/r1); drop the vendored-bitcoin dependency behind the host
   interface.
3. Invert the epoch dependency: kernel-owned ruleset identifier replaces
   `StacksEpochId` inside the VM; stackslib owns the epoch→ruleset map
   (`default_for_epoch` moves out of clarity-types).
4. Replace `HeadersDB`/`BurnStateDB` with the minimal host interface; port
   the pox-locking special-case hook to a generic registration API.
5. Define the `Engine`/`TransactionContext` traits; implement `Engine` for
   the current VM (the legacy-engine wrap); route all stackslib execution
   through the dispatcher.

Exit: zero `stacks-common` deps in clarity crates; all execution flows
through the kernel boundary; replay bit-identical; benchmarks within noise.

## Phase 2 — Repo split and publication

- Move kernel + legacy engine + primitives to a dedicated repo (natural home:
  the `clarity-lang` org) with its own CI, including the replay-anchor vector
  suite.
- Publish to crates.io; stacks-core consumes via crates.io (path overrides
  during development). First release is behaviorally identical to today.
- Coordinate downstream migration: **clar2wasm** (replaces today's
  fork-sync workflow with a normal crate dependency), Clarinet/clarity-repl,
  stacks-blockchain-api.
- Declare `clarity-legacy` frozen: consensus-fix patches only, each tied to
  an epoch pin.

Exit: stacks-core release running on published crates; at least one external
consumer migrated.

## Phase 3 — Spec and vNEXT design *(starts in parallel with Phase 1)*

- Stand up the spec repo and RFC process.
- Write kernel-interface chapters first (value format, host interface,
  cross-version call rules) — Phase 1 needs them as its design reference, so
  the spec and the kernel extraction co-evolve and check each other.
- Design vNEXT via RFCs: grammar, type system, semantics, cost model,
  stdlib. Every feature carries a decidability/cost-boundability analysis.
- Build the conformance-vector format and tooling early; write vectors as
  chapters land, not after.

Exit: complete draft spec; conformance suite covering every normative rule.

## Phase 4 — vNEXT engine and epoch activation

- Implement `clarity-vnext` as a clean-room engine against the spec —
  divergence between spec and implementation is a bug in one of them,
  adjudicated explicitly.
- Run clar2wasm against the same conformance suite as a second
  implementation of the same version; this is the final validation of the
  kernel ABI before it is declared 1.0-frozen.
- Wire the epoch manifest in stacks-core: the activating epoch pins
  kernel + legacy + vnext; prior epochs keep their pins. Ship via SIP.

Exit: vNEXT live on testnet, then mainnet at the activating epoch; historical
replay running on pinned old crates.

## Phase 5 — Cash in decidability *(the justification made real)*

Flagship deliverables, in value order:

1. **Static cost analyzer**: sound worst-case bounds per public function,
   derived from the spec's cost chapter. Surfaces: deploy-time reports,
   wallet max-fee display, fee estimation without simulation, block packing.
2. **Contract property checker**: SMT-backed verification of standard
   invariants (supply conservation, authorization, no-fund-lockup) using the
   spec's verification annotations; a path toward machine-checked contracts
   as a normal deployment artifact.
3. **Whole-ecosystem analysis**: precise asset-flow and interaction-graph
   tooling over deployed source (possible because source is law).

These are ongoing products, not a phase that "completes" — but item 1 should
land close behind vNEXT activation, because it is the concrete answer to
"why did we keep Clarity."

## Dependency summary

```
Phase 0 ──► Phase 1 ──► Phase 2 ──► Phase 4 ──► Phase 5
              ▲            (repo)     (engine+epoch)
              │
Phase 3 ──────┴──── spec co-evolves with kernel; must complete before Phase 4
```

## Top risks (consolidated)

1. **Kernel ABI frozen too early** → wrong surface forever. Gate the freeze
   on legacy + vNEXT + clar2wasm all shipping against it.
2. **Consensus drift during Phases 1–2** → chain fork. No step merges
   without bit-identical full replay; anchor vectors run in CI forever.
3. **Spec drifts from implementation** → the ECMAScript-4 failure mode.
   Conformance vectors written with each spec chapter; the vNEXT engine
   implements the spec, never the reverse silently.
4. **Effort-justification pressure** → if Phase 5 slips indefinitely, the
   "ditch Clarity" argument wins by default. Treat the static cost analyzer
   as a headline deliverable with the same priority as the engine itself.
5. **Downstream fragmentation** → Hiro tooling or clar2wasm pinning
   divergent forks. Bring them into the RFC process from Phase 0.
