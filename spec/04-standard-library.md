# 4. Standard Library

The standard library is vNEXT source, linked into modules by the compiler as a
prelude that is in scope in every contract (2.4.5). Its normative definition is
its source: [std/prelude.clar](std/prelude.clar). This chapter explains how it
is delivered, what it contains and why, and how every legacy Clarity construct
maps onto vNEXT.

## 4.1 Delivery and status

- The prelude is part of the language version. It is frozen when the language
  version is frozen and never changes for that version.
- Prelude names are reserved: a contract MUST NOT define a top-level name that
  the prelude defines. This includes the `std-*` helper definitions.
- The prelude uses only features available to every contract (P3). It is
  type-checked, instantiated, and compiled by the same rules as user code.
- **Results are defined by the source.** Conformance vectors for library
  functions are derived from the prelude source. If a vector and the source
  disagree, the vector is wrong.
- **Linked into each module.** The compiler includes the library instances a
  contract uses in that contract's module. A library call costs the fuel of that
  code (P4, P5). The chain holds no library code of its own.
- **Optimization replaces the implementation, not the definition.** A later
  compiler MAY link a hand-written or better compiled Wasm implementation of a
  library function. It MUST produce identical results, events, and errors to the
  source for every input, which the conformance suite checks. Contracts already
  deployed keep the code they were deployed with, so a library change never
  alters them and no chain upgrade is involved. (Their cost can still change at
  an epoch boundary if the chain's fuel schedule does; see
  [../03-architecture.md](../03-architecture.md) section 4.)

The source is written for correctness and readability, not speed. Where a
definition is slow (a digit-by-digit conversion, a bitwise square root), that is
a candidate for a Wasm replacement, not a reason to move it into the core.

## 4.2 What belongs in the library

Everything that can be written in the language. The layering rule
([README.md](README.md)) keeps in the core only host access, what cannot be
expressed, cryptographic standards, and the base operations on each type's
representation. Every other construct a contract author uses is here.

| Section      | Definitions                                                                                    | Built from                                                                                                        |
| ------------ | ---------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| Branching    | `if`, `not`                                                                                    | `match` on `bool`                                                                                                 |
| Comparison   | `<`, `>`, `>=`                                                                                 | `<=`, `not`                                                                                                       |
| Early exit   | `asserts!`, `unwrap!`, `unwrap-err!`, `try!`, `unwrap-panic`, `unwrap-err-panic`, `default-to` | `match`, `return`, `panic`                                                                                        |
| Predicates   | `is-some`, `is-none`, `is-ok`, `is-err`                                                        | `match`                                                                                                           |
| Arithmetic   | `max`, `min`, `bit-xor`, `bit-or` (rest parameters), `abs`, `mod`, `bit-not`                   | comparison, `+ - * /`, `bit-and`, `fold-left`                                                                     |
| Arithmetic   | `pow`, `sqrti`, `log2`                                                                         | `fold-left` over a constant list of bit positions, with shifts                                                    |
| Sequences    | `append`, `replace-at?`                                                                        | `concat`, `slice?`, `as-max-len?`                                                                                 |
| Sequences    | `index-of?`                                                                                    | `fold-left` with the target in the accumulator                                                                    |
| Conversions  | `buff-to-uint-le`, `buff-to-int-be`, `buff-to-int-le`                                          | `buff-to-uint-be`, a byte-reversing `fold-left`, two's-complement arithmetic sign-extended from the actual length |
| Conversions  | `int-to-ascii`, `int-to-utf8`, `string-to-int?`, `string-to-uint?`                             | digit tables, `element-at?`, `index-of?`, a 39-step `fold-left`                                                   |
| Conversions  | `to-ascii?`                                                                                    | `int-to-ascii`, `principal-to-ascii`, `map` with a hex or character table, `concat` with a spread                 |
| Principals   | `principal-construct?`, `principal-destruct?`                                                  | `to-consensus-buff`, `from-consensus-buff?`, `slice?`, `get-current-context`                                      |
| Principals   | `is-current-network`, `is-standard`, `principal-of?`                                           | `principal-destruct?`, `principal-construct?`, `hash160`                                                          |
| Cryptography | `hash160`                                                                                      | `ripemd160`, `sha256`                                                                                             |
| Cryptography | `verify-merkle-proof`                                                                          | `sha256`, `log2`, `fold-left` over the proof                                                                      |
| Storage      | `map-insert?`                                                                                  | `map-get?`, `map-set`                                                                                             |

