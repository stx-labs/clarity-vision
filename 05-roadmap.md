# Roadmap

Phased plan for the new Clarity on the Wasm chain. Phases overlap where the
dependency summary allows. The legacy track (running Clarity 1–6 on the
interpreter) proceeds separately and is not covered here.

## Phase 0 — Foundations _(start immediately)_

- Stand up the language repository and RFC process.
- Carry the working draft in [spec/](spec/) into RFCs: principles, core
  language, primitives, standard library.
- Open the chain ABI draft jointly with the chain team: value model, module
  format, host function list, call semantics.
- Define the conformance-vector formats (language, ABI, golden build) and build
  the vector runner early.

## Phase 1 — Spec and ABI _(the design long pole)_

- Settle the open questions in each spec chapter; freeze the core forms and
  primitive list.
- Write chapter 6 (compilation to Wasm) alongside the ABI, so the lowering and
  the host interface are designed against each other.
- Write language vectors as each chapter lands, not after.
- Reach ABI v0: enough to deploy and call a module, store data, move assets, and
  call another contract.

## Phase 2 — Reference compiler

- Front end: parser, type checker, overload resolution, instantiation, inline
  expansion.
- Back end: lowering to Wasm, prelude linking, interface and provenance
  sections.
- Determinism from the first commit: golden build vectors in CI on every
  supported platform.
- A direct evaluator of the spec's semantics, used only as a test oracle for
  differential testing and fuzzing of the compiler.
- Exit criterion: the compiler passes the language vectors.

## Phase 3 — Chain integration

- Chain devnet executing Clarity-compiled modules through ABI v0.
- Host functions, fuel metering, and every runtime guarantee in
  [03-architecture.md](03-architecture.md) section 5, each covered by ABI
  vectors.
- A second source-language prototype (a small subset of Rust or AssemblyScript
  is enough) deploying against the same ABI, to catch Clarity-shaped assumptions
  before the ABI is frozen.

## Phase 4 — Trust path

- `clarity-verify`: rebuild a module from source and compiler version and
  compare bytes.
- A source registry keyed by the provenance hash, and verified-source display in
  at least one wallet and explorer.
- Compiler hardening: sustained fuzzing, differential testing against the
  oracle, external audit.

## Phase 5 — Cash in decidability _(the justification made real)_

Flagship deliverables, in value order:

1. **Static cost analyzer**: sound worst-case fuel bounds per public function,
   from source, the verified module, and the chain's host-charge table.
   Surfaces: pre-deploy reports, wallet max-fee display, fee estimation without
   simulation, block packing.
2. **Contract property checker**: SMT-backed verification of standard invariants
   (supply conservation, authorization, no fund lockup) using the spec's
   verification annotations; a path toward machine-checked contracts as a normal
   deployment artifact.
3. **Whole-ecosystem analysis**: precise asset-flow and interaction-graph
   tooling over verified source.

These are ongoing products, not a phase that completes. Item 1 should land close
behind launch, because it is the concrete answer to "why a dedicated language".

## Phase 6 — Launch

- Freeze the language spec for the first version and ABI 1.0.
- Publish the porting guide from Clarity 1–6, built on the disposition table in
  [spec/04-standard-library.md](spec/04-standard-library.md).

## Dependency summary

```
Phase 0 ──► Phase 1 ──► Phase 2 ──► Phase 3 ──► Phase 6
                           │           │           ▲
                           │           └──► Phase 5 ┤ (analyzer close behind)
                           └──► Phase 4 ────────────┘
```

Phase 4 needs only the compiler. Phase 5 needs the chain's fuel schedule and
host-charge table from Phase 3, so the analyzer's design can start with Phase 2
but its bounds cannot be stated until ABI v0 fixes the schedule.

## Top risks

1. **ABI frozen too early**: a wrong surface forever, for every language. Gate
   the freeze on Clarity plus the second-language prototype both shipping
   against it.
2. **Compiler bugs**: deployed code differs from audited source. Conformance
   vectors, differential testing against the oracle, fuzzing, reproducible
   builds, and an external audit before launch.
3. **Spec drifts from the compiler**: the ECMAScript 4 failure mode. Vectors are
   written with each chapter, and the compiler implements the spec, never the
   reverse silently.
4. **Static bounds lost in compilation**: if the lowering obscures loop bounds,
   the analyzer cannot prove them from the module. The analyzer therefore works
   from verified source, and chapter 6 must carry the preservation argument that
   the module stays within the bound its source implies.
5. **Justification pressure**: if Phase 5 slips indefinitely, "just use Rust on
   the Wasm chain" wins by default. Treat the static cost analyzer as a headline
   deliverable with the same priority as the compiler.
6. **Fuel schedule churn**: schedule changes happen at epoch boundaries and
   re-price every deployed contract, so a published bound holds only for the
   schedule version it names. Agree with the chain team on how often the
   schedule may change before launch.
7. **Bounds stop at foreign code**: a `contract-call?` through a trait, or into
   a module from another language, has no static bound, and most real contracts
   make such calls. If the analyzer can only bound leaf contracts, the max-fee
   product does not ship. Mitigations: bounds compose over verified-Clarity call
   graphs; the analyzer reports the remaining budget at each unbounded call
   rather than refusing; and the language design opportunity in
   [04-spec-plan.md](04-spec-plan.md) (declared, checked fuel bounds that
   callers can rely on) is the long-term answer for trait calls.
