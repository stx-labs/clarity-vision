# Architecture: Clarity on a Wasm Chain

This document describes how Clarity source becomes code running on the new
chain, what the chain guarantees for every module, and where the compiler sits
in the trust path.

## 1. Shape

There are three parts, and only the middle one is shared between languages:

```
 Clarity toolchain (off chain)        Chain ABI (spec)           Chain runtime (on chain)
 ─────────────────────────────        ────────────────           ────────────────────────
 source ─► parse ─► check ─►          module format              validate module at deploy
 expand/instantiate ─► lower ─►       interface metadata         store module + interface
 link prelude ─► Wasm module  ──────► value encoding  ─────────► execute with fuel
                                      host functions             enforce runtime guarantees
                                      call semantics             dispatch contract calls
                                      fuel schedule
```

- The **toolchain** is Clarity-specific and runs off chain. The chain never sees
  Clarity source.
- The **chain ABI** is the contract between any compiler and the chain. It is
  specified jointly with the chain and shared by every source language.
- The **chain runtime** executes Wasm and enforces the guarantees in section 5
  for every module.

## 2. The Clarity toolchain

Illustrative crate layout; names are placeholders.

```
clarity-syntax      lexer, parser, source spans
clarity-types       type checker, overload resolution, instantiation (spec ch. 2)
clarity-std         the prelude source (spec/std/prelude.clar) and its tests
clarity-compiler    inline expansion, lowering to Wasm, prelude linking,
                    interface metadata, provenance section
clarity-analyzer    static cost bounds, asset-flow and authorization analyses
clarity-verify      rebuilds a module from source and compares it
```

Rules that bind every Clarity compiler:

- **Deterministic output.** The same build inputs produce a byte-identical
  module on every platform. No timestamps, paths, hash-map iteration order, or
  host-dependent floating point in the output.
- **Build inputs are explicit.** Compilation is not a function of source alone.
  Type-checking a `contract-call?` with a literal target reads the callee's
  deployed interface (spec 2.5.8), and the singleton-contract subtyping rule
  reads it too (spec 2.3.2). The inputs are therefore the source, the compiler
  version, the interface of every contract referenced by literal, and the
  deploying principal, because deployer-relative `.name` references are resolved
  at compile time. A module is therefore specific to its deployer, and the chain
  has no relocation step and no Clarity-specific name resolution. Deployed
  interfaces never change, so recording which ones were used is enough to
  reproduce the build.
- **Provenance.** Each module carries a custom section with the compiler
  identifier and version, the language version, a hash of the source, and the
  hash of each callee interface the build read, keyed by contract principal.
  `clarity-verify` fetches those interfaces from the chain and checks the hashes
  before rebuilding.
- **The prelude is linked into each module.** Only the library instances a
  contract uses are included, compiled like user code. There is no
  chain-provided library module, so the chain carries no Clarity code.
  Consequence: a faster library implementation ships in a new compiler release.
  Contracts already deployed keep the code they were deployed with, and no chain
  upgrade is needed.
- **Hashes are compiled, not host functions.** `sha256`, `sha512`, `sha512/256`,
  `keccak256`, and `hash160` are Wasm compiled from their Rust implementations
  and linked into the module like the prelude. Signature schemes stay host
  functions (section 4).
- **A new language version is a compiler release.** It needs the chain only when
  it depends on a new host function or ABI feature.

## 3. The module format

A deployed contract is one Wasm module plus its interface:

- **Exports**: one function per public and read-only function, and an
  initializer the chain runs once at deploy (Clarity's top-level expressions and
  `define-constant` / `define-data-var` initializers).
- **Imports**: host functions only (section 4). A module that imports anything
  else is rejected.
- **Interface metadata** (a custom section, validated by the chain): each
  exported function's name, parameter and result types in ABI types, and
  read-only mark; the traits the contract defines and claims to implement; its
  token definitions. This is what other contracts compile and dispatch against.
  The ABI type grammar includes an empty type (`never` in Clarity, spec 2.3.3)
  so that a function can declare that it never returns `err`; boundary
  validation admits no value for it.
