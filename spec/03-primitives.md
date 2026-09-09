# 3. Primitive Operations

This chapter enumerates every primitive in the vNEXT core. A primitive is an
operation that passes the layering rule in [README.md](README.md): it needs
the host or kernel, it cannot be expressed in the language, or expressing it
in the language would be asymptotically more expensive. Everything a contract
author uses that is not listed here or in the special forms of
[02-core-language.md](02-core-language.md) is a standard-library definition.

Every primitive has a fixed arity. Notation follows 2.1: uppercase letters
are type or size variables; "for `I` in {...}" denotes a family with one
signature per listed type. Subtyping (2.3.2) applies to arguments, so a
`(buff 4)` is accepted where `(buff 16)` is written.

Each entry gives the signature, semantics, and error conditions. Cost is
defined in the cost chapter (not yet drafted).

> [!NOTE]
> Signatures marked *(verify)* have been written from memory of the legacy
> behavior and must be checked against the legacy docstrings before this
> chapter is frozen.

## 3.1 Arithmetic

For `I` in {`int`, `uint`}:

| Primitive | Signature | Semantics | Runtime errors |
|---|---|---|---|
| `+` | `(I I) -> I` | addition | overflow |
| `-` | `(I I) -> I` | subtraction | overflow/underflow |
| `*` | `(I I) -> I` | multiplication | overflow |
| `/` | `(I I) -> I` | division truncating toward zero | divisor is zero |
| `mod` | `(I I) -> I` | remainder with the sign of the dividend | divisor is zero |
| `pow` | `(I I) -> I` | exponentiation | exponent negative or not representable in 32 bits; overflow |
| `sqrti` | `(I) -> I` | largest integer whose square does not exceed the argument | argument negative |
| `log2` | `(I) -> I` | floor of the base-2 logarithm | argument not positive |
| `to-int` | `(uint) -> int` | conversion | argument at least 2^127 |
| `to-uint` | `(int) -> uint` | conversion | argument negative |
| `bit-and` | `(I I) -> I` | bitwise and | |
| `bit-or` | `(I I) -> I` | bitwise or | |
| `bit-xor` | `(I I) -> I` | bitwise exclusive or | |
| `bit-not` | `(I) -> I` | bitwise complement | |
| `bit-shift-left` | `(I uint) -> I` | shift left, discarding bits shifted out; the result reinterprets the 128-bit pattern as `I` | shift amount 128 or more |
| `bit-shift-right` | `(I uint) -> I` | shift right; arithmetic for `int`, logical for `uint` | shift amount 128 or more |

Library, not primitive: `max`, `min`, `abs`.

## 3.2 Comparison and equality

For `C` in {`int`, `uint`, `(buff N)`, `(string-ascii N)`, `(string-utf8 N)`}:

| Primitive | Signature | Semantics |
|---|---|---|
| `<`, `<=`, `>`, `>=` | `(C C) -> bool` | numeric order for integers; lexicographic byte order for sequences |

| Primitive | Signature | Semantics |
|---|---|---|
| `is-eq` | `(T T) -> bool` | structural equality. Both arguments are admitted at `lub` of their types; an undefined lub is a type error |

## 3.3 Sequences

`S` ranges over the four sequence kinds; `S[N]` is that kind with bound `N`;
`elem(S)` is its element type (2.3.1). All sequence primitives are
kind-preserving: a `concat` of two buffers is a buffer.

| Primitive | Signature | Semantics | Runtime errors |
|---|---|---|---|
| `len` | `(S[N]) -> uint` | current length (code points for `string-utf8`) | |
| `concat` | `(S[N] S[M]) -> S[N + M]` | concatenation | |
| `element-at?` | `(S[N] uint) -> (optional elem(S))` | element at zero-based index, or `none` if out of range | |
| `slice?` | `(S[N] uint uint) -> (optional S[N])` | elements in `[left, right)`; `none` if `left > right` or `right > len` | |
| `as-max-len?` | `(S[N] size) -> (optional S[M])` | the second argument is a size term `M` (literal or size variable); `(some s)` if `len(s) <= M`, else `none` | |
| `map` | `((function (elem(S)) U) S[N]) -> (list N U)` | applies the function to each element in order | |
| `filter` | `((function (elem(S)) bool) S[N]) -> S[N]` | keeps elements for which the function returns `true`, preserving order | |
| `fold` | `((function (elem(S) A) A) S[N] A) -> A` | left fold: the function receives each element and the accumulator, starting from the initial value | |
| `index-of?` | `(S[N] elem(S)) -> (optional uint)` | zero-based index of the first element equal to the argument, or `none` | |
| `replace-at?` | `(S[N] uint elem(S)) -> (optional S[N])` | copy with the element at the index replaced; `none` if the index is out of range | |

