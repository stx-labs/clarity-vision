# Architecture: Clarity on a Wasm Chain

This document describes how Clarity source becomes code running on the new
chain, what the chain guarantees for every module, and where the compiler sits
in the trust path.

## 1. Shape

There are three parts, and only the middle one is shared between languages:

```
 Clarity toolchain (off chain)        Chain ABI (spec)           Chain runtime (on chain)
 ─────────────────────────────        ────────────────           ────────────────────────
 source ─► parse ─► check ─►          runtime layer:             validate module at deploy
 expand/instantiate ─► lower ─►        module format, interface  store module
 link prelude ─► Wasm module  ──────►  host functions  ────────► execute with fuel
                                       call semantics, fuel      enforce runtime guarantees
                                      interpretation layer:      dispatch contract calls
                                       declared types,
                                       value encoding
```

- The **toolchain** is Clarity-specific and runs off chain. The chain never sees
  Clarity source.
- The **chain ABI** is the contract between any compiler and the chain. It is
  specified jointly with the chain and shared by every source language, in two
  layers: the **runtime layer** ([07-chain-abi.md](07-chain-abi.md)), which the
  chain implements, and the **interpretation layer**
  ([08-value-interpretation.md](08-value-interpretation.md)), the declared types
  and value encoding that compilers, wallets, and explorers use. The chain
  depends only on the runtime layer, except where a legacy contract calls a Wasm
  one or the reverse (section 7).
- The **chain runtime** executes Wasm and enforces the guarantees in section 5
  for every module.

## 2. The Clarity toolchain

Illustrative crate layout; names are placeholders.

```
clarity-syntax      lexer, parser, source spans
clarity-types       type checker, overload resolution, instantiation (spec ch. 2)
clarity-std         the prelude source (spec/std/prelude.clar) and its tests
clarity-compiler    inline expansion, lowering to Wasm, prelude linking,
                    interface and types sections, provenance section
clarity-analyzer    static cost bounds, asset-flow and authorization analyses
clarity-verify      rebuilds a module from source and compares it
```

Rules that bind every Clarity compiler:

- **Deterministic output.** The same build inputs produce a byte-identical
  module on every platform. No timestamps, paths, hash-map iteration order, or
  host-dependent floating point in the output.
- **Build inputs are explicit.** Compilation is not a function of source alone.
  Type-checking a `contract-call?` with a literal target reads the callee's
  declared types, its `abi.types` section (spec 2.5.8), and the
  singleton-contract subtyping rule reads it too (spec 2.3.2). A trait used in
  the source is read from the `abi.types` of the contract that defines it. The
  inputs are therefore the source, the compiler version, the `abi.interface` and
  `abi.types` of every contract referenced by literal or defining a trait the
  source uses, and the deploying principal, because deployer-relative `.name`
  references are resolved at compile time. A module is therefore specific to its
  deployer, and the chain has no relocation step and no Clarity-specific name
  resolution. Deployed sections never change, so recording which ones were used
  is enough to reproduce the build.
- **Provenance.** Each module carries a custom section with the compiler
  identifier and version, the language version the source declares (spec 2.4.0),
  a hash of the source, and the hashes of each callee's `abi.interface` and
  `abi.types` the build read, keyed by contract principal. `clarity-verify`
  fetches those sections from the chain and checks the hashes before rebuilding.
- **The prelude is linked into each module.** Only the library instances a
  contract uses are included, compiled like user code. There is no
  chain-provided library module, so the chain carries no Clarity code.
  Consequence: a faster library implementation ships in a new compiler release.
  Contracts already deployed keep the code they were deployed with, and no chain
  upgrade is needed.
- **Hashes are host functions.** `sha256`, `sha512`, `sha512/256`, `keccak256`,
  and `hash160` are host functions, like the signature schemes (section 4): one
  audited implementation at a native-speed price, which matters for the Merkle
  and SPV proofs central to sBTC, shared by every source language
  ([07-chain-abi.md](07-chain-abi.md) section 12, item 1).
- **A new language version is a compiler release.** It needs the chain only when
  it depends on a new host function or ABI feature.

## 3. The module format

A deployed contract is one Wasm module ([07-chain-abi.md](07-chain-abi.md)
section 3):

- **Exports**: one function per public and read-only function, each of Wasm type
  `[] -> []`, and an initializer the chain runs once at deploy (Clarity's
  top-level expressions and `define-constant` / `define-data-var` initializers).
- **Imports**: host functions only (section 4). A module that imports anything
  else is rejected.
- **`abi.interface`** (a custom section, validated by the chain): each exported
  function's name and kind (public or read-only), and the contract's token
  names. This is what the chain dispatches against, and all it reads.