- **Provenance** (section 2).

At deploy the chain checks that the module is valid Wasm within size limits,
imports only host functions, exports exactly the functions its interface
declares with matching Wasm signatures, and that every implemented-trait claim
holds against the interface. It then runs the initializer.

### Values across calls

Values cross a contract call in the ABI's canonical encoding (the value model
and wire format, formalizing SIP-005). The chain **decodes and validates every
argument against the callee's declared parameter types, and every result against
the declared result type**, before the other side sees it. For a trait-typed
parameter, the chain checks that the principal's interface implements the trait.

The chain cannot trust any caller's compiler, so this validation is what lets a
Clarity contract rely on its own types when it is called from a module written
in another language.

## 4. The host interface

Everything a module can do beyond pure computation goes through host functions.
The Clarity primitives in [spec/03-primitives.md](spec/03-primitives.md) that
pass the layering rule's host-access test map onto them.

| Group        | Host functions                                                                                                                                             |
| ------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Storage      | data-var get/set, map get/set/delete, keyed by the calling contract                                                                                        |
| Assets       | fungible and non-fungible token mint/burn/transfer/balance/owner/supply, STX transfer/burn/account; every movement recorded in the transaction's asset map |
| Context      | tx-sender, contract-caller, sponsor, current contract, block heights and time, chain id, network flags, liquid supply                                      |
| Chain data   | Stacks block, tenure, and burn block lookups; Bitcoin transaction output parsing. All total: they return `none` rather than fail                           |
| Calls        | contract-call by principal and function name, with argument and result validation (section 3)                                                              |
| Frames       | `as-contract?` and `restrict-assets?` frames: context switch, nested rollback, allowance checks                                                            |
| Events       | print and asset events                                                                                                                                     |
| Cryptography | signature schemes (secp256k1 recover/verify/decompress, secp256r1, ed25519). Hashes are compiled into the module (section 2)                               |

The allowance comparison for `as-contract?` and `restrict-assets?` is host code,
not compiled code over a host-provided movement log, so the guarantee holds for
every module whatever its source language.

Each host function has a fuel charge, and storage operations are also charged in
read/write count and length dimensions. The fuel schedule and charge table are
part of the chain ABI. They may change at epoch boundaries, and a change applies
to every deployed module: a module's cost depends only on its code and the
engine's schedule, not on its source. Cost bounds are therefore stated per
schedule version.

## 5. Where each guarantee lives

| Guarantee                                                                                   | Enforced by                                               | Holds for                                                                                                                                                                                                |
| ------------------------------------------------------------------------------------------- | --------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Execution stops within the fuel budget                                                      | Chain (fuel metering)                                     | Every module                                                                                                                                                                                             |
| No reentrancy; bounded call depth                                                           | Chain (call dispatch)                                     | Every module                                                                                                                                                                                             |
| No writes inside a read-only call                                                           | Chain (host functions reject writes in a read-only frame) | Every module                                                                                                                                                                                             |
| A public call that returns `err` has its state changes discarded                            | Chain (frame commit/discard on the result)                | Every module                                                                                                                                                                                             |
| Values at call boundaries match the declared interface                                      | Chain (section 3)                                         | Every call                                                                                                                                                                                               |
| Post-conditions; `as-contract?` / `restrict-assets?` allowances                             | Chain (asset map, frames)                                 | Every module                                                                                                                                                                                             |
| Termination by construction; worst-case fuel of the module's own code computable in advance | Clarity language, preserved by the compiler               | Clarity modules                                                                                                                                                                                          |
| Worst-case fuel of a whole call graph computable in advance                                 | Static cost analyzer over verified source                 | Call graphs whose every callee is verified Clarity, reached by literal target. A trait call or a call into another language is bounded only by the remaining budget, and the analyzer reports it as such |
| Complete static analysis; tractable proofs                                                  | Clarity language                                          | Clarity modules with verified source                                                                                                                                                                     |
| No undefined behavior; responses must be handled                                            | Clarity type checker and compiler                         | Clarity modules                                                                                                                                                                                          |