Library, not primitive: `append`. Multi-sequence `map` is dropped (open
question in chapter 2).

## 3.4 Conversions and serialization

| Primitive | Signature | Semantics | Runtime errors |
|---|---|---|---|
| `buff-to-uint-be` | `((buff 16)) -> uint` | big-endian unsigned interpretation; the empty buffer is `u0` | |
| `buff-to-uint-le` | `((buff 16)) -> uint` | little-endian unsigned interpretation; the empty buffer is `u0` | |
| `buff-to-int-be` | `((buff 16)) -> int` | big-endian two's-complement interpretation, sign-extended from the buffer's actual length; the empty buffer is `0` | |
| `buff-to-int-le` | `((buff 16)) -> int` | little-endian counterpart of `buff-to-int-be` | |
| `int-to-ascii` | `(I) -> (string-ascii 40)` for `I` in {`int`, `uint`} | decimal rendering with a leading `-` for negative values | |
| `int-to-utf8` | `(I) -> (string-utf8 40)` for `I` in {`int`, `uint`} | as `int-to-ascii` | |
| `string-to-int?` | `(X) -> (optional int)` for `X` in {`(string-ascii N)`, `(string-utf8 N)`} | parses an optional `-` and decimal digits; `none` on empty input, a non-digit, or overflow | |
| `string-to-uint?` | `(X) -> (optional uint)` for `X` as above | parses decimal digits; `none` on empty input, a non-digit, `-`, or overflow | |
| `uint-to-buff-be` | `(uint size) -> (buff W)` | the second argument is a size term `W` (literal or static constant), at most 16; big-endian encoding in exactly `W` bytes | value does not fit in `W` bytes |
| `uint-to-buff-le` | `(uint size) -> (buff W)` | little-endian counterpart | value does not fit |
| `int-to-buff-be` | `(int size) -> (buff W)` | two's-complement big-endian encoding in exactly `W` bytes | value does not fit in `W` signed bytes |
| `int-to-buff-le` | `(int size) -> (buff W)` | little-endian counterpart | value does not fit |
| `to-consensus-buff?` | `(T) -> (optional (buff serialized-size(T)))` | SIP-005 serialization of the value; `none` if the result would exceed the value size limit. `T` MUST be storable | |
| `from-consensus-buff?` | `(type (buff N)) -> (optional T)` | the first argument is a type expression `T`, which MUST be storable. Deserializes; `none` if the bytes are not a canonical encoding of a value of type `T` (exact typed-tuple fields, no trailing bytes). Memory for the result is reserved against `serialized-size(T)` before decoding (2.7.7) | |
| `to-ascii?` | `(T) -> (response (string-ascii ascii-size(T)) uint)` | ASCII rendering of a value; `T` MUST be storable. Retained pending open question 8 in chapter 2 | |

`serialized-size(T)` and `ascii-size(T)` are type-level size functions
defined with the wire format in the kernel chapter.

The four `*-to-buff-*` primitives have no legacy counterpart. They are the
write direction of the `buff-to-*` family, requested for hashing structured
data (Merkle leaves, transcripts, commitments); legacy contracts slice the
type-tagged output of `to-consensus-buff?` instead, which is fragile and
aliases values that share low bytes. Rejecting values that do not fit closes
that aliasing class at the language level.

## 3.5 Principals

| Primitive | Signature | Semantics |
|---|---|---|
| `principal-construct?` | `((buff 1) (buff 20) (optional (string-ascii 40))) -> (response principal { error-code: uint, principal: (optional principal) })` | builds a standard principal (no name) or contract principal (with name) from a version byte and hash bytes. `(err {error-code: u0, principal: (some p)})` if the version byte is valid but for the other network; `u1` if the version byte is invalid; `u2` if the name is not a valid contract name |
| `principal-destruct?` | `(principal) -> (response D D)` where `D = { hash-bytes: (buff 20), name: (optional (string-ascii 40)), version: (buff 1) }` | decomposes a principal. `ok` if the version byte matches the current network, `err` with the same payload otherwise |
| `contract-of` | `((trait X)) -> principal` | the contract principal a trait-typed value refers to |
| `contract-hash?` | `(principal) -> (response (buff 32) uint)` | SHA-512/256 of the deployed contract's source; `err u1` if the principal is not a deployed contract |

Library, not primitive: `is-standard`, `principal-of?`.