About forty public definitions, plus `std-*` helpers. Two conventions decide
whether a prelude function is `define-macro` or `define-private`:

- Anything that needs laziness or early exit is a macro: `if` and the early-exit
  family.
- Everything else is private. Private functions are compiled once per instance
  and can be passed to `map`, `filter`, `fold-left`, and `fold-right`.

### Notes on specific definitions

- **Families over integer or sequence kinds.** `pow`, `sqrti`, `log2`,
  `bit-not`, `int-to-ascii`, and `int-to-utf8` are overloaded on `int` and
  `uint`. `replace-at?` is overloaded on the four sequence kinds. `<`, `>`,
  `>=`, `mod`, `max`, `min`, `bit-xor`, `bit-or`, `index-of?`, `string-to-int?`,
  and `string-to-uint?` are single generic definitions checked per instance
  (2.6.2); per-kind constants such as digit tables are selected by small
  overloaded helpers.
- **`pow` does not overflow early.** It squares and multiplies from the most
  significant exponent bit down, so every intermediate is the base raised to a
  prefix of the exponent and no step overflows unless the result does.
- **`verify-merkle-proof`** takes a leaf hash, a root hash, the leaf index, the
  transaction count, and up to 24 sibling hashes from leaf to root, all in
  internal byte order, and uses double SHA-256 with Bitcoin's odd-row
  duplication rule. It returns `false` for any proof inconsistent with the
  canonical tree shape implied by the count: an index not below the count, a
  path length other than the tree depth, or a sibling that must equal its
  partner on an odd row but does not. This contract is enforced by the source;
  it is security-sensitive and needs the densest conformance vectors in the
  library.

### Kept primitive although expressible

The representation-base test names a basis, not a minimal set, so some of its
members could be written in terms of the others or of other primitives: `len`
and `slice?` as folds, `element-at?` through `slice?`, `buff-to-uint-be` as a
fold over the bytes with a binary search for each byte's value, the shifts as
multiplication and division by a table of powers of two, `to-int` and `to-uint`
through the `*-to-buff-*` primitives and deserialization, and comparison on
sequences as a fold. Each derivation needs iteration, a table, or a primitive
outside the base, so these stay core. The test sends to the library what is a
fixed-size expression in the base operations and the special forms: `<`, `>`,
and `>=` over `<=` and `not`, and `bit-xor` and `bit-or` over `bit-and`, `+`,
and `-`.

`secp256k1-verify` can be written with `secp256k1-recover?`, by trying the four
recovery ids against the key. Both are operations the scheme's standard defines,
so both are core by the cryptographic-standard test, which keeps the language
from reimplementing either one in terms of the other.

`principal-construct?` and `principal-destruct?` are library. They build and
slice the principal's encoding (chain ABI 2.2) with `to-consensus-buff` and
`from-consensus-buff?`, whose decoding checks the version byte and the contract
name, and they read the network from `get-current-context` against the prelude's
version-byte constants, as `principal-of?` does. `principal-to-ascii` is also
expressible, since c32check is base-32 text with a double-SHA-256 checksum, but
the derivation needs iteration and a table, so it stays core.

## 4.3 Disposition of every legacy construct

These tables cover every native function, define form, and native variable in
Clarity 6. Constructs with no legacy counterpart are listed in 4.4. The vNEXT
column says what each became:

