# 4. Standard Library

The standard library is vNEXT source, shipped with the engine as a prelude
that is in scope in every contract (2.4.5). Its normative definition is its
source: [std/prelude.clar](std/prelude.clar). This chapter explains how it is
delivered, what it contains and why, and how every legacy Clarity construct
maps onto vNEXT.

## 4.1 Delivery and status

- The prelude is part of the language version. It is frozen when the
  language version is frozen and never changes for that version.
- Prelude names are reserved: a contract MUST NOT define a top-level name
  that the prelude defines.
- The prelude uses only features available to every contract (P3). It is
  type-checked, cost-accounted, and instantiated by the same rules as user
  code. A library call costs exactly what its expansion costs (P4).
- Conformance vectors for library functions are derived from the prelude
  source. If a vector and the source disagree, the vector is wrong.
- Engines MAY implement a library function natively as an optimization, but
  MUST produce identical results, events, and costs to evaluating the prelude
  source. The conformance suite is how that is checked.

## 4.2 What belongs in the library

The library holds **control flow and convenience**: constructs whose
expansion costs the same as a native would, and which would otherwise each
need a bespoke evaluation or typing rule in the core. It does not hold pure
computation with a plain signature; that is a primitive, by the fourth test
of the layering rule ([README.md](README.md)).

The test applied to each candidate is: *is the expansion within a small
constant factor of a native implementation?* If yes, library. If no, the
function costs one table row as a primitive and would cost users real fees
as library code.

| Section | Definitions | Built from | Expansion cost |
|---|---|---|---|
| Branching | `if`, `and`, `or`, `not` | `match` on `bool` | one `match` |
| Early exit | `asserts!`, `unwrap!`, `unwrap-err!`, `try!`, `unwrap-panic`, `unwrap-err-panic`, `default-to` | `match`, `return`, `panic` | one `match` |
| Predicates | `is-some`, `is-none`, `is-ok`, `is-err` | `match` | one `match` plus a call |
| Arithmetic | `max`, `min`, `abs` | comparisons | one comparison plus a call |
| Sequences | `append` | `concat`, `list` | one `concat` |
| Principals | `is-standard`, `principal-of?` | `principal-destruct?`, `principal-construct?`, `hash160` | one or two primitives |
| Storage | `map-insert` | `map-get?`, `map-set` | one read plus one write, as legacy |
| Assets | `stx-get-balance` | `stx-account` | one lookup |

Twenty definitions in total. Two conventions decide whether a prelude
function is `define-inline` or `define-private`:

- Anything that needs laziness or early exit is inline. This is the whole
  branching and early-exit family.
- Anything users pass to `map`, `filter`, or `fold` is private, because
  inline functions cannot be referenced (open question 4 in chapter 2).
  Predicates and `not` fall here.

### Functions considered and kept primitive

An earlier draft placed the following in the library. Each is expressible
in the language, but each failed the constant-factor test and was returned to
the core:

| Function | Why it stays primitive |
|---|---|
| `index-of?`, `replace-at?` | A `fold` carrying tuple state per element, and one copy per sequence kind for lack of sequence-kind polymorphism |
| `buff-to-uint-le`, `buff-to-int-be`, `buff-to-int-le` | A reversal fold plus two's-complement arithmetic for what a native does in one step |
| `int-to-ascii`, `int-to-utf8` | A 39-iteration fold over a digit table with an `as-max-len?` per digit |
| `string-to-int?`, `string-to-uint?` | A fold with an `index-of?` per character and two overflow guards per step |
| `verify-merkle-proof` | A fold with two hashes and a tuple merge per level; also security-sensitive code that should not live in a consensus prelude |

