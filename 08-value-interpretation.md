# Value Interpretation Proposal

This is the interpretation layer of the chain ABI, the companion to
[07-chain-abi.md](07-chain-abi.md), which is the runtime layer. The runtime
layer passes a contract's arguments, results, storage, and `print` messages
through as bytes and never interprets them (chain ABI R1). This document says
what those bytes mean: the types a contract declares, how values of those types
are encoded, and what compilers, wallets, explorers, and indexers may rely on.

The chain enforces nothing here, with one exception: a call between a legacy and
a Wasm contract converts values by the encoding of section 3 (chain ABI 13,
question 4). A module that ignores this document deploys and runs, but tools can
then describe its functions only as taking and returning bytes. References of
the form "chain ABI 5.2" are to sections of [07-chain-abi.md](07-chain-abi.md).

## 1. The two layers

| Value                                                | Chain ABI (runtime)                                                        | This document                           |
| ---------------------------------------------------- | -------------------------------------------------------------------------- | --------------------------------------- |
| Interface                                            | reads function names and kinds, and token names (4.1)                      | typed signatures and traits (5)         |
| Arguments                                            | passes the bytes to the callee unchanged (5.2)                             | their types (5) and layout (6.1, 6.4)   |
| Results                                              | passes the bytes and the result flag; the flag closes a public frame (5.2) | their types (5) and encoding (6.2, 6.4) |
| Storage                                              | stores bytes under byte keys (4.2)                                         | its declared layout (7.2)               |
| `print` messages                                     | records UTF-8 text (6.2)                                                   | how a language renders values (7.1)     |
| NFT identifiers                                      | stores and compares bytes (6.2)                                            | their declared type (7.3)               |
| Host values: principals, `u128` words, and raw bytes | defines them and acts on them (2)                                          | nothing                                 |

The host's one structured value is a principal, and its encoding (chain ABI 2.2)
is the same bytes as a `principal` value here, so a principal reads the same in
both layers.

## 2. Types

```
type ::= int | uint | bool | principal | never
       | (buff N) | (string-ascii N) | (string-utf8 N)
       | (list N type) | (optional type) | (response type type)
       | { name: type, ... }
       | (trait trait-ref)
trait-ref ::= contract-principal "." name
```

| Type               | Values                                                   |
| ------------------ | -------------------------------------------------------- |
| `int`              | signed 128-bit integers                                  |
| `uint`             | unsigned 128-bit integers                                |
| `bool`             | `true`, `false`                                          |
| `principal`        | standard or contract principals                          |
| `never`            | none                                                     |
| `(buff N)`         | byte sequences of length at most `N`                     |
| `(string-ascii N)` | at most `N` bytes from the ASCII set of section 3        |
| `(string-utf8 N)`  | UTF-8 strings of at most `N` code points                 |
| `(list N T)`       | sequences of at most `N` values of `T`                   |
| `(optional T)`     | `none`, or `(some v)` with `v` of `T`                    |
| `(response T E)`   | `(ok v)` with `v` of `T`, or `(err e)` with `e` of `E`   |
| `{ f: T, ... }`    | records with exactly the listed fields                   |
| `(trait X)`        | contract principals, meant to conform to trait `X` (5.2) |

A contract declares the type of each parameter and result of its functions, of
each function of its traits, and of each NFT's identifiers in this grammar
(section 5). A source language maps its own types onto it.

- Every type is closed: no type variables, no unknown parts (chain ABI R3).
- `never` may appear anywhere a type may. A position of type `never` can hold
  nothing, so a function can declare, for example, that it never returns `err`.
- Tuples have exact field sets (chain ABI R2). Zero-field tuples are allowed.
- Parameter and tuple-field names follow the rules for function names (chain ABI
  2.1).

A `(trait X)` names trait `X` by its defining contract and its name (5.2). Its
values are contract principals; that a value conforms to `X` is the declaring
contract's expectation, which only the receiving module checks (chain ABI 5.4).

**Subtyping** on declared types is the smallest reflexive, transitive relation
such that:

- `never <: T` for every `T`.
- `(buff N) <: (buff M)`, `(string-ascii N) <: (string-ascii M)`, and
  `(string-utf8 N) <: (string-utf8 M)` when `N <= M`.
- `(list N S) <: (list M T)` when `N <= M` and `S <: T`.
- `(optional S) <: (optional T)` when `S <: T`.
- `(response S1 S2) <: (response T1 T2)` when `S1 <: T1` and `S2 <: T2`.
- `{ f1: S1, ... } <: { f1: T1, ... }` when both have exactly the same field
  names and `Si <: Ti` for every field.
- `(trait X) <: (trait Y)` when every function of `Y` is a function of `X` with
  an identical signature (structural sub-trait).
- `(trait X) <: principal`.