- **`abi.types`** (a custom section the chain does not read,
  [08-value-interpretation.md](08-value-interpretation.md) section 5): each
  function's parameter and result types, each NFT's identifier type, the traits
  the contract defines and claims to implement, and its storage layout. This is
  what other contracts compile against and what wallets and explorers display
  values with. Its type grammar includes an empty type (`never` in Clarity, spec
  2.3.3) so that a function can declare that it never returns `err`.
- **Provenance** (section 2).

At deploy the chain checks that the module is valid Wasm within the profile and
size limits, imports only host functions, and exports exactly the functions its
`abi.interface` names. It then runs the initializer. It checks no types and no
trait claims.

### Values across calls

Arguments and results cross a contract call as bytes the chain does not
interpret ([07-chain-abi.md](07-chain-abi.md) section 5.4). By convention they
are the canonical encoding (formalizing SIP-005) of values of the declared types
([08-value-interpretation.md](08-value-interpretation.md) section 6), which is
what wallets encode and clear-sign and explorers decode.

The chain does not validate them, so each module validates what it receives. A
Clarity contract decodes its arguments against its declared parameter types on
entry, and the result of every call against the declared result type, and aborts
on anything that does not decode (spec 2.5.8). A Clarity contract can therefore
rely on its own types whoever calls it, because its own compiled code checks
them, not the chain. Traits are checked at compile time; at runtime the chain
guarantees only that a called function exists and, when the caller asks, that it
is read-only.

## 4. The host interface

Everything a module can do beyond pure computation goes through host functions.
The Clarity primitives in [spec/03-primitives.md](spec/03-primitives.md) that
pass the layering rule's host-access test map onto them.

| Group        | Host functions                                                                                                                                                                                                                           |
| ------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Storage      | one key-value store per contract, with raw-byte keys and values; Clarity lays its data variables and maps out on it (spec 3.7)                                                                                                           |
| Assets       | fungible and non-fungible token mint/burn/transfer/balance/owner/supply, STX transfer/burn/account; every movement recorded in the transaction's asset map                                                                               |
| Context      | the fields of `get-current-context` (spec 3.9): sender, caller, sponsor, contract, block heights and time, chain id, network flags, liquid supply                                                                                        |
| Chain data   | Stacks block, tenure, and burn block lookups, one function per field. All total: a height the host cannot serve is reported through the result, never a failure                                                                          |
| Calls        | contract-call by principal and function name; arguments and results pass through as bytes, validated by the modules (section 3)                                                                                                          |
| Frames       | nested state frames: open, commit, discard. Used by `as-contract?` and `restrict-assets?` (with context switch and allowance checks) and by a module's internal calls to its own public functions, which roll back on `err` (spec 2.7.3) |
| Events       | print (UTF-8 text) and asset events                                                                                                                                                                                                      |
| Cryptography | hashes (SHA-256, SHA-512, SHA-512/256, Keccak-256, hash160) and signature schemes (secp256k1 recover/verify/decompress, secp256r1, ed25519)                                                                                              |

The allowance comparison for `as-contract?` and `restrict-assets?` is host code,
not compiled code over a host-provided movement log, so the guarantee holds for
every module whatever its source language.

Cost has one dimension, fuel. Wasm execution is metered by the engine, each host
function has a fuel charge, and storage reads and writes are charged in fuel at
a worst-case price; there are no separate read and write dimensions. A
transaction states a fuel limit and a rate (uSTX per million fuel) and pays for
the fuel it uses, so a miner can order transactions by rate and pack a block
against one fuel limit. The fuel schedule and charge table are part of the chain
ABI ([07-chain-abi.md](07-chain-abi.md) section 9). They may change at epoch
boundaries, and a change applies to every deployed module: a module's cost
depends only on its code and the schedule, not on its source. Cost bounds are
therefore stated per schedule version, and the static cost analyzer's bound is
what a wallet proposes as the transaction's fuel limit.

## 5. Where each guarantee lives

