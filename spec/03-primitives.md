# 3. Primitive Operations

This chapter enumerates every primitive in the vNEXT core. A primitive is an
operation that passes the layering rule in [README.md](README.md): it needs the
host, it cannot be expressed in the language, it is a cryptographic standard, or
it is a base operation on a type's representation. Everything a contract author
uses that is not listed here or in the special forms of
[02-core-language.md](02-core-language.md) is a standard-library definition.

Every primitive has a declared arity (P6). A signature whose last parameter is
written `I...` or `S...` has a rest parameter (2.6.5): the primitive takes its
fixed arguments plus one or more further arguments, or a single spread list
(2.6.5), and the result is the left fold of the operation over them, so
`(- a b c)` is `(- (- a b) c)`, `(- a b)` is ordinary subtraction, and
`(+ 0 xs...)` is the sum of `xs`. Passed as a function argument, such a
primitive is its two-argument operation: `(fold-left + 0 xs)`.

Notation otherwise follows 2.1: uppercase letters are type or size variables;
"for `I` in {...}" denotes a family with one signature per listed type.
Subtyping (2.3.2) applies to arguments, so a `(buff 4)` is accepted where
`(buff 16)` is written.

Each entry gives the signature, semantics, and error conditions. Primitives have
no cost entries (P4). A primitive the compiler lowers to Wasm costs the fuel of
that code; a primitive that calls a host function is charged by the chain ABI.
Which primitives are host functions is decided by the chain ABI and the
compilation chapter, not here.

## 3.1 Arithmetic

For `I` in {`int`, `uint`}:

| Primitive         | Signature       | Semantics                                                                                   | Runtime errors           |
| ----------------- | --------------- | ------------------------------------------------------------------------------------------- | ------------------------ |
| `+`               | `(I I...) -> I` | addition                                                                                    | overflow                 |
| `-`               | `(I I...) -> I` | subtraction                                                                                 | overflow/underflow       |
| `*`               | `(I I...) -> I` | multiplication                                                                              | overflow                 |
| `/`               | `(I I...) -> I` | division truncating toward zero                                                             | divisor is zero; overflow (the most negative `int` divided by `-1`) |
| `to-int`          | `(uint) -> int` | conversion                                                                                  | argument at least 2^127  |
| `to-uint`         | `(int) -> uint` | conversion                                                                                  | argument negative        |
| `bit-and`         | `(I I...) -> I` | bitwise and                                                                                 |                          |
| `bit-or`          | `(I I...) -> I` | bitwise or                                                                                  |                          |
| `bit-xor`         | `(I I...) -> I` | bitwise exclusive or                                                                        |                          |
| `bit-shift-left`  | `(I uint) -> I` | shift left, discarding bits shifted out; the result reinterprets the 128-bit pattern as `I` | shift amount 128 or more |
| `bit-shift-right` | `(I uint) -> I` | shift right; arithmetic for `int`, logical for `uint`                                       | shift amount 128 or more |

Library, not primitive: `mod`, `pow`, `sqrti`, `log2`, `bit-not`, `max`, `min`,
`abs`. Their error conditions are the same as legacy and are defined by their
source.

## 3.2 Comparison and equality

For `C` in {`int`, `uint`, `(buff N)`, `(string-ascii N)`, `(string-utf8 N)`}:

| Primitive            | Signature       | Semantics                                                          |
| -------------------- | --------------- | ------------------------------------------------------------------ |
| `<`, `<=`, `>`, `>=` | `(C C) -> bool` | numeric order for integers; lexicographic byte order for sequences |

| Primitive | Signature       | Semantics                                                                                                  |
| --------- | --------------- | ---------------------------------------------------------------------------------------------------------- |
| `is-eq`   | `(T T) -> bool` | structural equality. Both arguments are admitted at `lub` of their types; an undefined lub is a type error |

## 3.3 Sequences

`S` ranges over the four sequence kinds; `S[N]` is that kind with bound `N`;
`elem(S)` is its element type (2.3.1). All sequence primitives are
kind-preserving: a `concat` of two buffers is a buffer.