- **primitive**: stays in the core, with the signature in
  [03-primitives.md](03-primitives.md).
- **form**: a special form of the core language, in
  [02-core-language.md](02-core-language.md). **Allowance forms** are the
  allowance syntax of `as-contract?` and `restrict-assets?` (2.5.9).
- **sugar**: a fixed rewrite into other syntax, with no definition of its own;
  `begin` is `let` with no bindings.
- **literal**: a literal of the lexical grammar (2.2).
- **library**: defined in the prelude, in vNEXT source.
- **removed**: vNEXT has no equivalent by that name; the notes say what to use.

In the notes, **private** and **macro** say how the prelude defines a library
function, not who can call it: every prelude function is in scope in every
contract (2.4.5), and none is callable by `contract-call?`. A private function
is an ordinary function (`define-private`), so all of its arguments are
evaluated once, before the call, as in legacy. A macro (`define-macro`, 2.6.3)
is expanded at the call site and evaluates an argument only where its body uses
it.

### Arithmetic and logic

| Legacy                              | vNEXT     | Notes                                                                             |
| ----------------------------------- | --------- | --------------------------------------------------------------------------------- |
| `+`, `-`, `*`, `/`                  | primitive | rest parameter (2.6.5); at least two arguments, so unary `-` is written `(- 0 x)` |
| `mod`, `pow`, `sqrti`, `log2`       | library   | same results as legacy                                                            |
| `<=`                                | primitive |                                                                                   |
| `>=`, `<`, `>`                      | library   | private, over `<=` and `not`                                                      |
| `to-int`, `to-uint`                 | primitive |                                                                                   |
| `xor`                               | removed   | use `bit-xor`                                                                     |
| `bit-and`                           | primitive | rest parameter                                                                    |
| `bit-xor`                           | library   | rest parameter; `bit-and`, `+`, and `-`                                           |
| `bit-or`                            | library   | rest parameter; `bit-and`, `+`, and `-`                                           |
| `bit-not`                           | library   | all ones minus the value                                                          |
| `bit-shift-left`, `bit-shift-right` | primitive | shift of 128 or more aborts instead of wrapping                                   |
| `and`, `or`                         | form      | two or more arguments, short-circuit                                              |
| `not`                               | library   | private                                                                           |
| `is-eq`                             | primitive | binary only; `(is-eq a b c)` is written `(and (is-eq a b) (is-eq a c))`           |
| `if`                                | library   | macro over `match`                                                                |

### Binding, sequencing, branching, early exit

| Legacy                                       | vNEXT   | Notes                                                                                                                                                                                                                                                                |
| -------------------------------------------- | ------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `let`                                        | form    |                                                                                                                                                                                                                                                                      |
| `begin`                                      | sugar   | `(let () ...)`                                                                                                                                                                                                                                                       |
| `match`                                      | form    | constructor patterns `((some x) ...)`, `(none ...)`, `((ok x) ...)`, `((err e) ...)`, `(true ...)`, `(false ...)`                                                                                                                                                    |
| `asserts!`, `unwrap!`, `unwrap-err!`, `try!` | library | macro over `match` and `return`; `thrown` is evaluated only on failure, which for `unwrap!` and `unwrap-err!` is a change from legacy (legacy evaluates it first); not usable in top-level expressions or constant initializers, where `return` is forbidden (2.4.2) |
| `unwrap-panic`, `unwrap-err-panic`           | library | macro over `match` and `panic`                                                                                                                                                                                                                                       |
| `default-to`                                 | library | private; both arguments evaluated, as in legacy                                                                                                                                                                                                                      |
| `is-ok`, `is-err`, `is-some`, `is-none`      | library | private                                                                                                                                                                                                                                                              |
| `ok`, `err`, `some`                          | form    | constructors                                                                                                                                                                                                                                                         |
| `none`, `true`, `false`                      | literal |                                                                                                                                                                                                                                                                      |

