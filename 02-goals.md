# Goals and Non-Goals

## Goals

### G1 — Clarity is an independent language, not a stacks-core module

- Clarity crates live in their own repository, published to crates.io, with
  their own CI, release cadence, and versioning policy.
- No dependency on `stacks-common`, `StacksEpochId`, or chainstate-shaped
  interfaces. The chain is a *host* that implements a small, specified host
  interface; stacks-core becomes one consumer among several (clar2wasm,
  Clarinet/REPL, analyzers, other chains).

### G2 — Frozen engines: language versions evolve without compatibility debt

- Each language version is implemented by its own **engine crate**, frozen at
  release (consensus-fix patches only). A shared, eternally-stable **kernel
  crate** carries values, serialization, database access, cost accounting, and
  the cross-version call boundary.
- New language versions have **no backwards-compatibility obligation** — not
  in syntax, semantics, or crate API. Old contracts keep running forever on
  their frozen engines; old epochs replay on pinned old crate versions.
- The current implementation (Clarity 1–6) is wrapped, unmodified in behavior,
  as a single **legacy engine**. We do not attempt to split or re-spec it.

### G3 — A real specification, for the new version only

- The next language version is designed **spec-first**: grammar, type system,
  evaluation semantics, cost model, serialization, and host interface, each
  normative and each backed by conformance tests.
- Legacy versions (Clarity 1–6) are explicitly declared
  **implementation-defined**: their frozen engine crates are their spec. We do
  not spend effort formalizing their accumulated inconsistencies.

### G4 — Cash in decidability

The unique properties become shipped products, not talking points:

- **Static cost analyzer**: sound worst-case cost bounds per public function,
  derived at analysis time — the foundation for true max-fee display,
  simulation-free fee estimation, and smarter block packing.
- **Proof-friendly semantics**: the new version's semantics are written so
  that verification conditions land in decidable/well-supported SMT fragments;
  a contract-property checker (supply conservation, authorization invariants,
  no-fund-lockup) is a first-class roadmap item.
- **Conformance suite as semantic anchor**: interpreter and clar2wasm (and any
  future implementation) are pinned to identical behavior by
  implementation-independent test vectors.

### G5 — Consensus safety throughout

- Every refactor step is validated by full-history mainnet replay and by
  conformance vectors captured from real mainnet transactions.
- The serialized forms that cross crate boundaries or live in the MARF (value
  wire format, analysis metadata, database layout) are specified, frozen, and
  owned by the kernel.

## Non-Goals

- **N1 — Backwards-compatible language evolution.** Explicitly rejected; the
  architecture exists precisely to remove this constraint.
- **N2 — Speccing legacy Clarity.** Versions 1–6 remain defined by their
  implementation. The spec effort starts at the new version.
- **N3 — Turing completeness.** Decidability is the product. Any proposal
  that introduces unbounded loops, recursion, or unbounded data is out of
  scope by definition.
- **N4 — Splitting the legacy interpreter into per-version crates.** All the
  consensus risk, none of the payoff. The legacy engine stays whole.
- **N5 — Replacing SIP governance.** Language versions still activate via
  epochs and SIPs; the spec becomes the artifact SIPs reference, not a rival
  process.
- **N6 — A general-purpose language.** Clarity stays a smart contract
  language; no file I/O, FFI, or off-chain execution ambitions.

## Success criteria

1. `clarity-kernel` + engine crates build with zero stacks-core dependencies;
   stacks-core consumes them from crates.io.
2. A stacks-core release runs old epochs on pinned old crate versions and the
   current epoch on current crates, with bit-for-bit replay equivalence.
3. A complete, versioned spec for the new language version, with a
   conformance suite that both the reference interpreter and clar2wasm pass.
4. A static cost analyzer that emits a sound worst-case bound for every public
   function of any well-typed contract in the new version.
5. At least one non-stacks-core embedder (e.g. Clarinet or an analysis tool)
   consuming the published crates without patches.