The first six rows are why a Clarity contract can call a module from another
language safely. The last four are what Clarity adds over any other language on
the chain.

## 6. The trust path

The compiler is in the trust path: a compiler bug can make the deployed code
differ from the audited source. The defenses:

1. **Spec and conformance suite.** A correct compiler is defined by the spec,
   not by an implementation. Every compiler release passes the suite.
2. **Differential testing and fuzzing against a direct evaluator.** The
   direct evaluator is an interpreter that runs Clarity source by applying the
   spec's dynamic-semantics rules one at a time, with no lowering, no Wasm, and
   no optimization. It is a much smaller program than the compiler and a
   different kind of program, so the two are unlikely to share a bug.
   Differential testing runs the same contract and the same calls through both
   and compares every observable result: return values, events, asset
   movements, and aborts. Fuzzing supplies those contracts and calls by
   generating them, well-typed, in volume. Any disagreement is a bug in the
   compiler, in the evaluator, or in the spec, and the spec adjudicates. The
   evaluator is only a test oracle: it never runs on chain, is never a fallback
   execution path, and has no authority over the compiler. A second production
   implementation would make "whatever the implementation does" the de facto
   spec again, which is the legacy situation this design leaves behind.
3. **Reproducible builds and source verification.** Source is published in an
   off-chain registry keyed by the source hash in the module's provenance
   section; the chain stores only the module. `clarity-verify` rebuilds a module
   from its claimed source and compiler version and compares bytes. Wallets and
   explorers show whether a module's source is verified.
4. **Analyses attach to the triple.** A cost bound or proof is stated for a
   (source hash, compiler version, module hash) triple and is meaningful for a
   deployed module only when that triple verifies. A cost bound also names the
   fuel-schedule version it was computed for (section 4). Bounds need both
   halves of the triple: loop and size bounds come from the verified source,
   because only Clarity source guarantees bounded loops, and fuel comes from the
   module, because that is what the chain meters. The chain sees only the
   module, so the ABI carries no bound certificates.

## 7. Legacy contracts

Clarity 1–6 contracts keep running on the interpreter, and the interpreter and
the Wasm engine can call each other. How that works is a chain concern outside
the scope of these documents.

It is out of scope, not unimportant. Tokens, PoX, and sBTC are legacy contracts,
and a new contract that cannot call them has no ecosystem. The chain owns the
mapping from a legacy contract's analysis to an ABI interface, and the mapping
is not one to one. Known mismatches the chain must decide, with input from the
language:

- **Tuples.** Legacy admission lets a tuple with extra fields pass where a
  smaller one is declared, so a legacy function can return a value with fields
  its interface does not name. vNEXT requires exact field sets (spec 2.3.2).
  Boundary validation must either strip extra fields on the way out of legacy
  code or reject them.
- **List union types and trait values.** Legacy lists may carry a union of trait
  types and contract literals, and legacy trait values carry static type
  information at runtime. The ABI value model has neither; a trait value is a
  principal (spec 2.7.1).
- **Read-only marks.** A vNEXT read-only function may call a legacy function
  only if the legacy interface marks it read-only, so the mapping must carry
  that mark.
- **Error-code and field-name conventions** (`error_code`, `stx-transfer-memo?`)
  are the legacy contract's and are not translated.

## 8. Open questions

1. **Wasm memory limit.** The language's intermediate value size limit (spec
   2.8, provisionally 8 MiB) must stay below the memory a module may use, and
   exceeding that memory is a runtime error (spec 2.7.2). The chain ABI must fix
   the limit, per transaction or per call frame.
2. **Module size limit.** It is the only limit on a contract's size after inline
   expansion and instantiation (spec 2.8), and the deploy check in section 3
   enforces it. The chain ABI must fix the value.