### Sequences

| Legacy                                   | vNEXT     | Notes                                                                  |
| ---------------------------------------- | --------- | ---------------------------------------------------------------------- |
| `list`                                   | form      | variadic, like `and` and `or`; functions use rest parameters           |
| `len`, `concat`, `slice?`, `as-max-len?` | primitive | `concat` has a rest parameter                                          |
| `element-at?`                            | primitive |                                                                        |
| `index-of?`, `replace-at?`               | library   |                                                                        |
| `element-at`, `index-of`                 | removed   | aliases                                                                |
| `append`                                 | library   | `(concat items (list item))`                                           |
| `map`                                    | primitive | single sequence only; multi-sequence form dropped (chapter 3.3)        |
| `filter`                                 | primitive |                                                                        |
| `fold`                                   | removed   | `fold-left` with the callback's parameters swapped (accumulator first) |

### Tuples

| Legacy         | vNEXT   | Notes               |
| -------------- | ------- | ------------------- |
| `tuple`        | removed | use `{ f: v, ... }` |
| `get`, `merge` | form    |                     |

### Conversions and serialization

| Legacy                              | vNEXT     | Notes                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| ----------------------------------- | --------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `buff-to-uint-be`                   | primitive |                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| `buff-to-uint-le`                   | library   | over `buff-to-uint-be`                                                                                                                                                                                                                                                                                                                                                                                                                            |
| `buff-to-int-be`, `buff-to-int-le`  | library   | over `buff-to-uint-be`; a short buffer is sign-extended from its actual length, where legacy zero-padded it (chapter 3.4)                                                                                                                                                                                                                                                                                                                         |
| `int-to-ascii`, `int-to-utf8`       | library   |                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| `string-to-int?`, `string-to-uint?` | library   |                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| `to-consensus-buff?`                | primitive | renamed `to-consensus-buff`, total: legacy's `none` for a result over the value size limit is replaced by the static size limits on the result's position (2.3.1)                                                                                                                                                                                                                                                                                 |
| `from-consensus-buff?`              | primitive |                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| `to-ascii?`                         | library   | six overloads (`int`, `uint`, `bool`, `principal`, `buff`, `string-utf8`) with legacy's text and bounds, except that the principal bound is 82 where legacy's is 170, because contract names are limited to 40 characters (2.2); the principal case uses the new `principal-to-ascii` primitive (chapter 3.5). A `string-utf8` containing U+000C (form feed) is now `err u1`: legacy accepted it, but a vNEXT `string-ascii` cannot hold it (2.2) |

### Principals

| Legacy                 | vNEXT     | Notes                                                                                                                                                                                                  |
| ---------------------- | --------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `principal-construct?` | library   | single signature with `(optional (string-ascii 40))` name; `error_code` and `value` fields renamed `error-code` and `principal`; builds the encoding and decodes it with `from-consensus-buff?`        |
| `principal-destruct?`  | library   | slices `to-consensus-buff`                                                                                                                                                                             |
| `is-standard`          | library   | renamed `is-current-network`, since it tests the version byte against the current network and is true for contract principals too; vNEXT's `is-standard` tests for a standard (not contract) principal |
| `principal-of?`        | library   | `hash160` plus `principal-construct?` with the network's version byte                                                                                                                                  |
| `contract-of`          | removed   | `(trait X) <: principal` (2.3.2), so a trait value is already a principal wherever one is expected; `(as principal t)` states it explicitly                                                            |
| `contract-hash?`       | primitive |                                                                                                                                                                                                        |

### Cryptography