| Primitive     | Signature                                     | Semantics                                                                                                                                                               | Runtime errors |
| ------------- | --------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------- |
| `len`         | `(S[N]) -> uint`                              | current length (code points for `string-utf8`)                                                                                                                          |                |
| `concat`      | `(S[N] S[M]...) -> S[N + M1 + ... + Mk]`      | concatenation, left to right; with rest arguments of bounds `M1 ... Mk`, the bound is their exact sum plus `N`. With a spread `(list K S[M])`, the bound is `N + K × M` |                |
| `element-at?` | `(S[N] uint) -> (optional elem(S))`           | element at zero-based index, or `none` if out of range                                                                                                                  |                |
| `slice?`      | `(S[N] uint uint) -> (optional S[N])`         | elements in `[left, right)`; `none` if `left > right` or `right > len`                                                                                                  |                |
| `as-max-len?` | `(S[N] size) -> (optional S[M])`              | the second argument is a size term `M` (2.3.1); `(some s)` if `len(s) <= M`, else `none`                                                                                |                |
| `map`         | `((function (elem(S)) U) S[N]) -> (list N U)` | applies the function to each element in order                                                                                                                           |                |
| `filter`      | `((function (elem(S)) bool) S[N]) -> S[N]`    | keeps elements for which the function returns `true`, preserving order                                                                                                  |                |
| `fold-left`   | `((function (A elem(S)) A) A S[N]) -> A`      | `(f (f (f init x1) x2) ... xn)`: elements left to right, accumulator first                                                                                              |                |
| `fold-right`  | `((function (elem(S) A) A) S[N] A) -> A`      | `(f x1 (f x2 ... (f xn init)))`: elements right to left, accumulator second                                                                                             |                |

In both folds the initial value sits on the same side as the accumulator in the
callback, so the argument order of the call mirrors the order of the callback's
parameters. Neither fold can be written from the other: that needs a wrapper
that swaps `f`'s arguments, and a function cannot be closed over. Legacy `fold`
(left to right, element first) is removed; it is `fold-left` with the callback's
parameters swapped.

Library, not primitive: `append`, `index-of?`, `replace-at?`. Legacy
multi-sequence `map` (`(map f l1 l2)`) is dropped. It cannot be written in the
library, because a fold would have to carry `f` in its accumulator.

## 3.4 Conversions and serialization

| Primitive              | Signature                          | Semantics                                                                                                                                                                                                                                                                                                  | Runtime errors                         |
| ---------------------- | ---------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------- |
| `buff-to-uint-be`      | `((buff 16)) -> uint`              | big-endian unsigned interpretation; the empty buffer is `u0`                                                                                                                                                                                                                                               |                                        |
| `uint-to-buff-be`      | `(uint size) -> (buff W)`          | the second argument is a size term `W` (2.3.1), at most 16; big-endian encoding in exactly `W` bytes                                                                                                                                                                                                       | value does not fit in `W` bytes        |
| `uint-to-buff-le`      | `(uint size) -> (buff W)`          | little-endian counterpart                                                                                                                                                                                                                                                                                  | value does not fit                     |
| `int-to-buff-be`       | `(int size) -> (buff W)`           | two's-complement big-endian encoding in exactly `W` bytes                                                                                                                                                                                                                                                  | value does not fit in `W` signed bytes |
| `int-to-buff-le`       | `(int size) -> (buff W)`           | little-endian counterpart                                                                                                                                                                                                                                                                                  | value does not fit                     |
| `to-consensus-buff`    | `(T) -> (buff serialized-size(T))` | SIP-005 serialization of the value. Total: the size limits apply to the result through its position (2.3.1), so a serialization that is only hashed or compared is bounded by the intermediate limit, and one that is bound, returned, or stored by the value limit, both statically. `T` MUST be storable |                                        |
| `from-consensus-buff?` | `(type (buff N)) -> (optional T)`  | the first argument is a type expression `T`, which MUST be storable. Deserializes; `none` if the bytes are not a canonical encoding of a value of type `T` (exact typed-tuple fields, no trailing bytes). Memory for the result is reserved against `serialized-size(T)` before decoding (2.7.7)           |                                        |

`serialized-size(T)` is a type-level size function defined with the wire format
in the chain ABI.

`buff-to-uint-be` and `uint-to-buff-be` are the base conversions between
integers and bytes. The `*-to-buff-*` family stays primitive because each takes
a size argument, which a library function cannot. Library, not primitive:
`buff-to-uint-le`, `buff-to-int-be`, `buff-to-int-le`, `int-to-ascii`,
`int-to-utf8`, `string-to-int?`, `string-to-uint?`, and `to-ascii?`, with the
same signatures as legacy. All but the signed buffer conversions also have the
same results. `buff-to-int-be` and `buff-to-int-le` sign-extend from the
buffer's actual length, so `(buff-to-int-be 0xff)` is `-1`; legacy zero-pads a
short buffer and returns `255`, which makes the signed conversion of a short
buffer disagree with the same bytes in a 16-byte buffer. This is a deliberate
change, listed in the footguns table of chapter 1 and the disposition table of
chapter 4.

