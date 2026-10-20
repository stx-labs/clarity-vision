# Why Clarity on a Wasm Chain

The new chain executes Wasm, and any language that compiles to Wasm can target
it. So the question is no longer "why not switch VMs". It is "why a dedicated
contract language, instead of Rust or another general-purpose language compiled
to the same Wasm". This document makes the case, and states honestly what the
Wasm-first design costs.

## 1. What the VM gives and what only the language can give

Wasm gives the chain a mature, sandboxed, portable execution engine, fuel
metering, good performance, and a path to more than one source language. The
chain adds runtime guarantees on top that hold for every module (section 1.4).

Wasm cannot give **decidability**. A Wasm module can loop without bound; fuel
guarantees that execution stops, not that anyone can know beforehand how much it
will cost or what it can do. Those properties have to come from the source
language.

### 1.1 Decidability

Clarity is deliberately **not Turing-complete**:

- There is no recursion (direct or mutual) and no unbounded loop construct.
  Iteration exists only as `map`, `filter`, `fold-left`, and `fold-right` over
  sequences whose maximum length is fixed by their type.
- Every type has a statically known maximum size. Lists, buffers, and strings
  all carry length bounds; there are no unbounded data structures.
- Call depth is bounded and contracts cannot be re-entered.

Consequence: **every Clarity program provably terminates**, and every execution
path is statically enumerable in principle. The halting problem, which makes
complete static analysis impossible for general Wasm, does not apply to a module
compiled from Clarity.

### 1.2 What decidability enables

These capabilities justify the language, and this effort commits to building
them:

- **Sound static cost bounds.** Because all loops and data are bounded by types,
  the worst-case fuel of a function's own code is computable before deployment
  without simulation, as a function of its arguments' sizes (a list's actual
  length, not only its type bound, so the bound for a one-element list is not
  the bound for a thousand). A wallet can display a true maximum fee; a block
  producer can pack against guaranteed bounds; there is no "estimate by
  simulating and hope state doesn't change" pattern. The bound composes across
  `contract-call?` only as far as the callees are themselves Clarity with
  verified source. A call through a trait, or into a module written in another
  language, can consume the whole remaining budget, and the analyzer reports it
  as such ([03-architecture.md](03-architecture.md) section 5).
- **Complete static analysis.** Whole-program analyses (taint tracking, asset
  flow, authorization checks) terminate and can be precise, not heuristic. An
  analyzer can enumerate every path by which a contract's assets can move.