| Legacy                                                            | vNEXT     | Notes                                                                                                                                    |
| ----------------------------------------------------------------- | --------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| `sha256`, `sha512`, `sha512/256`, `keccak256`                     | primitive | buffers only; integer inputs removed                                                                                                     |
| `hash160`                                                         | library   | `ripemd160` of `sha256`, over buffers only; integer inputs removed                                                                       |
| `secp256k1-recover?`, `secp256k1-verify`, `secp256k1-decompress?` | primitive | low-S required; `secp256k1-verify` takes a `(buff 64)` signature only, where legacy also accepted 65 bytes and ignored the recovery byte |
| `secp256r1-verify`, `ed25519-verify`                              | primitive | low-S required for ECDSA                                                                                                                 |
| `verify-merkle-proof`                                             | library   | over `sha256`                                                                                                                            |

### Storage

| Legacy                              | vNEXT     | Notes                                                                                                                                                                                                                                                          |
| ----------------------------------- | --------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `var-get`, `var-set`                | primitive |                                                                                                                                                                                                                                                                |
| `map-get?`, `map-set`, `map-delete` | primitive |                                                                                                                                                                                                                                                                |
| `map-insert`                        | library   | renamed `map-insert?`; returns `(optional V)`: the existing value if the key was present (nothing written), `none` if inserted, where legacy returned `bool`; private, so both arguments are evaluated; written with a `(map K V)` reference parameter (2.3.7) |

### Assets

| Legacy                                                                    | vNEXT     | Notes                                                   |
| ------------------------------------------------------------------------- | --------- | ------------------------------------------------------- |
| `ft-mint?`, `ft-burn?`, `ft-transfer?`, `ft-get-balance`, `ft-get-supply` | primitive |                                                         |
| `nft-mint?`, `nft-burn?`, `nft-transfer?`, `nft-get-owner?`               | primitive |                                                         |
| `stx-transfer?`                                                           | primitive | takes `(optional (buff 34))` memo                       |
| `stx-transfer-memo?`                                                      | removed   | merged into `stx-transfer?`                             |
| `stx-burn?`, `stx-account`                                                | primitive |                                                         |
| `stx-get-balance`                                                         | removed   | `(get unlocked (stx-account p))`; a one-line alias (P6) |

### Calls, context, and allowances

| Legacy                                                                                  | vNEXT           | Notes                                                                                                                     |
| --------------------------------------------------------------------------------------- | --------------- | ------------------------------------------------------------------------------------------------------------------------- |
| `contract-call?`                                                                        | form            |                                                                                                                           |
| `as-contract?`                                                                          | form            |                                                                                                                           |
| `as-contract`                                                                           | removed         | unrestricted asset access                                                                                                 |
| `restrict-assets?`                                                                      | form            | takes `allowance` forms only; `with-all-assets-unsafe` is accepted by `as-contract?` alone, as its only allowance (2.5.9) |
| `with-stx`, `with-ft`, `with-nft`, `with-staking`, `with-pox`, `with-all-assets-unsafe` | allowance forms |                                                                                                                           |
| `with-stacking`                                                                         | removed         | renamed `with-staking` in Clarity 6                                                                                       |
| `at-block`                                                                              | removed         | disabled in legacy since epoch 3.4                                                                                        |
| `print`                                                                                 | primitive       | emits the value's Clarity literal text (3.10), not its SIP-005 encoding                                                   |

### Chain data

| Legacy                                                               | vNEXT     | Notes                                                                                                                                                                                 |
| -------------------------------------------------------------------- | --------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `get-stacks-block-info?`, `get-tenure-info?`, `get-burn-block-info?` | primitive | return the whole record; property-name argument removed; `get-tenure-info?` and `get-burn-block-info?` serve the current tenure and burn block; the `hashbytes` field is `hash-bytes` |
| `get-block-info?`                                                    | removed   | already removed in Clarity 3                                                                                                                                                          |
| `get-bitcoin-tx-output?`                                             | primitive |                                                                                                                                                                                       |

### Define forms