It is used for trait conformance (5.2). A language may have more rules for its
own source types, such as Clarity's contract literal types (spec 2.3.2), but a
declared type is in this grammar, and these rules relate declared types.

## 3. Canonical encoding

The encoding is SIP-005, byte for byte, for every value that exists in legacy,
so values pass between legacy and Wasm contracts and between the chain and
existing tooling without translation. What changes from legacy is decoding,
which accepts only the canonical form.

| Prefix | Value              | Payload                                                         |
| ------ | ------------------ | --------------------------------------------------------------- |
| `0x00` | `int`              | 16 bytes, two's complement, big-endian                          |
| `0x01` | `uint`             | 16 bytes, big-endian                                            |
| `0x02` | `buff`             | u32 BE length, bytes                                            |
| `0x03` | `true`             |                                                                 |
| `0x04` | `false`            |                                                                 |
| `0x05` | standard principal | as chain ABI 2.2                                                |
| `0x06` | contract principal | as chain ABI 2.2                                                |
| `0x07` | `(ok v)`           | encoding of `v`                                                 |
| `0x08` | `(err v)`          | encoding of `v`                                                 |
| `0x09` | `none`             |                                                                 |
| `0x0A` | `(some v)`         | encoding of `v`                                                 |
| `0x0B` | list               | u32 BE element count, elements                                  |
| `0x0C` | tuple              | u32 BE field count, then per field: u8 name length, name, value |
| `0x0D` | `string-ascii`     | u32 BE byte length, bytes                                       |
| `0x0E` | `string-utf8`      | u32 BE byte length, UTF-8 bytes                                 |

**Canonical decoding** of bytes `b` against type `T` succeeds if and only if `b`
is exactly the encoding of some value of `T`:

- the prefix is one that `T` admits; `principal` admits `0x05` and `0x06`, and
  `(trait X)` admits only `0x06`;
- lengths and counts are within `T`'s bounds; `string-utf8` bounds count code
  points;
- tuple fields are exactly `T`'s fields, in strictly ascending byte order of
  name, with no duplicates;
- `string-ascii` bytes are 0x20–0x7E, tab, line feed, or carriage return (legacy
  also admits form feed), and `string-utf8` bytes are valid UTF-8 (no
  surrogates, no overlong forms);
- principals decode as chain ABI 2.2 requires;
- nesting depth is at most 32, counted the same way everywhere;
- no bytes remain after the value.

There is no sanitizing and no untyped decoding. Self-describing prefixes are
kept for tooling, but every decode is against a type.

## 4. Sizes and type encoding

### 4.1 Sizes

`serialized-size(T)` is the largest canonical encoding of any value of `T`:

| Type                           | `serialized-size`              |
| ------------------------------ | ------------------------------ |
| `int`, `uint`                  | 17                             |
| `bool`                         | 1                              |
| `principal`, `(trait X)`       | 63 (1 + 1 + 20 + 1 + 40)       |
| `never`                        | 0                              |
| `(buff N)`, `(string-ascii N)` | 5 + N                          |
| `(string-utf8 N)`              | 5 + 4N                         |
| `(list N T)`                   | 5 + N × size(T)                |
| `(optional T)`                 | 1 + size(T)                    |
| `(response T E)`               | 1 + max(size(T), size(E))      |
| `{ f1: T1, ... }`              | 5 + Σ (1 + len(fi) + size(Ti)) |

The **value size limit**, 1 MiB, is a limit on `serialized-size`. It matches the
chain's byte limits on arguments, results, and NFT identifiers (chain ABI 9.3),
so every value of a declared type fits them. Legacy measures a separate abstract
"size" that disagrees with the bytes (a principal is 148 there and up to 151 on
the wire); this layer has one measure.

A caller can size its buffer for a callee's result from `serialized-size` of the
declared result type (chain ABI 5.3).

### 4.2 Type encoding

Types are encoded in binary, reusing the value prefixes:

| Tag    | Type               | Payload                                     |
| ------ | ------------------ | ------------------------------------------- |
| `0x00` | `int`              |                                             |
| `0x01` | `uint`             |                                             |
| `0x02` | `(buff N)`         | u32 BE `N`                                  |
| `0x03` | `bool`             |                                             |
| `0x05` | `principal`        |                                             |
| `0x07` | `(response T E)`   | `T`, `E`                                    |
| `0x0A` | `(optional T)`     | `T`                                         |
| `0x0B` | `(list N T)`       | u32 BE `N`, `T`                             |
| `0x0C` | tuple              | u32 BE count, per field: name, type; sorted |
| `0x0D` | `(string-ascii N)` | u32 BE `N`                                  |
| `0x0E` | `(string-utf8 N)`  | u32 BE `N`                                  |
| `0x11` | `never`            |                                             |
| `0x12` | `(trait X)`        | trait reference                             |