- **Tractable safety proofs.** All functions are total, state access is
  explicit, and there is no reentrancy, so verification conditions stay inside
  decidable or well-behaved
  [SMT](https://en.wikipedia.org/wiki/Satisfiability_modulo_theories) fragments.
  Proving invariants such as supply conservation, access control, and "no path
  locks funds" is an engineering task, not a research program.

### 1.3 The deployed artifact is Wasm

The chain stores and executes Wasm. It never sees Clarity source. This is the
price of a chain that more than one language can target, and it changes one of
legacy Clarity's claims: legacy Clarity had no compiler between the author and
the chain, and new Clarity does.

A compiler in the trust path means a compiler bug can make the deployed code
differ from the source everyone audited. The plan pays that down directly:

- **A specification and conformance suite** define what a correct compiler
  produces, independent of any one implementation.
- **Deterministic, reproducible builds.** The same source and compiler version
  produce a byte-identical module, and each module records which compiler built
  it and the hash of its source. Anyone can rebuild and compare.
- **Source verification as a product.** Analyses, cost bounds, and proofs are
  computed on source and attach to a verified (source, compiler version, module)
  triple. They apply to the deployed code exactly when that triple checks.
- **A compiler that is small by design.** The core language is about a dozen
  forms and eighty primitives with no bespoke evaluation rules, and the standard
  library is compiled like user code. Validating the translation of a
  first-order, loop-bounded language is far more tractable than for a
  general-purpose one, which keeps verified compilation a realistic long-term
  goal.

### 1.4 Safety by construction

Two layers enforce safety, and it matters which one enforces what.

The **chain** enforces these for every module, whatever its source language, so
they hold even when a Clarity contract calls one written in something else (the
normative table is [03-architecture.md](03-architecture.md) section 5):

- **No reentrancy**, the largest exploit class in EVM history, and bounded call
  depth.
- **Read-only frames**: a write attempted inside a read-only call is rejected at
  runtime.
- **Rollback on error**: a public function that returns `err` has its state
  changes discarded.
- **Post-conditions and asset allowances**: the sender bounds what a transaction
  may do to their assets, and `as-contract?` bounds what a contract may do with
  its own, regardless of the called code.

The **language** adds, for Clarity contracts:

- **No undefined behavior**: arithmetic overflow aborts deterministically; there
  are no null references.
- **Errors must be handled**: ignoring a `response` is a type error.
- **Well-typed boundaries**: a Clarity contract validates every value it
  receives, its arguments on entry and the result of every call it makes,
  against its declared types, so it can rely on its types whatever language the
  other side is written in. The chain passes values through as bytes and checks
  none of them.
- **Decidability**, with everything in 1.2.

### 1.5 Bitcoin-native

Clarity contracts read Bitcoin chain state directly (burn block info, Bitcoin
transaction outputs, Merkle inclusion proofs). The chain ABI exposes that state
to every language; Clarity makes it first-class in the type system and standard
library.

## 2. Honest ledger

| Gap                                    | Reality                                                                                                                                           | Plan item                                                                                                                      |
| -------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| No specification yet                   | The design exists as a working draft ([spec/](spec/))                                                                                             | Spec-first design ([04-spec-plan.md](04-spec-plan.md))                                                                         |
| Compiler in the trust path             | Deployed code is only as trustworthy as the compiler that produced it                                                                             | Conformance suite, reproducible builds, source verification ([03-architecture.md](03-architecture.md))                         |
| Guarantees are per-language            | A module from another language has the chain's runtime guarantees but not Clarity's static ones                                                   | Verified-source labeling in wallets and explorers, so users know which they are looking at                                     |
| Properties unexploited                 | No static cost analyzer or prover exists yet                                                                                                      | Flagship toolchain deliverables ([05-roadmap.md](05-roadmap.md))                                                               |
| Not source-compatible with Clarity 1–6 | Builders must port contracts                                                                                                                      | Disposition table for every legacy construct ([spec/04-standard-library.md](spec/04-standard-library.md))                      |
| Mixed ecosystem for years              | Tokens, PoX, and sBTC are legacy contracts; a new contract that calls them crosses a type mapping between legacy analysis types and the chain ABI | Named as a chain-owned deliverable with the mismatches listed ([03-architecture.md](03-architecture.md) section 7)             |
| Cost bounds stop at foreign code       | A call through a trait or into a non-Clarity module has no static bound                                                                           | Bounds are stated per verified-Clarity call graph, and the analyzer marks the boundary ([05-roadmap.md](05-roadmap.md) risk 7) |
| Developer experience                   | Tooling, docs, and error messages behind mainstream ecosystems                                                                                    | A stable spec and toolchain crates as the foundation for tools                                                                 |

Each gap is an engineering problem. None is a fundamental limitation. The
reverse does not hold for general-purpose languages: their deficits relative to
Clarity are fundamental.

## 3. Why not a general-purpose language on the same Wasm

| Option                                    | What you gain                                               | What you permanently lose                                                                                                                                                                  |
| ----------------------------------------- | ----------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Rust (or C, Go, AssemblyScript) to Wasm   | Mature toolchains, large developer pool, raw expressiveness | Decidability; static cost bounds; complete analysis; tractable proofs. Contract safety reduces to library discipline, and the language's compiler and runtime become a large trust surface |
| Solidity or an EVM-style language to Wasm | Familiarity for EVM developers                              | All of the above, plus a design built around a reentrancy-permitting call model                                                                                                            |
| Move-style resource language              | Linear resource types (genuinely good)                      | Still Turing-complete: termination, exact costs, and complete analysis remain impossible                                                                                                   |

These are not either/or. The chain is multi-language by design, and nothing
stops other languages from targeting it. Clarity's role is to be the language in
which the properties above are guaranteed, and the one that consensus-critical
and high-value contracts are written in.

The pitch, in one sentence:

> **The contract language where the worst case is a theorem, not a hope.** Every
> contract's maximum cost is known before it runs, its safety properties are
> machine-checkable, and anyone can verify that the code on chain was built from
> the code they read.

## 4. The commitment this implies

A decidable language only earns its place if we ship what decidability makes
possible. Concretely (see [05-roadmap.md](05-roadmap.md)):

1. A **specification**, designed spec-first.
2. A **deterministic compiler** to Wasm, pinned to the spec by a **conformance
   suite**.
3. **Reproducible builds and source verification**, so analyses of source apply
   to deployed code.
4. A **static cost analyzer** producing sound worst-case fuel bounds per
   function.
5. **Proof-friendly semantics** and a verification toolchain path.