Moving these back removed three open questions from chapter 2
(sequence-kind polymorphism, fixed-count iteration, and the size of the
prelude's generic surface) and cut the prelude roughly in half
.

## 4.3 Disposition of every legacy construct

This table covers every native function, define form, and native variable in
Clarity 6. "Primitive" means it stays in the core with the signature in
[03-primitives.md](03-primitives.md); "form" means a special form in
[02-core-language.md](02-core-language.md); "library" means it is defined in
the prelude; "removed" means vNEXT has no equivalent by that name.

### Arithmetic and logic

| Legacy | vNEXT | Notes |
|---|---|---|
| `+`, `-`, `*`, `/` | primitive | binary only |
| `mod`, `pow`, `sqrti`, `log2` | primitive | |
| `>=`, `<=`, `<`, `>` | primitive | |
| `to-int`, `to-uint` | primitive | |
| `xor` | removed | use `bit-xor` |
| `bit-and`, `bit-or`, `bit-xor`, `bit-not` | primitive | binary only |
| `bit-shift-left`, `bit-shift-right` | primitive | shift of 128 or more aborts instead of wrapping |
| `and`, `or` | library | binary, inline, short-circuit |
| `not` | library | private |
| `is-eq` | primitive | binary only |
| `if` | library | inline over `match` |

### Binding, sequencing, branching, early exit

| Legacy | vNEXT | Notes |
|---|---|---|
| `let` | form | |
| `begin` | sugar | `(let () ...)` |
| `match` | form | constructor patterns `((some x) ...)`, `(none ...)`, `((ok x) ...)`, `((err e) ...)`, `(true ...)`, `(false ...)` |
| `asserts!`, `unwrap!`, `unwrap-err!`, `try!` | library | inline over `match` and `return` |
| `unwrap-panic`, `unwrap-err-panic` | library | inline over `match` and `panic` |
| `default-to` | library | inline; default is now lazy |
| `is-ok`, `is-err`, `is-some`, `is-none` | library | private |
| `ok`, `err`, `some` | form | constructors |
| `none`, `true`, `false` | literal | |

### Sequences

| Legacy | vNEXT | Notes |
|---|---|---|
| `list` | form | the only variadic form |
| `len`, `concat`, `slice?`, `as-max-len?` | primitive | |
| `element-at?`, `index-of?`, `replace-at?` | primitive | |
| `element-at`, `index-of` | removed | aliases |
| `append` | library | `(concat items (list item))` |
| `map` | primitive | single sequence only; see chapter 2 open question 2 |
| `filter`, `fold` | primitive | |

### Tuples

| Legacy | vNEXT | Notes |
|---|---|---|
| `tuple` | removed | use `{ f: v, ... }` |
| `get`, `merge` | form | |

### Conversions and serialization

| Legacy | vNEXT | Notes |
|---|---|---|
| `buff-to-uint-be`, `buff-to-uint-le`, `buff-to-int-be`, `buff-to-int-le` | primitive | |
| new: `uint-to-buff-be`, `uint-to-buff-le`, `int-to-buff-be`, `int-to-buff-le` | primitive | fixed width, abort if the value does not fit (issue #7312) |
| `int-to-ascii`, `int-to-utf8` | primitive | |
| `string-to-int?`, `string-to-uint?` | primitive | |
| `to-consensus-buff?`, `from-consensus-buff?` | primitive | |
| `to-ascii?` | primitive | candidate for removal |

### Principals

| Legacy | vNEXT | Notes |
|---|---|---|
| `principal-construct?` | primitive | single signature with `(optional (string-ascii 40))` name; `error_code` field renamed `error-code` |
| `principal-destruct?` | primitive | |
| `is-standard` | library | `(is-ok (principal-destruct? p))` |
| `principal-of?` | library | `hash160` plus `principal-construct?` with the network's version byte |
| `contract-of` | primitive | |
| `contract-hash?` | primitive | |

### Cryptography

| Legacy | vNEXT | Notes |
|---|---|---|
| `hash160`, `sha256`, `sha512`, `sha512/256`, `keccak256` | primitive | buffers only; integer inputs removed |
| `secp256k1-recover?`, `secp256k1-verify`, `secp256k1-decompress?` | primitive | low-S required |
| `secp256r1-verify`, `ed25519-verify` | primitive | low-S required for ECDSA |
| `verify-merkle-proof` | primitive | |

### Storage

| Legacy | vNEXT | Notes |
|---|---|---|
| `var-get`, `var-set` | primitive | |
| `map-get?`, `map-set`, `map-delete` | primitive | |
| `map-insert` | library | `map-get?` then `map-set`; becomes primitive if static reference kinds are dropped (chapter 2 open question 6) |

### Assets

| Legacy | vNEXT | Notes |
|---|---|---|
| `ft-mint?`, `ft-burn?`, `ft-transfer?`, `ft-get-balance`, `ft-get-supply` | primitive | |
| `nft-mint?`, `nft-burn?`, `nft-transfer?`, `nft-get-owner?` | primitive | |
| `stx-transfer?` | primitive | takes `(optional (buff 34))` memo |
| `stx-transfer-memo?` | removed | merged into `stx-transfer?` |
| `stx-burn?`, `stx-account` | primitive | |
| `stx-get-balance` | library | `(get unlocked (stx-account p))` |

### Calls, context, and allowances

| Legacy | vNEXT | Notes |
|---|---|---|
| `contract-call?` | form | |
| `as-contract?` | form | |
| `as-contract` | removed | unrestricted asset access |
| `restrict-assets?` | form | `with-all-assets-unsafe` not permitted |
| `with-stx`, `with-ft`, `with-nft`, `with-staking`, `with-pox`, `with-all-assets-unsafe` | allowance forms | |
| `with-stacking` | removed | renamed `with-staking` in Clarity 6 |
| `at-block` | removed | disabled in legacy since epoch 3.4 |
| `print` | primitive | |

### Chain data

| Legacy | vNEXT | Notes |
|---|---|---|
| `get-stacks-block-info?`, `get-tenure-info?`, `get-burn-block-info?` | primitive | return the whole record; property-name argument removed |
| `get-block-info?` | removed | already removed in Clarity 3 |
| `get-bitcoin-tx-output?` | primitive | |

### Define forms

| Legacy | vNEXT | Notes |
|---|---|---|
| `define-constant`, `define-data-var`, `define-map` | form | |
| `define-fungible-token`, `define-non-fungible-token` | form | |
| `define-public`, `define-read-only`, `define-private` | form | private may be generic and overloaded |
| `define-trait`, `impl-trait` | form | trait identifiers replace `<name>` syntax |
| `use-trait` | removed | `(define-type name (trait id))` |
| new: `define-type` | form | transparent type aliases |
| new: `define-inline` | form | call-by-name, expanded at call site |

### Native variables

| Legacy | vNEXT | Notes |
|---|---|---|
| `tx-sender`, `contract-caller`, `tx-sponsor?`, `current-contract` | primitive | nullary |
| `burn-block-height`, `stacks-block-height`, `tenure-height`, `stacks-block-time` | primitive | nullary |
| `chain-id`, `is-in-mainnet`, `is-in-regtest`, `stx-liquid-supply` | primitive | nullary |
| `block-height` | removed | already removed in Clarity 3 |
| `none`, `true`, `false` | literal | |

## 4.4 New in vNEXT

Library additions with no legacy counterpart, included because they were
common user-written helpers and expand to a single comparison:

- `max`, `min`, `abs`

Primitive additions with no legacy counterpart: the four `*-to-buff-*`
functions (chapter 3). Further candidates from the issue tracker are
collected in [05-issue-tracker.md](05-issue-tracker.md).

## 4.5 What the prelude taught us about the core

Writing the prelude is the test of the core design. Findings so far:

- The first draft put every expressible function in the library and had to
  invent digit tables, byte tables, and 39-element iteration lists to do it.
  Those functions are the ones with plain signatures, where a primitive costs
  one table row; the library bought nothing there and would have cost users
  fees. The layering rule's fourth test came from this.
- The value of the library is concentrated in the control-flow family, where
  it replaces ten bespoke lazy-evaluation and typing rules with `match`,
  `return`, and inline expansion.
- `never` as the type of `(return ...)` and `(panic)` makes every early-exit
  form typeable with ordinary lub rules, with no special cases.
- Inline functions cannot be passed to `filter`, which forces predicates to
  be real functions with call overhead (chapter 2 open question 4).
- Overloading and static reference kinds are each justified by exactly one
  group of prelude functions (`unwrap!`/`try!` and `map-insert`). Both are
  flagged for a keep-or-drop decision in chapter 2.