Names are a u8 length and the bytes. A trait reference is the defining
contract's principal (chain ABI 2.2, prefix `0x06`), then the trait's name. Like
a value, a type has exactly one encoding.

## 5. The `abi.types` section

### 5.1 Contents

A module declares its types in the `abi.types` custom section (chain ABI 3.4),
one canonically encoded record:

| Field        | Contents                                                                                            |
| ------------ | --------------------------------------------------------------------------------------------------- |
| `version`    | the version of this format (section 8)                                                              |
| `functions`  | per function: name, parameters (name, type), result type                                            |
| `nfts`       | per non-fungible token: name, identifier type                                                       |
| `traits`     | per trait the contract defines: name, then per function: name, kind, parameter types, result type   |
| `implements` | the trait references of the traits the contract claims to conform to                                |
| `storage`    | per variable or map (not per value): name, kind, key prefix, key type (maps only), value type (7.2) |

Rules:

- Types are in the encoding of 4.2. Names are unique within each list, and lists
  are sorted by name, or `implements` by encoded bytes, so the section has one
  hash: `sha512/256` of its bytes. Provenance records it for each callee,
  alongside the hash of the callee's `abi.interface`
  ([03-architecture.md](03-architecture.md) section 2).
- `functions` and `nfts` name functions and NFTs of the module's `abi.interface`
  (chain ABI 4.1), not necessarily all of them. A function or NFT left out is
  undeclared (6.4, 7.3).
- A `public` function's result type is a `response`, whose arms describe the
  result for each value of the flag that `result_set` takes (chain ABI 5.2). A
  `read-only` function's result type is any type. The same holds for the
  functions of a trait, by the kind the trait gives them.
- At most 256 parameters per function, in `functions` and in traits, as legacy.
- No declared type's `serialized-size` exceeds the value size limit (4.1), and
  no type nests deeper than 32.
- `storage` follows the rules of 7.2.

### 5.2 Traits

A trait is a named set of function signatures: per function, a name, a kind
(`public` or `read-only`), parameter types, and a result type. A contract
defines traits in `traits`, and a declared type names one with `(trait X)`,
where `X` is the defining contract's principal and the trait's name. A contract
can name its own traits.

A contract **conforms** to trait `X` if, for every function `f` of `X`, its
`abi.types` declares a function `f` with the same number of parameters, such
that:

- if `X` marks `f` `read-only`, the contract's `f` is `read-only` (chain ABI
  4.1); otherwise it may be either kind;
- each of `X`'s parameter types is a subtype (section 2) of the contract's
  parameter type in the same position;
- the contract's result type is a subtype of `X`'s.

This is the rule of Clarity's `impl-trait` (spec 2.4.1), stated over declared
types so that every language and tool applies the same one. Conformance is
structural: `implements` is a claim that a tool can check against this rule, not
a condition of conforming.

A compiler reads a trait's definition from the defining contract's `abi.types`,
and provenance records that section's hash (5.1), so a build that uses another
contract's trait reproduces. A wallet can label a trait-typed argument with its
trait and check that the principal it names conforms.

### 5.3 Validity and trust

Outside the legacy bridge (chain ABI 13, question 4), the chain checks only that
the section fits the module size limit; it does not decode it. A section that
breaks the rules of 5.1 is malformed, and tools treat it as absent: every
function and NFT of a module without a usable section is undeclared. A compiler
refuses to compile a typed call to an undeclared function, but an untyped call
(6.4) needs no declaration.

Nothing ties a declaration to what the module does. The chain does not check
values against declared types (chain ABI 5.4), so a module can declare one type
and accept or return another, or declare a function that conforms to a trait in
signature but not in behavior. A declaration is the author's claim, as a source
file is; provenance and `clarity-verify`
([03-architecture.md](03-architecture.md) section 2) are how a tool checks that
a module was compiled from a source that declares those types.

## 6. Arguments and results

Sections 6.1 to 6.3 apply to declared functions, and 6.4 to undeclared ones.

### 6.1 Arguments

A caller passes a declared function's arguments as the canonical encoding of
each argument against its declared parameter type, concatenated in parameter
order. There is no count and no framing: a decoder walks the parameter list,
decoding each value where the previous one ended, and the arguments are
well-formed only if every value decodes and no bytes remain.

This is the layout of a contract-call transaction's argument bytes (chain ABI
12, item 8), of a read-only query's, and of the `args` of a `call` (chain ABI
5.3).

### 6.2 Results

For a declared `public` function, the result bytes are the canonical encoding of
a value of the arm of the declared `response` that the result flag selects: `T`
for ok, `E` for err. A tool shows them as `(ok v)` or `(err v)`. For a
`read-only` function, they are the canonical encoding of a value of the declared
result type.