## 3.6 Cryptography

Hash functions accept buffers only (P6, footguns table).

| Primitive | Signature | Semantics |
|---|---|---|
| `hash160` | `((buff N)) -> (buff 20)` | RIPEMD-160 of SHA-256 |
| `sha256` | `((buff N)) -> (buff 32)` | SHA-256 |
| `sha512` | `((buff N)) -> (buff 64)` | SHA-512 |
| `sha512/256` | `((buff N)) -> (buff 32)` | SHA-512/256 (distinct IV; not a truncation of SHA-512) |
| `keccak256` | `((buff N)) -> (buff 32)` | Keccak-256 |
| `secp256k1-recover?` | `((buff 32) (buff 65)) -> (response (buff 33) uint)` | recovers the compressed public key from a message hash and a recoverable signature; `err u1` malformed or non-canonical signature, `err u2` recovery failed |
| `secp256k1-verify` | `((buff 32) (buff 65) (buff 33)) -> bool` | verifies a signature (64 bytes, or 65 with the recovery byte ignored) against a compressed public key; `false` for a non-canonical signature |
| `secp256k1-decompress?` | `((buff 33)) -> (response (buff 65) uint)` | uncompressed form of a compressed public key |
| `secp256r1-verify` | `((buff 32) (buff 64) (buff 33)) -> bool` | P-256 signature verification; `false` for a non-canonical signature |
| `ed25519-verify` | `((buff N) (buff 64) (buff 32)) -> bool` | Ed25519 signature verification over an arbitrary-length message |
| `verify-merkle-proof` | `((buff 32) (buff 32) uint uint (list 24 (buff 32))) -> bool` | Bitcoin-style inclusion proof with double SHA-256 and the odd-row duplication rule. Arguments: leaf hash, root hash, leaf index, transaction count, sibling hashes from leaf to root, all in internal byte order. `false` for any proof inconsistent with the canonical tree shape implied by the transaction count, including a path length other than the tree depth, an index not below the count, or a sibling that must equal its partner on an odd row but does not |

**Canonical signatures.** An ECDSA signature (secp256k1 or P-256) is
canonical only if its `S` component is in the lower half of the curve order
(low-S). The verify primitives MUST return `false`, and `secp256k1-recover?`
MUST return `err u1`, for a non-canonical signature. Accepting both `S` and
`n - S` would let anyone replay a signature-gated authorization with a
different signature encoding.

## 3.7 Contract storage

| Primitive | Signature | Semantics |
|---|---|---|
| `var-get` | `((var T)) -> T` | current value |
| `var-set` | `((var T) T) -> bool` | stores the value; returns `true` |
| `map-get?` | `((map K V) K) -> (optional V)` | lookup |
| `map-set` | `((map K V) K V) -> bool` | inserts or overwrites; returns `true` |
| `map-delete` | `((map K V) K) -> bool` | removes the entry; returns `true` if it existed |

Library, not primitive: `map-insert`.

## 3.8 Assets

All asset primitives record movements in the transaction's asset map (for
post-conditions and allowances) and emit events.

| Primitive | Signature | Semantics | `err` codes |
|---|---|---|---|
| `ft-mint?` | `((fungible-token) uint principal) -> (response bool uint)` | mints `amount` to the recipient | `u1` supply cap exceeded; runtime error if `amount` is zero *(verify)* |
| `ft-burn?` | `((fungible-token) uint principal) -> (response bool uint)` | burns `amount` from the owner | `u1` insufficient balance or amount is zero |
| `ft-transfer?` | `((fungible-token) uint principal principal) -> (response bool uint)` | moves `amount` from sender to recipient | `u1` insufficient balance; `u2` sender is recipient; `u3` amount is zero |
| `ft-get-balance` | `((fungible-token) principal) -> uint` | balance | |
| `ft-get-supply` | `((fungible-token)) -> uint` | circulating supply | |
| `nft-mint?` | `((non-fungible-token T) T principal) -> (response bool uint)` | mints the identifier to the recipient | `u1` already exists |
| `nft-burn?` | `((non-fungible-token T) T principal) -> (response bool uint)` | burns the identifier owned by the owner | `u1` not owned by owner; `u3` does not exist |
| `nft-transfer?` | `((non-fungible-token T) T principal principal) -> (response bool uint)` | changes the owner | `u1` not owned by sender; `u2` sender is recipient; `u3` does not exist |
| `nft-get-owner?` | `((non-fungible-token T) T) -> (optional principal)` | owner | |
| `stx-transfer?` | `(uint principal principal (optional (buff 34))) -> (response bool uint)` | moves uSTX with an optional memo (legacy `stx-transfer?` and `stx-transfer-memo?` merged) | `u1` insufficient balance; `u2` sender is recipient; `u3` amount is zero; `u4` sender is not `tx-sender` |
| `stx-burn?` | `(uint principal) -> (response bool uint)` | burns uSTX | `u1` insufficient balance; `u3` amount is zero; `u4` sender is not `tx-sender` |
| `stx-account` | `(principal) -> { locked: uint, unlock-height: uint, unlocked: uint }` | STX account state | |

