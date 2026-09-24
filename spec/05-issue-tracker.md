# 5. Issue Tracker Disposition

Every open issue labeled `clarity` in stacks-core (as of 2026-09-09), with
what this draft does about it. Issues are grouped by disposition. "Addressed"
means the draft's rules make the reported problem impossible or the request
part of the language; the referenced section is where.

## 5.1 Addressed by the draft

| Issue | Summary | Where |
|---|---|---|
| [#7312](https://github.com/stacks-network/stacks-core/issues/7312) (and #7147) | Integer to fixed-width bytes, abort on overflow | `uint-to-buff-be/le`, `int-to-buff-be/le` primitives, 3.4 |
| [#6831](https://github.com/stacks-network/stacks-core/issues/6831) | A trait defined in the contract cannot be used at the contract's top level | 2.4.2: local definitions are fully usable in top-level expressions |
| [#6485](https://github.com/stacks-network/stacks-core/issues/6485) | `concretize` mishandles lists mixing trait values and contract literals | No `ListUnionType`. A contract literal has a singleton type that is a subtype of every trait it implements, and list literals take the lub (2.3.2, 2.5.6) |
| [#5128](https://github.com/stacks-network/stacks-core/issues/5128) | `get-block-info? miner-address u0` makes the transaction unmineable | 3.9: chain-data lookups are total and return `none` |
| [#4751](https://github.com/stacks-network/stacks-core/issues/4751) | `(is-eq trait-value .contract)` passes the checker and fails at runtime | `(trait X) <: principal`, so the lub is a principal and the comparison is well-typed; runtime values are plain principals (2.3.2, 2.7.1) |
| [#4622](https://github.com/stacks-network/stacks-core/issues/4622) | Checker rejects a list of distinct contract literals | Lub of singleton contract types is `principal` (2.3.2) |
| [#4431](https://github.com/stacks-network/stacks-core/issues/4431) | Duplicate parameter names and wrong argument counts accepted | 2.4.1: parameter names distinct; 2.6.2 and 2.6.5: declared arity, checked statically |
| [#3566](https://github.com/stacks-network/stacks-core/issues/3566) | Cannot call a trait extracted from a tuple | 2.5.8: any trait-typed expression is a call target |
| [#3176](https://github.com/stacks-network/stacks-core/issues/3176) | Binding a reserved keyword passes analysis, fails at runtime | 2.5.2: no shadowing of any in-scope name, checked statically. The forward-compatibility concern raised in the thread is moot under frozen language versions: a new keyword only exists in a new version, and old contracts keep theirs |
| [#1981](https://github.com/stacks-network/stacks-core/issues/1981) | Read-only functions cannot call trait functions | 2.4.1 and 2.7.4: traits may mark functions `read-only`; implementations must be read-only; read-only callers may call them through the trait |
| [#1638](https://github.com/stacks-network/stacks-core/issues/1638) | Constants cannot be used where literals are required | 2.4.1: static constants (built from literals) are usable as size terms and `contract-call?` targets |
| [#1171](https://github.com/stacks-network/stacks-core/issues/1171) | Type aliases | `define-type`, 2.3.5 |
| [#3056](https://github.com/stacks-network/stacks-core/issues/3056) (referenced by #7312) | Variadic `concat` | `concat` has a rest parameter (3.3); rest parameters are a user feature (2.6.5) |

## 5.2 Candidate additions

Feature requests that fit the language's positioning but are not yet in the
draft because each deserves a short RFC (layer, host interface impact, exact
signature).

| Issue | Request | Draft position |
|---|---|---|
| [#3568](https://github.com/stacks-network/stacks-core/issues/3568) | Schnorr (BIP-340) signature verification over secp256k1 | Strong fit for a Bitcoin-native language (Taproot, FROST). Proposed: `secp256k1-schnorr-verify : ((buff 32) (buff 64) (buff 32)) -> bool`, `false` on malformed input, placed in 3.6. Recommend including in vNEXT |
| [#3849](https://github.com/stacks-network/stacks-core/issues/3849) | `tx-fee` context value | Cheap nullary primitive; requires the host interface to expose the fee of the executing transaction. Recommend including; decide the value for `contract-call?` frames of sponsored transactions |
| [#3975](https://github.com/stacks-network/stacks-core/issues/3975) | 256-bit integer arithmetic for Schnorr, ZK, and curve math | RFC. A `(buff 32)`-based `wide-add`/`wide-mul`/`wide-mod` family is expressible in the language, so under the layering rule it is library code, with a Wasm replacement later if it is hot. A new 256-bit integer type would instead be a core change. The RFC chooses between the two. If #3568 ships as a primitive, the most pressing motivation goes away |
| [#6320](https://github.com/stacks-network/stacks-core/issues/6320) | `code-body-of?` / per-definition code hashes | `contract-hash?` is in the draft (3.5). The thread converges on per-top-level-definition hashes (`has-definition-value?` or a MAST) as the safe version of introspection; returning source text invites contracts to parse Clarity in Clarity. The chain holds only the module, so an on-chain per-definition hash would be over compiled code and would depend on the compiler. The RFC decides between that and per-definition source hashes carried in the interface metadata |

## 5.3 Out of scope for the language spec

| Issue | Why |
|---|---|
| [#4487](https://github.com/stacks-network/stacks-core/issues/4487), [#4288](https://github.com/stacks-network/stacks-core/issues/4288) | Signer-voting and StackerDB boot-contract API design |
| [#3977](https://github.com/stacks-network/stacks-core/issues/3977), [#3878](https://github.com/stacks-network/stacks-core/issues/3878), [#3877](https://github.com/stacks-network/stacks-core/issues/3877) | sBTC and PoX contract migration checklists (2023) |
| [#4030](https://github.com/stacks-network/stacks-core/issues/4030) | Boot-contract test infrastructure |
| [#3350](https://github.com/stacks-network/stacks-core/issues/3350), [#3302](https://github.com/stacks-network/stacks-core/issues/3302) | Diagnostic quality. Implementation concerns for the reference compiler, though #3350's root cause (a `uint` expression where a literal is required) is removed by static constants |

## 5.4 Patterns worth noting

Three themes recur across the tracker and shaped rules in chapter 2:

- **Checker and runtime disagree** (#4751, #4431, #3176, #6485, fixlist
  items 5 and 10). The draft's answer is structural: one lookup order, no
  shadowing, declared arity, and a value model with no static type information
  at runtime, so there is nothing for the two to disagree about.
- **Literals where expressions should do** (#1638, #3350, #6831). Static
  constants and the "any trait-typed expression" rule remove the special
  cases.
- **Traits are second-class** (#3566, #1981, #6485, #4622, #4751). Making
  `(trait X)` an ordinary type with a subtyping relation to `principal`
  resolves every one of these without a dedicated rule.