| Guarantee                                                                                   | Enforced by                                                           | Holds for                                                                                                                                                                                                |
| ------------------------------------------------------------------------------------------- | --------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Execution stops within the fuel budget                                                      | Chain (fuel metering)                                                 | Every module                                                                                                                                                                                             |
| No reentrancy; bounded call depth                                                           | Chain (call dispatch)                                                 | Every module                                                                                                                                                                                             |
| No writes inside a read-only call                                                           | Chain (host functions reject writes in a read-only frame)             | Every module                                                                                                                                                                                             |
| A public call that returns `err` has its state changes discarded                            | Chain (frame commit/discard by the result flag)                       | Every module                                                                                                                                                                                             |
| Post-conditions; `as-contract?` / `restrict-assets?` allowances                             | Chain (asset map, frames)                                             | Every module                                                                                                                                                                                             |
| Termination by construction; worst-case fuel of the module's own code computable in advance | Clarity language, preserved by the compiler                           | Clarity modules                                                                                                                                                                                          |
| Worst-case fuel of a whole call graph computable in advance                                 | Static cost analyzer over verified source                             | Call graphs whose every callee is verified Clarity, reached by literal target. A trait call or a call into another language is bounded only by the remaining budget, and the analyzer reports it as such |
| Complete static analysis; tractable proofs                                                  | Clarity language                                                      | Clarity modules with verified source                                                                                                                                                                     |
| No undefined behavior; responses must be handled                                            | Clarity type checker and compiler                                     | Clarity modules                                                                                                                                                                                          |
| Values a contract receives from another match its declared types                            | Clarity compiler (validation on entry and after each call, section 3) | Clarity modules, whoever calls them                                                                                                                                                                      |

The first five rows are why a Clarity contract can call a module from another
language safely. The last five are what Clarity adds over any other language on
the chain.

## 6. The trust path

The compiler is in the trust path: a compiler bug can make the deployed code
differ from the audited source. The defenses:

1. **Spec and conformance suite.** A correct compiler is defined by the spec,
   not by an implementation. Every compiler release passes the suite.
2. **Differential testing and fuzzing against a direct evaluator.** The direct
   evaluator is an interpreter that runs Clarity source by applying the spec's
   dynamic-semantics rules one at a time, with no lowering, no Wasm, and no
   optimization. It is a much smaller program than the compiler and a different
   kind of program, so the two are unlikely to share a bug. Differential testing
   runs the same contract and the same calls through both and compares every
   observable result: return values, events, asset movements, and aborts.
   Fuzzing supplies those contracts and calls by generating them, well-typed, in
   volume. Any disagreement is a bug in the compiler, in the evaluator, or in
   the spec, and the spec adjudicates. The evaluator is only a test oracle: it
   never runs on chain, is never a fallback execution path, and has no authority
   over the compiler. A second production implementation would make "whatever
   the implementation does" the de facto spec again, which is the legacy
   situation this design leaves behind.
3. **Reproducible builds and source verification.** Source is published in an
   off-chain registry keyed by the source hash in the module's provenance
   section; the chain stores only the module. `clarity-verify` rebuilds a module
   from its claimed source and compiler version and compares bytes. Wallets and
   explorers show whether a module's source is verified.
4. **Analyses attach to the triple.** A cost bound or proof is stated for a
   (source, compiler version, module) triple, identified by the source hash,
   compiler version, and module hash, and is meaningful for a deployed module
   only when that triple verifies (rebuilds byte for byte). A cost bound also
   names the fuel-schedule version it was computed for (section 4). Bounds need
   both halves of the triple: loop and size bounds come from the verified
   source, because only Clarity source guarantees bounded loops, and fuel comes
   from the module, because that is what the chain meters. The chain sees only
   the module, so the ABI carries no bound certificates.

## 7. Legacy contracts

Clarity 1–6 contracts keep running on the interpreter, and the interpreter and
the Wasm engine can call each other. How that works is a chain concern outside
the scope of these documents.

It is out of scope, not unimportant. Tokens, PoX, and sBTC are legacy contracts,
and a new contract that cannot call them has no ecosystem. The chain owns the
mapping from a legacy contract's analysis to an `abi.interface` and an
`abi.types` section, and it converts values between the interpreter and Wasm
modules by the interpretation layer's encoding, the one place the chain
interprets contract values ([07-chain-abi.md](07-chain-abi.md) section 13,
question 4). The mapping is not one to one. Known mismatches the chain must
decide, with input from the language:

- **Tuples.** Legacy admission lets a tuple with extra fields pass where a
  smaller one is declared, so a legacy function can return a value with fields
  its interface does not name. vNEXT requires exact field sets (spec 2.3.2). The
  bridge must either strip extra fields on the way out of legacy code or reject
  them.
- **List union types and trait values.** Legacy lists may carry a union of trait
  types and contract literals, and legacy trait values carry static type
  information at runtime. The ABI value model has neither; a trait value is a
  principal (spec 2.7.1).
- **Read-only marks.** A vNEXT read-only function may call a legacy function
  only if the legacy interface marks it read-only, so the mapping must carry
  that mark.
- **Error-code and field-name conventions** (`error_code`, `stx-transfer-memo?`)
  are the legacy contract's and are not translated.