`stx-transfer?` and `stx-burn?` require `sender` to be `tx-sender` (`err u4`).
The `ft-*` and `nft-*` primitives do not check the sender; every movement is
recorded in the asset map and is subject to transaction post-conditions and
to any enclosing `as-contract?` or `restrict-assets?` allowance frame. Open
question: whether vNEXT should require `tx-sender` for token transfers as
well.

Library, not primitive: `stx-get-balance`.

## 3.9 Transaction and chain context

Nullary primitives are written as bare identifiers.

| Primitive | Type | Value |
|---|---|---|
| `tx-sender` | `principal` | the transaction sender, or the current contract inside `as-contract?` |
| `contract-caller` | `principal` | the principal that made the current call: the sender for the entry call, the calling contract for `contract-call?`, the current contract inside `as-contract?` |
| `tx-sponsor?` | `(optional principal)` | the sponsor, if the transaction is sponsored |
| `current-contract` | `principal` | the contract being executed |
| `burn-block-height` | `uint` | height of the burnchain block the current Stacks block is anchored to |
| `stacks-block-height` | `uint` | height of the current Stacks block |
| `tenure-height` | `uint` | number of tenures elapsed |
| `stacks-block-time` | `uint` | timestamp of the current Stacks block (seconds) |
| `chain-id` | `uint` | chain identifier |
| `is-in-mainnet` | `bool` | true on mainnet |
| `is-in-regtest` | `bool` | true in regtest environments |
| `stx-liquid-supply` | `uint` | total liquid uSTX |

Chain data lookups return a whole record rather than a property selected by
name, so their typing is uniform and there is no property-name mini-language.

**Lookups are total.** Every chain-data lookup returns `none` for any height
or input the host cannot serve, including heights before the chain's first
block and data that has not yet matured. A chain-data lookup MUST NOT raise a
runtime error and MUST NOT make the transaction unmineable. (Legacy treated
some such lookups as "problematic" transactions that miners drop, which
desynchronizes the sender's nonce.)

| Primitive | Signature | Semantics |
|---|---|---|
| `get-stacks-block-info?` | `(uint) -> (optional { id-header-hash: (buff 32), header-hash: (buff 32), time: uint })` | `none` if the height is not less than the current height |
| `get-tenure-info?` | `(uint) -> (optional { burnchain-header-hash: (buff 32), miner-address: principal, time: uint, vrf-seed: (buff 32), block-reward: (optional uint), miner-spend-total: uint, miner-spend-winner: uint })` | `block-reward` is `none` until the reward has matured. Maturity is defined by the host in terms of the coinbase (tenure) height at which the reward was recorded, so the lookup is total: it never fails for a height the host has no row for |
| `get-burn-block-info?` | `(uint) -> (optional { header-hash: (buff 32), pox-addrs: { addrs: (list 2 { hashbytes: (buff 32), version: (buff 1) }), payout: uint } })` | `none` if the burn height is outside the known range |
| `get-bitcoin-tx-output?` | `((buff N) uint) -> (response { script: (buff 1024), amount: uint, txid: (buff 32) } uint)` | parses raw Bitcoin transaction bytes and returns output `vout`; `err` codes as legacy *(verify)* |

## 3.10 Events and control

| Primitive | Signature | Semantics |
|---|---|---|
| `print` | `(T) -> T` | emits the value as an event and returns it |
| `panic` | `() -> never` | aborts the transaction with a runtime error. The library's `unwrap-panic` and `unwrap-err-panic` are defined with it |

## 3.11 Count

| Group | Primitives |
|---|---|
| Arithmetic | 16 (each in two integer families) |
| Comparison and equality | 5 |
| Sequences | 10 |
| Conversions | 15 |
| Principals | 4 |
| Cryptography | 11 |
| Storage | 5 |
| Assets | 12 |
| Context | 12 nullary, 4 lookups |
| Events and control | 2 |
| **Total** | **96** |

For comparison, legacy Clarity 6 has 126 native functions and 16 native
variables, most with bespoke typing rules.