The four `*-to-buff-*` primitives have no legacy counterpart. They are the write
direction of the `buff-to-*` family, requested for hashing structured data
(Merkle leaves, transcripts, commitments); legacy contracts slice the
type-tagged output of `to-consensus-buff` instead, which is fragile and aliases
values that share low bytes. Rejecting values that do not fit closes that
aliasing class at the language level.

## 3.5 Principals

| Primitive              | Signature                                                                                                                         | Semantics                                                                                                                                                                                                                                                                                            |
| ---------------------- | --------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `principal-construct?` | `((buff 1) (buff 20) (optional (string-ascii 40))) -> (response principal { error-code: uint, principal: (optional principal) })` | builds a standard principal (no name) or contract principal (with name) from a version byte and hash bytes. `(err {error-code: u0, principal: (some p)})` if the version byte is valid but for the other network; `u1` if the version byte is invalid; `u2` if the name is not a valid contract name |
| `principal-destruct?`  | `(principal) -> (response D D)` where `D = { hash-bytes: (buff 20), name: (optional (string-ascii 40)), version: (buff 1) }`      | decomposes a principal. `ok` if the version byte matches the current network, `err` with the same payload otherwise                                                                                                                                                                                  |
| `principal-to-ascii`   | `(principal) -> (string-ascii 82)`                                                                                                | the principal's text form: the c32check address of a standard principal, or the address, `.`, and the name of a contract principal (41 for the address, 1 for the dot, 40 for the name)                                                                                                              |
| `contract-hash?`       | `(principal) -> (response (buff 32) uint)`                                                                                        | SHA-512/256 of the deployed contract's module; `err u1` if the principal is not a deployed contract. The chain never holds source; the source hash is available from the module's provenance section, off chain                                                                                      |

Library, not primitive: `is-current-network`, `is-standard`, `principal-of?`.

`principal-to-ascii` is new. It is the principal case of `to-ascii?`, which is
otherwise library (3.4). It stays in the host because c32check is a chain
address encoding that wallets and explorers must match byte for byte.

## 3.6 Cryptography

Hash functions accept buffers only (P6, footguns table). Library, not primitive:
`verify-merkle-proof`, a composition of `sha256` (chapter 4).

| Primitive               | Signature                                            | Semantics                                                                                                                                                   |
| ----------------------- | ---------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `hash160`               | `((buff N)) -> (buff 20)`                            | RIPEMD-160 of SHA-256                                                                                                                                       |
| `sha256`                | `((buff N)) -> (buff 32)`                            | SHA-256                                                                                                                                                     |
| `sha512`                | `((buff N)) -> (buff 64)`                            | SHA-512                                                                                                                                                     |
| `sha512/256`            | `((buff N)) -> (buff 32)`                            | SHA-512/256 (distinct IV; not a truncation of SHA-512)                                                                                                      |
| `keccak256`             | `((buff N)) -> (buff 32)`                            | Keccak-256                                                                                                                                                  |
| `secp256k1-recover?`    | `((buff 32) (buff 65)) -> (response (buff 33) uint)` | recovers the compressed public key from a message hash and a recoverable signature; `err u1` malformed or non-canonical signature, `err u2` recovery failed |
| `secp256k1-verify`      | `((buff 32) (buff 64) (buff 33)) -> bool`            | verifies a 64-byte signature against a compressed public key; `false` for a signature that is not exactly 64 bytes or is non-canonical. A recoverable signature is verified by dropping its recovery byte with `slice?` |
| `secp256k1-decompress?` | `((buff 33)) -> (response (buff 65) uint)`           | uncompressed form of a compressed public key                                                                                                                |
| `secp256r1-verify`      | `((buff 32) (buff 64) (buff 33)) -> bool`            | P-256 signature verification; `false` for a non-canonical signature                                                                                         |
| `ed25519-verify`        | `((buff N) (buff 64) (buff 32)) -> bool`             | Ed25519 signature verification over an arbitrary-length message                                                                                             |

**Canonical signatures.** An ECDSA signature (secp256k1 or P-256) is canonical
only if its `S` component is in the lower half of the curve order (low-S). The
verify primitives MUST return `false`, and `secp256k1-recover?` MUST return
`err u1`, for a non-canonical signature. Accepting both `S` and `n - S` would
let anyone replay a signature-gated authorization with a different signature
encoding.

## 3.7 Contract storage