### 6.3 Who relies on this

Wallets encode arguments and clear-sign transactions from the declared types,
explorers decode results with them, and compilers type calls against them.

Because the chain does not check values (chain ABI 5.4), a tool can meet bytes
that do not decode against their declared type: the arguments of a transaction
that then failed validation in the module, or the result of a module that does
not follow its declaration. A tool decodes with canonical decoding against the
declared type and, where that fails, shows the raw bytes as such rather than
presenting a guess as a typed value.

### 6.4 Undeclared functions

A function with no entry in `functions` is **undeclared**. Its arguments are one
raw byte string and its result is a raw byte string, with the result flag as for
any function (chain ABI 5.2). Neither carries a prefix or a length header, and
the callee's language decides what the bytes mean.

A caller passes the bytes it has as `args` and reads the result as bytes,
bounding its length itself (chain ABI 5.3). A typed language exposes this as an
untyped call whose argument and result are byte buffers, which its compiler
cannot check against the callee. A wallet can send a call to an undeclared
function built from raw bytes but cannot clear-sign it, and an explorer shows
its arguments and result as hex.

This differs from declaring `(buff N)`. A declared `(buff N)` parameter or
result is canonically encoded, with its prefix and length (section 3), and gives
tools a signature to show. A language with no use for structured values can do
either; leaving its functions undeclared costs it clear-signing.

## 7. Events, storage, and identifiers

### 7.1 `print` messages

A `print` message is UTF-8 text that the chain records without interpreting it
(chain ABI 6.2). Each source language defines how it renders a value as text;
the Clarity spec will define Clarity's (chain ABI 12, item 5). Legacy `print`
events carry the printed value in SIP-005 encoding, so a tool that shows both
decodes legacy events as values and Wasm events as text.

### 7.2 Storage

Contract storage is an untyped key-value store (chain ABI 4.2), so state is not
self-describing: an explorer, a wallet, or the node's state read endpoint
returns raw bytes. The `storage` field of `abi.types` (5.1) makes it readable
without knowing the contract's language. It holds one declaration per variable
or map. Each declaration has a key prefix, a non-empty byte string the language
chooses, and fixes where its values live in the store:

| Declaration | Store key                                                     | Store value                             |
| ----------- | ------------------------------------------------------------- | --------------------------------------- |
| variable    | the prefix                                                    | canonical encoding of the value         |
| map         | per entry: the prefix, then the canonical encoding of the key | canonical encoding of the entry's value |

A map has an entry for a key exactly when the store has a value under the store
key for that key; a missing entry is the absence of that store key, not a stored
marker. Rules:

- No declaration's prefix is a prefix of another's, so every store key belongs
  to at most one declaration.
- The prefix plus the `serialized-size` of the key type fits the storage key
  limit, and the value type's `serialized-size` fits the storage value limit
  (chain ABI 9.3).

A store key that belongs to no declaration is undeclared, and a tool shows it
and its value as raw bytes. A language whose layout differs from this one leaves
its storage undeclared, as it can leave functions undeclared (6.4); the Clarity
compiler declares every data variable and map (chain ABI 12, item 3). Like any
declaration, `storage` is a claim: nothing stops a module from writing other
bytes under a declared key, and a tool that cannot decode a store value shows it
raw (6.3).

### 7.3 NFT identifiers

The chain stores and compares NFT identifiers as bytes (chain ABI 6.2). The
identifier bytes are the canonical encoding of a value of the token's declared
identifier type (section 5), so a tool displays identifiers by that type, and a
post-condition names an identifier by the same bytes. The Clarity compiler
encodes identifiers this way, so a Clarity token's identifiers have the same
bytes as in legacy (chain ABI 12, item 6). An undeclared NFT's identifiers are
raw bytes, which a tool shows as hex.

## 8. Versioning

The chain does not read the declared types outside the legacy bridge, so this
layer is versioned on its own. The `abi.types` section's `version` field names
its format; the first is `1`. A new version may add fields or types without a
new ABI version (chain ABI 11), and a tool supports every version it may meet. A
new type gets a new prefix. The encoding of an existing type never changes: the
legacy bridge converts values by it (chain ABI 13, question 4), and so does
every existing tool.

## 9. Open questions

1. **Whether the chain validates `abi.types` for every contract.** The legacy
   bridge already needs the section validated for any contract a legacy contract
   can call (chain ABI 13, question 4), and any Wasm contract can be passed to a
   legacy contract as a trait-typed argument. Validating every section at deploy
   would let every tool trust that it is well-formed and matches the interface,
   instead of each checking for itself. Against it: deploy gains a type decoder
   for a section the chain otherwise ignores, and a valid declaration still says
   nothing about the values a module accepts (section 5).