| Legacy                                                | vNEXT   | Notes                                     |
| ----------------------------------------------------- | ------- | ----------------------------------------- |
| `define-constant`, `define-data-var`, `define-map`    | form    |                                           |
| `define-fungible-token`, `define-non-fungible-token`  | form    |                                           |
| `define-public`, `define-read-only`, `define-private` | form    | private may be generic and overloaded     |
| `define-trait`, `impl-trait`                          | form    | trait identifiers replace `<name>` syntax |
| `use-trait`                                           | removed | `(define-type name (trait id))`           |

### Native variables

| Legacy                                                                           | vNEXT   | Notes                                                                                                                                        |
| -------------------------------------------------------------------------------- | ------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| `tx-sender`, `contract-caller`, `tx-sponsor?`, `current-contract`                | removed | fields `sender`, `caller`, `sponsor`, `contract` of `(get-current-context)` (3.9); `(get sender (get-current-context))` replaces `tx-sender` |
| `burn-block-height`, `stacks-block-height`, `tenure-height`, `stacks-block-time` | removed | fields `burn-height`, `stacks-height`, `tenure-height`, `time` of `(get-current-context)`                                                    |
| `chain-id`, `is-in-mainnet`, `is-in-regtest`, `stx-liquid-supply`                | removed | fields `chain-id`, `is-mainnet`, `is-regtest`, `liquid-supply` of `(get-current-context)`                                                    |
| `block-height`                                                                   | removed | already removed in Clarity 3                                                                                                                 |
| `none`, `true`, `false`                                                          | literal |                                                                                                                                              |

## 4.4 New in vNEXT

Constructs with no legacy counterpart, with the kinds of 4.3:

| Construct                                                                                                  | Kind      | Notes                                                                                                                                 |
| ---------------------------------------------------------------------------------------------------------- | --------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| `clarity-version`                                                                                          | form      | required first form of every contract (2.4.0); replaces the `clarity_version` field of the legacy deploy transaction                  |
| `define-type`                                                                                              | form      | transparent type aliases (2.3.6); replaces `use-trait`                                                                                |
| `define-macro`                                                                                             | form      | call-by-name, expanded at each call site (2.6.3)                                                                                      |
| rest parameters `(name T...)`                                                                              | form      | private functions only; the rest arguments are bound as a list (2.6.5)                                                                |
| `return`                                                                                                   | form      | exits the enclosing function with a value (2.5.4); the library's early-exit functions are defined with it                             |
| `as`                                                                                                       | form      | type ascription; widens, never narrows (2.5.10)                                                                                       |
| reference kinds `(var ...)`, `(map ...)`, `(fungible-token)`, `(non-fungible-token ...)`, `(function ...)` | form      | parameters that name a definition of the contract rather than hold a value (2.3.7)                                                    |
| `panic`                                                                                                    | primitive | aborts the transaction (3.10); the library's `unwrap-panic` and `unwrap-err-panic` are defined with it                                |
| `fold-left`, `fold-right`                                                                                  | primitive | replace legacy `fold` (3.3)                                                                                                           |
| `uint-to-buff-be`, `uint-to-buff-le`, `int-to-buff-be`, `int-to-buff-le`                                   | primitive | fixed width, abort if the value does not fit (3.4, issue #7312)                                                                       |
| `principal-to-ascii`                                                                                       | primitive | the text form of a principal (3.5)                                                                                                    |
| `get-current-context`                                                                                      | primitive | one record for the whole execution context, replacing the legacy native variables (3.9); the twelve bare names are no longer reserved |
| `max`, `min`, `abs`                                                                                        | library   | common user-written helpers; `max` and `min` take rest parameters                                                                     |

Further candidates from the issue tracker are collected in
[../06-issue-tracker.md](../06-issue-tracker.md).

## 4.5 Open questions

1. **User overloads of prelude names.** 2.4.5 forbids a contract from defining
   any name the prelude defines, which also forbids adding an overload, such as
   `to-ascii?` for a contract's own tuple type. Allowing overloads of prelude
   names, while still forbidding redefinition of an existing overload, would be
   backward compatible to add later and is left out of this draft.
