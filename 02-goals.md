# Goals and Non-Goals

## Goals

### G1 — Clarity is a specified language compiled to Wasm

- Clarity is designed **spec-first**: grammar, type system, static and dynamic
  semantics, compilation to Wasm, and the standard library, each normative and
  each backed by conformance tests.
- The reference compiler implements the spec and is validated against it, never
  the reverse. Any other Clarity compiler is held to the same suite.
- The toolchain lives in its own repository, published as crates with their own
  CI, release cadence, and versioning policy.

### G2 — One chain ABI, shared by every source language

- The chain defines a single ABI: the module format, interface metadata, value
  encoding, host functions, call semantics, and fuel schedule. Clarity is its
  first consumer, not its owner.
- Nothing on chain is Clarity-specific. The chain never parses Clarity, and a
  Clarity contract has no powers on chain that a module from another language
  lacks.

### G3 — Runtime guarantees for every module

The chain enforces a fixed set of guarantees for every module, whatever language
produced it: fuel limits, no reentrancy, read-only frames, rollback on `err`,
boundary validation, and asset allowances. The normative list, with which layer
enforces each, is [03-architecture.md](03-architecture.md) section 5 and is not
repeated here.

### G4 — Cash in decidability

The properties unique to Clarity become shipped products:

- **Static cost analyzer**: sound worst-case fuel bounds (plus host charges) per
  public function, computed before deployment. Bounds are functions of argument
  sizes, not only of argument types, so they are tight enough to display as a
  fee. They cover the contract's own code and, transitively, callees that are
  verified Clarity; at a trait call or a call into another language the analyzer
  reports the remaining budget as the bound. The foundation for true max-fee
  display, simulation-free fee estimation, and block packing.
- **Proof-friendly semantics**: written so that verification conditions land in
  decidable or well-supported SMT fragments; a contract-property checker (supply
  conservation, authorization invariants, no fund lockup) is a first-class
  roadmap item.

### G5 — A trustworthy compiler path

- **Deterministic builds**: the same build inputs produce a byte-identical
  module on every platform. The inputs are the source, the compiler version, the
  interface of every contract the source calls by literal, and the deploying
  principal when deployer-relative names are resolved at compile time
  ([03-architecture.md](03-architecture.md) section 2).
- **Provenance**: each module records its compiler version, its source hash, and
  a hash of every callee interface it was compiled against.
- **Source verification**: anyone can rebuild a deployed module from its claimed
  source and the recorded inputs and compare. Analyses and proofs attach to a
  verified (source, build inputs, module) triple.

## Non-Goals

- **N1 — Source compatibility with Clarity 1–6.** Rejected. The new language has
  no compatibility obligation in syntax or semantics. The disposition table in
  [spec/04-standard-library.md](spec/04-standard-library.md) is the porting
  guide. Legacy contracts keep running on the interpreter, with interop handled
  by the chain outside these documents.
- **N2 — Turing completeness.** Decidability is the product. Any proposal that
  introduces unbounded loops, recursion, or unbounded data is out of scope by
  definition.
- **N3 — On-chain compilation.** The chain stores and executes Wasm. It does not
  parse, type-check, or compile Clarity.
- **N4 — Being the only language.** The chain is multi-language. Clarity
  competes on guarantees, not on privileges.
- **N5 — A general-purpose language.** Clarity stays a smart contract language:
  no file I/O, FFI, or off-chain execution.

## Success criteria

1. A complete, versioned spec for the language, with a conformance suite.
2. A reference compiler that passes the suite and produces byte-identical
   modules across platforms.
3. A chain ABI specified jointly with the chain team, implemented by the chain,
   and exercised by Clarity.
4. A static cost analyzer that emits a sound worst-case fuel bound for every
   public function of any well-typed contract.
5. A source-verification service or tool that rebuilds and verifies any deployed
   Clarity module from its source.