| Primitive    | Signature                       | Semantics                                       |
| ------------ | ------------------------------- | ----------------------------------------------- |
| `var-get`    | `((var T)) -> T`                | current value                                   |
| `var-set`    | `((var T) T) -> bool`           | stores the value; returns `true`                |
| `map-get?`   | `((map K V) K) -> (optional V)` | lookup                                          |
| `map-set`    | `((map K V) K V) -> bool`       | inserts or overwrites; returns `true`           |
| `map-delete` | `((map K V) K) -> bool`         | removes the entry; returns `true` if it existed |

Library, not primitive: `map-insert?` (`map-get?` then `map-set`). A membership
test is `(is-some (map-get? m k))`; a compiler MAY lower it to an existence
check that does not read the value, since the result is identical (P5).

## 3.8 Assets

All asset primitives record movements in the transaction's asset map (for
post-conditions and allowances) and emit events.

| Primitive        | Signature                                                                 | Semantics                                                                                  | `err` codes                                                                                                         |
| ---------------- | ------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------- |
| `ft-mint?`       | `((fungible-token) uint principal) -> (response bool uint)`               | mints `amount` to the recipient; exceeding the supply cap is a runtime error, as in legacy | `u1` amount is zero                                                                                                 |
| `ft-burn?`       | `((fungible-token) uint principal) -> (response bool uint)`               | burns `amount` from the owner                                                              | `u1` insufficient balance or amount is zero                                                                         |
| `ft-transfer?`   | `((fungible-token) uint principal principal) -> (response bool uint)`     | moves `amount` from sender to recipient                                                    | `u1` insufficient balance; `u2` sender is recipient; `u3` amount is zero                                            |
| `ft-get-balance` | `((fungible-token) principal) -> uint`                                    | balance                                                                                    |                                                                                                                     |
| `ft-get-supply`  | `((fungible-token)) -> uint`                                              | circulating supply                                                                         |                                                                                                                     |
| `nft-mint?`      | `((non-fungible-token T) T principal) -> (response bool uint)`            | mints the identifier to the recipient                                                      | `u1` already exists                                                                                                 |
| `nft-burn?`      | `((non-fungible-token T) T principal) -> (response bool uint)`            | burns the identifier owned by the owner                                                    | `u1` not owned by owner; `u3` does not exist                                                                        |
| `nft-transfer?`  | `((non-fungible-token T) T principal principal) -> (response bool uint)`  | changes the owner                                                                          | `u1` not owned by sender; `u2` sender is recipient; `u3` does not exist                                             |
| `nft-get-owner?` | `((non-fungible-token T) T) -> (optional principal)`                      | owner                                                                                      |                                                                                                                     |
| `stx-transfer?`  | `(uint principal principal (optional (buff 34))) -> (response bool uint)` | moves uSTX with an optional memo (legacy `stx-transfer?` and `stx-transfer-memo?` merged)  | `u1` insufficient balance; `u2` sender is recipient; `u3` amount is zero; `u4` sender is not the context's `sender` |
| `stx-burn?`      | `(uint principal) -> (response bool uint)`                                | burns uSTX                                                                                 | `u1` insufficient balance; `u3` amount is zero; `u4` sender is not the context's `sender`                           |
| `stx-account`    | `(principal) -> { locked: uint, unlock-height: uint, unlocked: uint }`    | STX account state                                                                          |                                                                                                                     |

`stx-transfer?` and `stx-burn?` require the `sender` argument to be the
context's `sender` field (3.9), returning `err u4` otherwise. The `ft-*` and
`nft-*` primitives do not check the sender; every movement is recorded in the
asset map and is subject to transaction post-conditions and to any enclosing
`as-contract?` or `restrict-assets?` allowance frame. Open question: whether
vNEXT should require the context's `sender` for token transfers as well.

Library, not primitive: `stx-get-balance`.

## 3.9 Transaction and chain context

The execution context is one record, read with a single primitive. Legacy's
twelve bare context names (`tx-sender`, `stacks-block-height`, and so on) are
its fields; `(get sender (get-current-context))` replaces `tx-sender`.

| Primitive             | Signature       | Semantics                                                                                                                                       |
| --------------------- | --------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| `get-current-context` | `() -> context` | the context of the current call frame; the fields are below. A compiler MAY lower `(get f (get-current-context))` to a read of that field alone |

```
context = { sender: principal, caller: principal, sponsor: (optional principal),
            contract: principal,
            stacks-height: uint, burn-height: uint, tenure-height: uint,
            time: uint, liquid-supply: uint,
            chain-id: uint, is-mainnet: bool, is-regtest: bool }
```

| Field           | Value                                                                                                                                                          |
| --------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `sender`        | the transaction sender, or the current contract inside `as-contract?`                                                                                          |
| `caller`        | the principal that made the current call: the sender for the entry call, the calling contract for `contract-call?`, the current contract inside `as-contract?` |
| `sponsor`       | the sponsor, if the transaction is sponsored                                                                                                                   |
| `contract`      | the contract being executed                                                                                                                                    |
| `stacks-height` | height of the current Stacks block                                                                                                                             |
| `burn-height`   | height of the burnchain block the current Stacks block is anchored to                                                                                          |
| `tenure-height` | number of tenures elapsed                                                                                                                                      |
| `time`          | timestamp of the current Stacks block (seconds)                                                                                                                |
| `liquid-supply` | total liquid uSTX                                                                                                                                              |
| `chain-id`      | chain identifier                                                                                                                                               |
| `is-mainnet`    | true on mainnet                                                                                                                                                |
| `is-regtest`    | true in regtest environments                                                                                                                                   |

`sender`, `caller`, and `contract` are frame-scoped: `as-contract?` (2.5.9) and
`contract-call?` change them for the frames they create. The other fields are
the same in every frame of a transaction.

Context and chain data are records rather than properties selected by name, so
their typing is uniform and there is no property-name mini-language.

**Lookups are total.** Every chain-data lookup returns `none` for any height or
input the host cannot serve, including heights before the chain's first block
and data that has not yet matured. A chain-data lookup MUST NOT raise a runtime
error and MUST NOT make the transaction unmineable. (Legacy treated some such
lookups as "problematic" transactions that miners drop, which desynchronizes the
sender's nonce.)

| Primitive                | Signature                                                                                                                                                                                                | Semantics                                                                                                                                                                                                                                                                                                                                                                       |
| ------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `get-stacks-block-info?` | `(uint) -> (optional { id-header-hash: (buff 32), header-hash: (buff 32), time: uint })`                                                                                                                 | `none` if the height is not less than the current height: the current block's hashes do not exist until it is sealed, after this transaction runs. The current block's time is the context's `time` field                                                                                                                                                                       |
| `get-tenure-info?`       | `(uint) -> (optional { burnchain-header-hash: (buff 32), miner-address: principal, time: uint, vrf-seed: (buff 32), block-reward: (optional uint), miner-spend-total: uint, miner-spend-winner: uint })` | serves every tenure up to and including the current one (the context's `tenure-height`), since all fields are fixed at sortition. `block-reward` is `none` until the reward has matured. Maturity is defined by the host in terms of the coinbase (tenure) height at which the reward was recorded, so the lookup is total: it never fails for a height the host has no row for |
| `get-burn-block-info?`   | `(uint) -> (optional { header-hash: (buff 32), pox-addrs: { addrs: (list 2 { hash-bytes: (buff 32), version: (buff 1) }), payout: uint } })`                                                             | serves every burn block up to and including the current one (the context's `burn-height`); `none` if the burn height is outside the known range. The `hashbytes` field of legacy is `hash-bytes` (P6)                                                                                                                                                                           |
| `get-bitcoin-tx-output?` | `((buff N) uint) -> (response { script: (buff 1024), amount: uint, txid: (buff 32) } uint)`                                                                                                              | parses raw Bitcoin transaction bytes (SegWit or not) and returns output `vout`, with `txid` in internal byte order; `err u1` the bytes do not deserialize as a transaction, `err u2` `vout` is out of range, `err u3` the output script exceeds 1024 bytes                                                                                                                      |

## 3.10 Events and control

| Primitive | Signature     | Semantics                                                                                                            |
| --------- | ------------- | -------------------------------------------------------------------------------------------------------------------- |
| `print`   | `(T) -> T`    | emits the value as an event and returns it                                                                           |
| `panic`   | `() -> never` | aborts the transaction with a runtime error. The library's `unwrap-panic` and `unwrap-err-panic` are defined with it |

## 3.11 Count

| Group                   | Primitives                        |
| ----------------------- | --------------------------------- |
| Arithmetic              | 11 (each in two integer families) |
| Comparison and equality | 5                                 |
| Sequences               | 9                                 |
| Conversions             | 8                                 |
| Principals              | 4                                 |
| Cryptography            | 10                                |
| Storage                 | 5                                 |
| Assets                  | 12                                |
| Context                 | 5                                 |
| Events and control      | 2                                 |
| **Total**               | **71**                            |

For comparison, legacy Clarity 6 has 126 native functions and 16 native
variables, most with bespoke typing rules.
