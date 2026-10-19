# Chain ABI Proposal

This is a proposal for the chain ABI: the contract between any compiler and the
chain, shared by every source language ([02-goals.md](02-goals.md) G2). It fills
in what [03-architecture.md](03-architecture.md) sections 3–5 sketch. It is
written to seed the joint draft with the chain team
([05-roadmap.md](05-roadmap.md) Phase 0), so it takes a position on every
question instead of listing options; the positions that change an earlier
document are collected in section 12, and the questions it cannot settle alone
are in section 13.

The ABI has two layers, specified in two documents:

- **The runtime layer**, this document: what the chain parses, executes, and
  enforces. That is the module format, the host interface, calls and frames,
  state, fuel, and outcomes, and the encoding of principals, the one structured
  value the host reads and writes.
- **The interpretation layer**,
  [08-value-interpretation.md](08-value-interpretation.md): the types a contract
  declares for its functions and the conventions compilers, wallets, and
  explorers use to encode and decode the values it exchanges.

The chain depends only on the runtime layer. Arguments, results, storage, and
`print` messages are bytes to it (R1), and a module that follows no
interpretation convention still deploys and runs. Tools depend on both layers.

This document draws on two prior systems:

- **The legacy interpreter** in stacks-core, which defines today's value model,
  wire format (SIP-005), storage layout, asset map, and call semantics.
- **clarity-wasm**, the earlier compiler from Clarity to Wasm and its host in
  stacks-core (`feat/clarity-wasm-develop`). Its host interface was built to
  match the interpreter, not designed as an ABI, and most of its problems trace
  to that. Section 1 lists the lessons.

## 1. Design rules

Each rule answers a problem found in one of the two prior systems.

| Rule                                                                                                                                                                                                       | Problem it answers                                                                                                                                                                                                                                                                 |
| ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **R1. The host never interprets a contract's values.** Arguments, results, storage, and events cross the boundary as bytes; the host decodes only the values it acts on itself, in one canonical encoding. | clarity-wasm passed values in a Clarity-type-directed layout, so the host kept a copy of Clarity's type checker and re-parsed textual type strings at runtime (`print`, early returns). Unknown response arms changed Wasm signatures and needed a "duck typing" conversion layer. |
| **R2. Every encoding has exactly one valid byte string per value.** Decoding rejects anything else.                                                                                                        | Legacy decoding accepts unsorted tuple fields, duplicate fields before epoch 4.1, and two contract-name length limits, and "sanitizes" extra tuple fields in some paths but not others.                                                                                            |
| **R3. Types are complete.** No partially known or inference-only types.                                                                                                                                    | `NoType`, `ListUnionType`, and `TraitReferenceType` in legacy, and the epoch-dependent admission rules built around them.                                                                                                                                                          |
| **R4. The chain enforces every guarantee itself.** No guarantee depends on a compiler emitting instrumentation or on a call being made.                                                                    | clarity-wasm metering was optional codegen, and the node deploy path compiled without it. Host-function cost charges were commented out.                                                                                                                                           |
| **R5. A module has no state except chain state.** Each call gets a fresh instance.                                                                                                                         | Without this, linear memory and globals could carry data between calls in one transaction, which is state that no rollback covers.                                                                                                                                                 |
| **R6. Every contract-caused failure is an includable transaction outcome.**                                                                                                                                | Legacy "rejectable" errors (`Unreachable`, some memory and asset-map errors) make a transaction unmineable rather than failed, which desynchronizes the sender's nonce.                                                                                                            |
| **R7. Semantics never change under a module.** A module binds to an ABI version, and that version's behavior is frozen; only the fuel schedule moves.                                                      | Legacy reinterprets `block-height`, `get-block-info?` heights, `secp256r1-verify` hashing, and argument sanitizing by epoch, under contracts already deployed.                                                                                                                     |
| **R8. The ABI is a single formal definition.** Host and every compiler derive from it.                                                                                                                     | clarity-wasm's host interface was two hand-synchronized Rust files and a `.wat` import list.                                                                                                                                                                                       |

## 2. Host values

The host reads and writes three kinds of value:

- **principals**, in the encoding of 2.2;
- **unsigned 128-bit integers**, as fixed-width words (6.1);
- **raw bytes**, whose length and meaning each function states.

Nothing with more structure crosses the host interface. A block's fields, an
account's balances, and an allowance's fields are each passed on their own (6.2,
7.2), so the host has no record layout to decode or produce.

The values a contract exchanges are not host values: arguments, results,
storage, and `print` messages are bytes the host passes through or stores (5.4,
4.2, 6.2). The interpretation layer defines a type grammar and an encoding for
them ([08-value-interpretation.md](08-value-interpretation.md) sections 2–3),
whose encoding of a principal is the one in 2.2. Nothing in this document
depends on that layer, except a call between a legacy and a Wasm contract
(section 13, question 4).

### 2.1 Names

| Kind                     | Grammar                                                                       | Length      |
| ------------------------ | ----------------------------------------------------------------------------- | ----------- |
| Function and token names | ASCII letters, digits, and `- _ ! ? + < > = / * ^`, not starting with a digit | 1–128 bytes |
| Contract names           | an ASCII letter, then letters, digits, `-`, `_`                               | 1–40 bytes  |

Every source language shares these rules. One contract-name limit applies
everywhere: in deploys, in principals, and on the wire. Legacy has 40 at deploy
and 128 inside values before epoch 4.1.

### 2.2 Principals

| Prefix | Principal | Payload                                    |
| ------ | --------- | ------------------------------------------ |
| `0x05` | standard  | version (1 byte, < 32), hash160 (20 bytes) |
| `0x06` | contract  | version, hash160, u8 name length, name     |

This is the SIP-005 encoding of a principal, so a principal has the same bytes
here as in legacy values, transaction post-conditions, and the interpretation
layer. Decoding accepts exactly this form (R2): the prefix is `0x05` or `0x06`,
the version is below 32, a contract name is valid (2.1), and no bytes remain.

## 3. Module format

A deployed contract is one Wasm module. The chain stores the module bytes and
nothing else; any compiled or cached form of it is node-local and never
consensus data.

### 3.1 Wasm profile

Allowed: Wasm 1.0 plus mutable globals, sign-extension operators, and
multi-value.

Rejected at deploy:

- all floating-point types and instructions (no NaN canonicalization questions);
- bulk memory (`memory.copy`, `memory.fill`, and the passive-segment operators),
  because engine metering charges one operator the same whatever length it
  covers (9.2). A compiler emits loops instead; a later version may allow these
  operators with a per-byte charge;
- SIMD, threads, reference types (`externref`), exceptions, multiple memories,
  memory64, tail calls, and any later proposal not listed above;
- a `start` function (initialization is an explicit export, section 3.3);
- a table with more initial entries than the table limit (section 9.3). Wasm 1.0
  allows at most one table, of `funcref`, and gives the module no way to grow
  it.

A later ABI version may allow more; a module states the version it targets
(section 11). The likely direction is the deterministic profile of the Wasm
specification, which fixes the results the base specification leaves
nondeterministic, such as NaN bit patterns, and would replace this hand-picked
subset with a standard one (section 13).

### 3.2 Imports and memory

- Every import is a function from module `stacks-abi-v1` (section 11) whose name
  and Wasm type match the host interface exactly (section 6). Anything else is
  rejected.
- The module defines exactly one memory, exports it as `memory`, and declares a
  maximum no larger than the instance memory limit (section 9.3).

### 3.3 Exports

- `memory`.
- `init`, of type `[] -> []`, if the contract has deploy-time code.
- One export per interface function (section 4), under the function's name, of
  type `[] -> []`.

No other exports. Every entry point has the same Wasm type: arguments arrive and
results leave through host functions (section 5.2), so no flattening convention
is part of the ABI and no unused response arm can change a signature.

### 3.4 Custom sections

| Section          | Required | Validated by the chain                                                                                                               |
| ---------------- | -------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| `abi.interface`  | yes      | yes (section 4)                                                                                                                      |
| `abi.types`      | no       | only for size; contents are defined by the interpretation layer ([08-value-interpretation.md](08-value-interpretation.md) section 5) |
| `abi.provenance` | no       | only for size; contents are owned by the toolchain that produced the module ([03-architecture.md](03-architecture.md) section 2)     |

Any other custom section, including `name`, is rejected. The module is the unit
that `contract-hash?` hashes and that `clarity-verify` compares, so it carries
nothing that is not executed, validated, or metadata for tools.

### 3.5 Deploy

The chain, in order:

1. Checks the module size limit (section 9.3), parses the module, and applies
   sections 3.1–3.4.
2. Decodes and validates the interface (section 4) and checks that the exports
   match it.
3. Instantiates the module and runs `init`, if present, in a public frame
   (section 7) with `sender` and `caller` set to the deployer. The new contract
   has an active frame, so it cannot be called during its own `init` (section
   7.3).

A runtime error in `init` aborts the deploy; nothing is stored. Deploy is
charged for module bytes, validation, and compilation before step 1, and for the
fuel `init` consumes (9.2). A module rejected in steps 1–2 is a failed deploy
that pays its charges.

## 4. Interface

### 4.1 Contents

The `abi.interface` section records what the chain acts on: which functions
exist, how each may be called, and which tokens the contract defines. Its bytes
are, in order:

| Field         | Encoding                                                                     |
| ------------- | ---------------------------------------------------------------------------- |
| `abi-version` | u32 BE, the ABI version the module targets                                   |
| `functions`   | u32 BE count, then per function: name, kind byte (`0` public, `1` read-only) |
| `fts`         | u32 BE count, then per fungible token: name                                  |
| `nfts`        | u32 BE count, then per non-fungible token: name                              |

A name is a u8 length and the name's bytes (2.1). No bytes may follow `nfts`.

Rules:

- Names are unique within each list, and lists are sorted in strictly ascending
  byte order of name, so an interface has exactly one encoding (R2) and one
  hash: `sha512/256` of the section bytes.
- The interface carries no types and no traits. A function's arguments and
  result are bytes to the chain (5.2), and their declared types, the type of
  each NFT's identifiers, and the contract's traits are in the `abi.types`
  section, which the interpretation layer defines
  ([08-value-interpretation.md](08-value-interpretation.md) section 5) and the
  chain does not read.
- A token is addressed by its index in its sorted list. The index is a
  module-local handle; the chain keys state by name (section 8.1), so the name,
  not the index, is the stable identity.

### 4.2 Storage is untyped

Storage is not part of the interface. Each contract has one key-value store
whose keys and values are bytes (6.2), and the host never decodes either. A
source language lays its own variables and maps out over that store, for example
by prefixing each key with the variable or map name. The chain does not need
storage types, since it never acts on a stored value, and leaving them out
removes a decode from every write and keeps the host independent of how any
language structures its state. A contract makes its state readable by tools by
declaring its layout ([08-value-interpretation.md](08-value-interpretation.md)
section 7.2).

## 5. Calls

### 5.1 Entry points

| Entry                     | Frame                               | `sender` / `caller`          |
| ------------------------- | ----------------------------------- | ---------------------------- |
| Contract-call transaction | public frame on a `public` function | origin / origin              |
| Deploy                    | public frame on `init`              | deployer / deployer          |
| `call` host function      | per the callee's kind               | unchanged / calling contract |
| Read-only query (RPC)     | read-only frame                     | as the request states        |

A contract-call transaction that names a missing or `read-only` function fails
before any code runs. It is included and pays its intrinsic charge (9.2), with
the class `no-such-function`. Its arguments are not checked (5.4); a transaction
whose arguments exceed the arguments limit (9.3) is invalid.

The node's read-only query runs in an explicit read-only frame, so a write is a
`read-only-violation`, not a zeroed write budget surfacing as a cost error, as
in legacy. It runs under the node's own fuel limit (9.1). Simulating a public
function is a separate query that runs a public frame and discards it.

### 5.2 Arguments and results

Inside an entry point:

- `args_size()` returns the byte length of the arguments, and
  `args_read(dst, offset, len)` copies `len` bytes of them, starting at
  `offset`, into memory, so a module can read them whole or piecewise. The
  arguments are the bytes the caller passed, unchanged: a contract-call
  transaction and a read-only query carry them as one byte string, and `call`
  takes them as `args`. The chain does not parse them; how a caller lays them
  out is the interpretation layer's convention
  ([08-value-interpretation.md](08-value-interpretation.md) section 6.1).
- `result_set(ok, result)` sets the result: a flag, `1` for ok and `0` for err,
  and the result's bytes. It does not return: the host ends the export there, as
  `abort` does, so no host function runs after the result is set and a result
  cannot be set twice. For a `public` function, the flag closes the frame: ok
  commits, err discards (7.1). For a `read-only` function, the flag is passed to
  the caller and recorded, and has no other effect. An export that returns
  without calling `result_set` is a `no-result` runtime error.

The module chooses where the bytes go; the ABI defines no allocator and no
exported buffer.

### 5.3 The `call` host function

```
call(target: principal, fn: bytes, args: bytes, read_only: i32, out: buf,
     ok: out<1>) -> len
```

In the notation of 6.1, this is the Wasm type
`(param i32 i32 i32 i32 i32 i32 i32 i32 i32 i32) (result i32)`.

- `target` is the callee, a principal.
- `fn` is the function name's bytes (2.1), not an encoded value.
- `args` is the arguments as in 5.2, passed to the callee unchanged.
- `read_only` is `1` to require the callee to be `read-only`, and `0` otherwise;
  any other value is `bad-host-argument`. A caller sets it when it relies on the
  callee not writing, as when it calls a function that a trait marks
  `read-only`, so the host enforces that in any frame.
- `ok` receives the callee's result flag (5.2), as one byte.

The host, in order:

1. Resolves the target. A standard principal, a missing contract, or a missing
   function is a runtime error (`no-such-function`).
2. If the current frame is read-only, or `read_only` is `1`, requires `fn` to be
   `read-only` (section 7.4).
3. Applies the reentrancy and depth rules (section 7.3).
4. Opens the callee's frame, instantiates a fresh instance, runs the export, and
   closes the frame: for a public function, commit if the result flag is ok and
   discard if it is err.
5. Writes the result flag to `ok`, writes the result to `out`, and returns its
   length. If `cap` is too small, it writes the flag but not the result, keeps
   the result, and returns the negated length; `result_read(dst, offset, len)`
   then copies the kept result, whole or in pieces. A kept result lasts until
   the next `call`; `result_read` with no kept result is a `bad-host-argument`
   runtime error. The callee's frame has already closed either way. A module
   that bounds the result in advance, as a Clarity module does from the declared
   result type ([08-value-interpretation.md](08-value-interpretation.md) section
   4.1), sizes `out` for that bound and treats a longer result as one that fails
   validation (5.4), so it never needs the second step.

Steps 1–3 failing, and any runtime error in the callee, abort the transaction.
There is no catch.

### 5.4 Values at a call boundary

The chain does not validate the values that cross a call boundary: the arguments
of a transaction or query (5.1), the arguments of a `call` (5.3), and every
result (5.2) pass through as bytes. A module validates what it receives. A
callee validates its arguments, and a caller validates the result of every call,
since nothing guarantees that either matches the declared types. A module cannot
read another contract's declared types, so it cannot check at runtime that a
principal it receives conforms to a trait. What it can rely on at a call through
that principal is that the function exists (5.3, step 1) and, when it sets
`read_only`, that the function is `read-only` (step 2), and it validates the
result. Validation is module code, charged as execution (9.2) like any other
work.

Declared types and the encoding conventions that wallets, explorers, and
compilers rely on are the interpretation layer's
([08-value-interpretation.md](08-value-interpretation.md) section 6). Nothing in
this section depends on a module following them.

Keeping validation out of the host keeps every language's type checker out of
the host and the mempool. A transaction with malformed arguments is included,
fails in the module, and pays for the check. What the chain still guarantees at
a call boundary is the frame: commit or rollback by the result flag, read-only
enforcement, reentrancy, and depth (section 7). A value that fails validation is
a runtime error of the source language, reported through `abort` (10.2).

## 6. Host interface

### 6.1 Conventions

Signatures in 6.2 are written with typed parameters. Each parameter kind expands
to a fixed sequence of Wasm parameters, in the order written, and the import's
Wasm type is the concatenation:

| Kind        | Wasm parameters      | Meaning                                                                                                                                |
| ----------- | -------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| `i32`       | `i32`                | an integer, as the function describes                                                                                                  |
| `u128`      | `i64 lo`, `i64 hi`   | an unsigned 128-bit integer, low 64 bits first                                                                                         |
| `principal` | `i32 ptr`, `i32 len` | a principal's encoding (2.2); a failed decode is `bad-host-argument`                                                                   |
| `bytes`     | `i32 ptr`, `i32 len` | raw bytes, not an encoded value                                                                                                        |
| `bytes<N>`  | `i32 ptr`            | exactly `N` raw bytes                                                                                                                  |
| `out<N>`    | `i32 ptr`            | the host writes exactly `N` bytes; a `u128` result is written as 16 bytes, little-endian                                               |
| `buf`       | `i32 ptr`, `i32 cap` | the host writes at most `cap` bytes and returns the length; what it writes (an encoded principal, or raw bytes) is stated per function |

| Result   | Wasm result | Meaning                                                                                                                   |
| -------- | ----------- | ------------------------------------------------------------------------------------------------------------------------- |
| none     | none        |                                                                                                                           |
| `len`    | `i32`       | the number of bytes written to the `buf`, with the short-buffer rule of 5.3; `-1` means "none" where the function says so |
| `status` | `i32`       | `0` for success, otherwise one of the codes listed with the function                                                      |
| `bool`   | `i32`       | `1` for true, `0` for false                                                                                               |

For example, `stx_burn(amount: u128, from: principal) -> status` is imported
with Wasm type `(param i64 i64 i32 i32) (result i32)`.

- Lengths and capacities are unsigned. Every range a call names (`ptr` to
  `ptr + len`, `ptr + N`, or `ptr + cap`) must lie inside the module's memory;
  otherwise the call is a `bad-host-argument` runtime error, raised before the
  call has any effect.
- The host reads every input before it writes any output, so an output may
  overlap an input.
- An index argument (`token`, `kind`) outside its range is a `bad-host-argument`
  runtime error.
- Every host function has a charge (section 9.2).

### 6.2 Functions

Each function is given by its signature in the notation of 6.1, then its
behavior. Status codes are listed where a function has them; `0` is always
success.

#### Boundary and control

##### `args_size`

```
args_size() -> i32
```

Returns the byte length of the current entry point's arguments (5.2).

##### `args_read`

```
args_read(dst: i32, offset: i32, len: i32)
```

Writes bytes `offset` to `offset + len` of the arguments (5.2) at `dst`. A range
that extends past `args_size()` is `bad-host-argument`.

##### `result_set`

```
result_set(ok: i32, result: bytes)
```

Sets the result of the current entry point and its flag (5.2): `ok` is `1` for
ok and `0` for err; any other value is `bad-host-argument`. A `result` longer
than the result limit (section 9.3) is `bad-host-argument`. Does not return.
`init` has no result; it ends by returning, and calling `result_set` in `init`
is `bad-host-argument`.

##### `abort`

```
abort(code: i32, msg: bytes)
```

Aborts the transaction with a module-defined code and message, both recorded in
the receipt as given (section 10). `msg` is at most 128 bytes; a longer one is
`bad-host-argument`. Does not return.

#### Context

Each piece of transaction and block context has its own function, and new
context arrives as a new function in a new ABI version (section 11). The
frame-scoped functions return the value for the current frame; the others return
the same value in every frame of a transaction.

##### `sender`

```
sender(out: buf) -> len
```

Writes the encoded transaction sender, or the current contract inside an
`as-contract` frame (7.2). Frame-scoped.

##### `caller`

```
caller(out: buf) -> len
```

Writes the encoded caller: the transaction sender for the entry call, the
calling contract under `call`, or the current contract inside an `as-contract`
frame. Frame-scoped.

##### `sponsor`

```
sponsor(out: buf) -> len
```

Writes the encoded sponsor, or returns `-1` if the transaction is not sponsored.

##### `contract`

```
contract(out: buf) -> len
```

Writes the encoded principal of the contract being executed. Frame-scoped.

##### `stacks_height`

```
stacks_height(out: out<16>)
```

Writes the height of the current Stacks block as a `u128`.

##### `burn_height`

```
burn_height(out: out<16>)
```

Writes the height of the burn block the current Stacks block is anchored to, as
a `u128`.

##### `tenure_height`

```
tenure_height(out: out<16>)
```

Writes the number of tenures elapsed as a `u128`.

##### `time`

```
time(out: out<16>)
```

Writes the timestamp of the current Stacks block, in seconds, as a `u128`.

##### `liquid_supply`

```
liquid_supply(out: out<16>)
```

Writes the total liquid uSTX as a `u128`.

##### `chain_id`

```
chain_id(out: out<16>)
```

Writes the chain identifier as a `u128`.

##### `is_mainnet`

```
is_mainnet() -> bool
```

Whether the chain is mainnet.

##### `is_regtest`

```
is_regtest() -> bool
```

Whether the chain is a regtest environment.

#### Block data

Lookups of Stacks blocks, tenures, and burn blocks by height. They are total:
each reports a height the host cannot serve through its result, as status `1` or
as `-1` for a function that writes a `buf`, and no height is ever a runtime
error or a reason to drop the transaction. Like the context values, each field
is its own function, so a later ABI version can add one without changing a
layout.

The Stacks block lookups serve heights below `stacks_height`. The current
block's hashes do not exist until it is sealed, after this transaction runs; its
time is what `time` returns.

##### `stacks_block_id_header_hash`

```
stacks_block_id_header_hash(height: u128, out: out<32>) -> status
```

Writes the index block hash of the Stacks block at `height`.

##### `stacks_block_header_hash`

```
stacks_block_header_hash(height: u128, out: out<32>) -> status
```

Writes the header hash of the Stacks block at `height`.

##### `stacks_block_time`

```
stacks_block_time(height: u128, out: out<16>) -> status
```

Writes the timestamp of the Stacks block at `height`, in seconds, as a `u128`.

The tenure lookups serve every tenure up to and including `tenure_height`, since
every field is fixed at sortition.

##### `tenure_burnchain_header_hash`

```
tenure_burnchain_header_hash(height: u128, out: out<32>) -> status
```

Writes the header hash of the burn block associated with the tenure at `height`.

##### `tenure_miner_address`

```
tenure_miner_address(height: u128, out: buf) -> len
```

Writes the encoded principal of the miner of the tenure at `height`.

##### `tenure_time`

```
tenure_time(height: u128, out: out<16>) -> status
```

Writes the timestamp of the tenure at `height`, in seconds, as a `u128`.

##### `tenure_vrf_seed`

```
tenure_vrf_seed(height: u128, out: out<32>) -> status
```

Writes the VRF seed of the tenure at `height`.

##### `tenure_block_reward`

```
tenure_block_reward(height: u128, out: out<16>) -> status
```

Writes the block reward of the tenure at `height`, in uSTX, as a `u128`.
Maturity is defined by the host in terms of the tenure height at which the
reward was recorded.

- `1` height not served
- `2` the reward has not matured

##### `tenure_miner_spend_total`

```
tenure_miner_spend_total(height: u128, out: out<16>) -> status
```

Writes the total spent by all miners in the sortition of the tenure at `height`,
as a `u128`.

##### `tenure_miner_spend_winner`

```
tenure_miner_spend_winner(height: u128, out: out<16>) -> status
```

Writes the amount spent by the winning miner in the sortition of the tenure at
`height`, as a `u128`.

The burn block lookups serve every burn block up to and including `burn_height`.

##### `burn_block_header_hash`

```
burn_block_header_hash(height: u128, out: out<32>) -> status
```

Writes the header hash of the burn block at `height`.

##### `burn_block_pox_addr`

```
burn_block_pox_addr(height: u128, index: i32, out: buf) -> len
```

Writes PoX reward address `index` of the burn block at `height`: its version
byte, then its hash bytes (at most 32), as raw bytes. Returns `-1` if the height
is not served or the block has no address at `index`. A block has at most two
addresses, so an `index` above 1 is `bad-host-argument`.

##### `burn_block_pox_payout`

```
burn_block_pox_payout(height: u128, out: out<16>) -> status
```

Writes the amount paid to each PoX reward address of the burn block at `height`,
as a `u128`.

#### Storage

The current contract's key-value store (4.2). Keys and values are raw bytes,
compared byte for byte. A key longer than the storage key limit, or a value
longer than the storage value limit (section 9.3), is `bad-host-argument`.

##### `kv_get`

```
kv_get(key: bytes, out: buf) -> len
```

Writes the value stored under `key`, or returns `-1` if there is no entry.

##### `kv_has`

```
kv_has(key: bytes) -> bool
```

Whether an entry exists under `key`. Charged as a read without the value's
length.

##### `kv_set`

```
kv_set(key: bytes, value: bytes)
```

Inserts or overwrites the entry under `key`.

##### `kv_delete`

```
kv_delete(key: bytes) -> bool
```

Removes the entry under `key`; returns whether it existed.

#### Assets

`token` is an index into `fts` or `nfts` (4.1). A contract can only operate its
own tokens, because it can only name its own indices. An NFT identifier `id` is
raw bytes in an encoding the token's contract chooses; the chain compares
identifiers byte for byte. An identifier longer than the NFT identifier limit
(section 9.3) is `bad-host-argument`.

Every successful mutation records an entry in the asset map (8.2) and emits an
asset event. STX functions require `from` to be the frame's `sender`. Token
functions do not check the sender: every movement is in the asset map, so
post-conditions and allowance frames (7.2) protect the holder, and a token's
contract decides its own transfer rules.

##### `ft_set_cap`

```
ft_set_cap(token: i32, cap: u128)
```

Sets the token's supply cap. Valid only during `init`, at most once per token;
otherwise a runtime error. The cap is a host call rather than interface data
because deploy-time code computes it.

##### `ft_mint`

```
ft_mint(token: i32, amount: u128, to: principal) -> status
```

Mints `amount` to `to`. Exceeding the supply cap is a runtime error.

- `1` amount is zero

##### `ft_burn`

```
ft_burn(token: i32, amount: u128, from: principal) -> status
```

Burns `amount` from `from`.

- `1` insufficient balance, or amount is zero

##### `ft_transfer`

```
ft_transfer(token: i32, amount: u128, from: principal, to: principal) -> status
```

Moves `amount` from `from` to `to`.

- `1` insufficient balance
- `2` `from` is `to`
- `3` amount is zero

##### `ft_balance`

```
ft_balance(token: i32, owner: principal, out: out<16>)
```

Writes `owner`'s balance as a `u128`.

##### `ft_supply`

```
ft_supply(token: i32, out: out<16>)
```

Writes the circulating supply as a `u128`.

##### `nft_mint`

```
nft_mint(token: i32, id: bytes, to: principal) -> status
```

Mints the identifier `id` to `to`.

- `1` already exists

##### `nft_burn`

```
nft_burn(token: i32, id: bytes, from: principal) -> status
```

Burns `id`, which `from` must own.

- `1` not owned by `from`
- `3` does not exist

##### `nft_transfer`

```
nft_transfer(token: i32, id: bytes, from: principal, to: principal) -> status
```

Changes the owner of `id` from `from` to `to`.

- `1` not owned by `from`
- `2` `from` is `to`
- `3` does not exist

##### `nft_owner`

```
nft_owner(token: i32, id: bytes, out: buf) -> len
```

Writes the encoded owner of `id`, a `principal`, or returns `-1` if `id` does
not exist.

##### `stx_transfer`

```
stx_transfer(amount: u128, from: principal, to: principal, memo: bytes) -> status
```

Moves `amount` uSTX from `from` to `to`, recording `memo` in the event. `memo`
is at most 34 bytes, and a longer one is `bad-host-argument`; an empty memo is
recorded as no memo.

- `1` insufficient balance
- `2` `from` is `to`
- `3` amount is zero
- `4` `from` is not the frame's `sender`

##### `stx_burn`

```
stx_burn(amount: u128, from: principal) -> status
```

Burns `amount` uSTX from `from`.

- `1` insufficient balance
- `3` amount is zero
- `4` `from` is not the frame's `sender`

##### `stx_locked`

```
stx_locked(owner: principal, out: out<16>)
```

Writes the uSTX `owner` has locked for staking, as a `u128`.

##### `stx_unlock_height`

```
stx_unlock_height(owner: principal, out: out<16>)
```

Writes the burn height at which `owner`'s locked uSTX unlock, as a `u128`, or
`0` if none are locked.

##### `stx_unlocked`

```
stx_unlocked(owner: principal, out: out<16>)
```

Writes `owner`'s unlocked uSTX balance, as a `u128`.

#### Frames

##### `frame_open`

```
frame_open(kind: i32, desc: bytes)
```

Opens a frame (section 7): `0` plain, `1` as-contract, `2` restrict. `desc` is
empty for a plain frame and the allowance descriptor of 7.2 otherwise.

##### `frame_close`

```
frame_close(commit: i32) -> i32
```

Closes the innermost module-opened frame. `commit` is `0` to discard or `1` to
commit after the allowance check. Returns `-1`, or the index of the violated
allowance (7.2).

#### Calls and principals

##### `call`

```
call(target: principal, fn: bytes, args: bytes, read_only: i32, out: buf,
     ok: out<1>) -> len
```

Calls a function of another contract and writes its result flag and result
(5.3). An `args` longer than the arguments limit (section 9.3) is
`bad-host-argument`.

##### `result_read`

```
result_read(dst: i32, offset: i32, len: i32)
```

Writes bytes `offset` to `offset + len` of the result kept by the last `call`
that returned a negated length (5.3) at `dst`. A range that extends past the
kept result is `bad-host-argument`.

##### `contract_hash`

```
contract_hash(contract: principal, out: out<32>) -> status
```

Writes the `sha512/256` of the contract's module.

- `1` the principal is a standard principal
- `2` no such contract

##### `principal_to_ascii`

```
principal_to_ascii(p: principal, out: buf) -> len
```

Writes the c32check text form of `p` as raw ASCII bytes, not an encoded value. A
contract principal is the address, `.`, and the name.

#### Events

##### `print`

```
print(msg: bytes)
```

Emits `msg` as a contract event. `msg` must be valid UTF-8 (no surrogates, no
overlong forms) and at most the print message limit (section 9.3); anything else
is `bad-host-argument`. It also counts toward the transaction's event bytes. The
chain does not interpret the text: the source language decides how a value is
rendered ([08-value-interpretation.md](08-value-interpretation.md) section 7.1),
and a module that wants to emit structured data formats it itself. Asset events
are emitted by the asset functions themselves.

#### Cryptography

Formats: an ECDSA signature is `r` then `s`, each 32 bytes big-endian; a
recoverable signature appends one recovery-id byte, `0`–`3`. ECDSA public keys
are SEC 1 compressed points, 33 bytes; the verify functions accept no other
form, and `secp256k1_decompress` is the only function that produces the 65-byte
uncompressed form. Ed25519 keys and signatures are as in RFC 8032.

An ECDSA signature is canonical only if its `S` is in the lower half of the
curve order. The verify functions return `0`, and `secp256k1_recover` returns
`1`, for a non-canonical signature; accepting both `S` and `n - S` would let
anyone replay a signature-gated authorization with a different encoding.

##### `sha256`

```
sha256(data: bytes, out: out<32>)
```

Writes the SHA-256 hash of `data`, as defined in FIPS 180-4.

##### `sha512`

```
sha512(data: bytes, out: out<64>)
```

Writes the SHA-512 hash of `data`, as defined in FIPS 180-4.

##### `sha512_256`

```
sha512_256(data: bytes, out: out<32>)
```

Writes the SHA-512/256 hash of `data`, as defined in FIPS 180-4, which starts
from its own initial hash value. It is not the first 32 bytes of SHA-512.

##### `keccak256`

```
keccak256(data: bytes, out: out<32>)
```

Writes the Keccak-256 hash of `data`, as defined in the Keccak submission to the
SHA-3 competition (version 3), with its original padding. It is not FIPS 202
SHA3-256, which pads differently and gives different results.

##### `hash160`

```
hash160(data: bytes, out: out<20>)
```

Writes RIPEMD-160 (ISO/IEC 10118-3) of the SHA-256 hash (FIPS 180-4) of `data`.

##### `secp256k1_recover`

```
secp256k1_recover(hash: bytes<32>, sig: bytes<65>, out: out<33>) -> status
```

Writes the compressed public key that produced `sig` over `hash`.

- `1` malformed or non-canonical signature
- `2` recovery failed

##### `secp256k1_verify`

```
secp256k1_verify(hash: bytes<32>, sig: bytes<64>, key: bytes<33>) -> bool
```

Whether `sig` is a valid, canonical secp256k1 signature of `hash` by `key`.
`hash` is used as given, not hashed again.

##### `secp256r1_verify`

```
secp256r1_verify(hash: bytes<32>, sig: bytes<64>, key: bytes<33>) -> bool
```

Whether `sig` is a valid, canonical P-256 signature of `hash` by `key`. `hash`
is used as given, not hashed again.

##### `secp256k1_decompress`

```
secp256k1_decompress(key: bytes<33>, out: out<65>) -> status
```

Writes the uncompressed form of `key`.

- `1` not a valid key

##### `ed25519_verify`

```
ed25519_verify(msg: bytes, sig: bytes<64>, key: bytes<32>) -> bool
```

Whether `sig` is a valid Ed25519 signature (RFC 8032) of `msg`, which may be any
length.

## 7. Frames and runtime guarantees

### 7.1 Frames

A frame buffers state changes: storage writes, token and STX state, asset-map
entries, and events. Frames nest. Closing a frame either commits its changes
into the parent or discards them.

| Frame       | Opened by                                                      | Closed                                                                |
| ----------- | -------------------------------------------------------------- | --------------------------------------------------------------------- |
| public      | the host, for every call to a `public` function and for `init` | by the host: by the result flag (5.2); `init` commits when it returns |
| read-only   | the host, for every call to a `read-only` function             | by the host: commit (there are no writes, only events)                |
| plain       | the module, `frame_open(0, …)`                                 | by the module                                                         |
| as-contract | the module, `frame_open(1, allowances)`                        | by the module, with the allowance check                               |
| restrict    | the module, `frame_open(2, owner + allowances)`                | by the module, with the allowance check                               |

Plain frames are how a module calls its own public function internally with
rollback. Module-opened frames are well nested within one call: closing a frame
the module did not open, or ending an export (by returning or by `result_set`)
with a frame still open, is an `unbalanced-frame` runtime error.

Events of a read-only frame are kept and commit with the caller. Legacy drops
them because it rolls the frame back; nothing in a read-only frame needs rolling
back.

### 7.2 Allowance frames

`frame_open(1 | 2, desc)` takes an allowance descriptor. For a `restrict` frame,
`desc` starts with the owner's encoding (2.2). Then, for both kinds:

- a u8 count of allowances, at most 128;
- per allowance, a kind byte, then its fields in the order of the table below: a
  `principal` as its encoding (2.2), a `name` as a u8 length and the name's
  bytes (2.1), and a `u128` as 16 bytes, little-endian (6.1);
- for `nft`, the `ids` field is a u32 BE count, then per identifier a u32 BE
  length and the identifier's bytes (6.2).

No bytes may follow the last allowance. A descriptor that does not decode this
way is a `bad-host-argument` runtime error. The allowance kinds are ABI data:

| Byte | Kind      | Fields                                                   | Covers                                                  |
| ---- | --------- | -------------------------------------------------------- | ------------------------------------------------------- |
| `0`  | `stx`     | `amount: u128`                                           | the owner's uSTX transferred plus burned                |
| `1`  | `ft`      | `contract: principal`, `token: name`, `amount: u128`     | the owner's movements of that token, summed             |
| `2`  | `nft`     | `contract: principal`, `token: name`, `ids`: identifiers | each moved identifier must be listed, compared by bytes |
| `3`  | `all`     | none                                                     | everything; only in an `as-contract` frame              |
| `4`  | `staking` | `amount: u128`                                           | the uSTX the owner locks for staking, summed            |
| `5`  | `pox`     | none                                                     | any position-altering PoX action by the owner           |

`as-contract` also sets the frame's `sender` and `caller` to the current
contract. `frame_close(1)` on an allowance frame compares the owner's outgoing
movements, stakes, and PoX actions in the frame's asset map (8.2) against the
list. If all are covered, it commits and returns `-1`. Otherwise it discards and
returns the index of the first allowance violated, in list order, or `128` (the
allowance limit) for a movement that no allowance names. `frame_close(1)` on a
plain frame commits and returns `-1`. `frame_close(0)` discards any frame
without a check and returns `-1`.

### 7.3 Depth and reentrancy

- A call into a contract that already has an active frame in the transaction is
  a `reentrancy` runtime error. The unit is the contract. Legacy checks per
  (contract, function), so `A.f → B.g → A.h` passes there.
- Contract-call depth is at most 64. This counts frames the host opens for
  calls, not module-internal function calls, which the chain cannot see.
  Legacy's 128 counts every function application, builtins included, so the two
  numbers are not comparable. A source language may bound its own internal call
  depth separately.
- Wasm stack depth is bounded separately and deterministically (section 9.3).

### 7.4 Read-only

In a read-only frame, every storage write, asset mutation, and `frame_open` of
an allowance kind is a `read-only-violation` runtime error, and `call` accepts
only `read-only` callees. A `call` with `read_only` set (5.3) applies the same
callee check from any frame. Legacy checks storage writes at runtime but relies
on analysis for asset functions; here every mutation is checked.

## 8. State and effects

### 8.1 State layout

Contract storage is keyed by contract and the key's bytes, and stores the
value's bytes as given (4.2). Token state is keyed by contract, token name, and,
for NFTs, the identifier's bytes. Legacy uses serde JSON for principals in
token-balance keys and for persisted type metadata; nothing here depends on a
language's in-memory representation. The concrete key strings and the encoding
of balances and supplies are the chain's choice, made once.

### 8.2 Asset map

Every asset operation records an entry: kind (transfer, mint, burn), asset (STX,
or contract and token name), from, to, and amount or identifier. Post-conditions
and allowance frames are evaluated over it.

Staking adds two more kinds of entry, recorded by the host when a module calls
the chain's PoX contract, as legacy does:

- **Stake**: the staker and the uSTX newly locked, recorded by every PoX
  function that locks uSTX. A `staking` allowance covers their sum within the
  frame.
- **PoX action**: the staker, recorded by every PoX function that otherwise
  changes or ends the staker's position. It is recorded whether or not the call
  succeeds, so an allowance gates even a failed attempt. A `pox` allowance
  covers it.

The staker is the frame's `sender` at the call. The ABI fixes what each kind of
entry means; the PoX contract specifies which of its functions record which
entry, so a later PoX contract can define its own. Legacy records only outflows,
merges burns into transfers for tokens, and does not record mints; recording
everything costs little and lets post-conditions and allowances say what they
mean.

### 8.3 Events

Events are `print` events and asset events, each tagged with the emitting
contract. They live in the frame that emitted them and commit or discard with
it.

### 8.4 Post-conditions

A transaction carries a post-condition mode and a list of post-conditions. Their
wire layout belongs to the transaction format; their meaning is defined here,
over the asset map (8.2), so they mean the same thing whatever module runs. The
kinds, codes, and modes are legacy's, as extended by SIP-040 (originator mode,
`may-send`) and SIP-045 (staking and PoX post-conditions).

**When.** The host evaluates post-conditions once, when the entry point sets an
ok result or `init` returns, over the asset map the transaction is about to
commit. Entries from discarded frames are already gone, so post-conditions see
exactly what would commit. A transaction whose entry point sets an err result
commits nothing and its post-conditions are not evaluated.

**Kinds.** Each post-condition names a principal, either explicitly or as the
transaction's origin account, and constrains that principal's outgoing entries:
transfers from it, burns from it, its stakes, and its PoX actions. The kinds
mirror the allowance kinds (7.2):

| Kind      | Fields                                         | Holds when                                                         |
| --------- | ---------------------------------------------- | ------------------------------------------------------------------ |
| `stx`     | principal, comparator, amount                  | the principal's uSTX transferred plus burned compares to `amount`  |
| `ft`      | principal, contract, token, comparator, amount | the principal's transfers and burns of that token, summed, compare |
| `nft`     | principal, contract, token, identifier, code   | the identifier's movement from the principal matches the code      |
| `staking` | principal, comparator, amount                  | the uSTX the principal newly locked, summed, compares to `amount`  |
| `pox`     | principal, code                                | whether the principal recorded a PoX action matches the code       |

A comparator is one of `=`, `<`, `<=`, `>`, `>=`, applied as "actual comparator
amount". Identifiers compare byte for byte, as in 7.2. The codes are:

| Kind  | Code            | Holds when                                             |
| ----- | --------------- | ------------------------------------------------------ |
| `nft` | `sent`          | the identifier left the principal (transfer or burn)   |
| `nft` | `not-sent`      | the identifier did not leave the principal             |
| `nft` | `may-send`      | always; it exists to cover the identifier (below)      |
| `pox` | `performed`     | the principal recorded at least one PoX action         |
| `pox` | `not-performed` | the principal recorded no PoX action                   |
| `pox` | `may-perform`   | always; it exists to cover the principal's PoX actions |

**Coverage.** A post-condition covers the outgoing entries it constrains,
whatever its comparator or code: an `stx` post-condition covers the principal's
STX entries, an `ft` the principal's entries for that token, an `nft` the
principal's entries for that one identifier, a `staking` the principal's stakes,
and a `pox` the principal's PoX actions.

**Modes.**

- **Allow**: every listed post-condition must hold.
- **Deny**: every listed post-condition must hold, and every outgoing entry in
  the asset map must be covered.
- **Originator**: every listed post-condition must hold, and every outgoing
  entry of the origin account must be covered. Other principals' entries need
  not be; a contract the user does not trust protects its own assets with
  allowance frames (7.2).

The **origin account** is the account of the transaction's origin spending
condition. It is fixed for the transaction: it is not the frame's `sender`, does
not change in an `as-contract` frame, and in a sponsored transaction is the
origin, not the sponsor.

A mint is not an outgoing entry for any principal, so recording mints (8.2)
never fails a deny-mode or originator-mode transaction. A transfer is outgoing
for its sender only.

A post-condition that does not hold makes the transaction's outcome
`post-condition failure` (10.1): state discarded, fee paid, no events.

## 9. Fuel, charges, and limits

### 9.1 Budget and fee

Cost has one dimension, **fuel**. Wasm execution, host functions, storage reads
and writes, instantiation, and the transaction's own processing are all charged
in fuel against one budget. Legacy's five dimensions (`runtime`, `read_count`,
`read_length`, `write_count`, `write_length`) do not exist here.

A transaction carries two fee fields:

| Field        | Meaning                                   |
| ------------ | ----------------------------------------- |
| `fuel-limit` | the most fuel the transaction may consume |
| `fuel-rate`  | the price, in uSTX per million fuel       |

Its maximum fee is `fuel-limit × fuel-rate / 10^6`, and the payer (the sponsor,
if there is one) must hold that much for the transaction to be valid. The fee
charged is the fuel consumed times the rate, rounded up to a whole uSTX; the
rest is never taken. A transaction that exceeds its limit is aborted with
`budget-exceeded` and pays for its whole limit. The whole fee goes to the miner;
there is no protocol base fee.

The rate is per million fuel because one fuel is about one Wasm instruction, so
any realistic price per fuel is far below 1 uSTX.

The two fields give a miner what it needs to build a block: it orders
transactions by rate and knows each one's worst case from its limit. A block has
one fuel limit (9.3), and a transaction whose execution would take the block
past it is not included.

Read-only queries pay no fee. Each node sets its own fuel limit for them and may
choose not to serve them at all.

### 9.2 Charges

Every charge is a worst-case price. A node may be faster in the common case, for
example by caching state, but the charge does not depend on it.

- **Intrinsic.** Before anything runs, the transaction is charged for its bytes
  and its signature check, and a deploy is charged for module bytes, validation,
  and compilation. A transaction whose intrinsic charge alone exceeds its
  `fuel-limit` is invalid and not included. Once the signature checks out, the
  transaction is included and pays, even if it then fails before executing (a
  missing function): the miner has done the work, and an unpaid failure would be
  a free way to make it do more.
- **Execution.** Wasm execution is metered by the engine: each operator consumes
  the fuel the schedule assigns it, and the engine traps when the budget runs
  out. Growing memory is charged per page.
- **Host functions.** Each has a base charge plus a per-byte charge on its
  inputs and outputs.
- **Storage.** Reads and writes are charged per access and per byte, priced so
  that a block spent entirely on them stays within what nodes can read, write,
  and keep. Writes are priced well above computation for that reason: there is
  no separate limit on state growth.
- **Instantiation.** Each call is charged per byte of the callee module, in
  place of legacy `LoadContract`.

The fuel schedule (these prices and the fuel of each Wasm operator) is
versioned, may change at an epoch, and applies to every module
([03-architecture.md](03-architecture.md) section 4). This is the one thing that
moves under a deployed module (R7). Because execution is metered by the engine,
the engine's fuel accounting is part of the schedule: an engine upgrade that
changes how much fuel any execution consumes is a consensus change, and the
chain pins the engine's behavior to the schedule.

### 9.3 Limits

| Limit                       | Value (provisional) | Notes                                                              |
| --------------------------- | ------------------- | ------------------------------------------------------------------ |
| Contract-call depth         | 64                  | 7.3                                                                |
| Instance memory             | 16 MiB              | bounds every intermediate value a module holds                     |
| Table entries               | TBD                 | bounds the allocation at instantiation                             |
| Transaction memory          | 64 MiB              | sum over live instances; caps depth × instance memory              |
| Wasm stack                  | TBD                 | in schedule-defined units, enforced by deploy-time instrumentation |
| Module size                 | TBD                 | the only bound on a contract's size                                |
| NFT identifier              | 1 MiB               | bytes per identifier                                               |
| Storage key                 | 1 KiB               | bytes per key                                                      |
| Storage value               | 1 MiB               | bytes per value                                                    |
| Arguments                   | 1 MiB               | bytes per transaction, query, or `call`                            |
| Result                      | 1 MiB               | bytes per `result_set`                                             |
| Print message               | 1 MiB               | bytes per `print`                                                  |
| Allowances per frame        | 128                 |                                                                    |
| Fuel per block              | TBD                 | 9.1                                                                |
| Fuel per read-only query    | node's choice       | 9.1                                                                |
| Event bytes per transaction | TBD                 |                                                                    |

Two of these need care beyond a number:

- **Stack.** Engine stack limits (wasmtime's `max_wasm_stack`) are in native
  bytes and differ by engine version and platform, so a stack overflow would not
  be deterministic. The chain bounds stack height in its own units, computed per
  function at deploy, and sets the native stack well above the maximum.
- **Memory.** Without a transaction cap, 64 nested instances at 16 MiB each is 1
  GiB. Growth is charged in fuel, and the cap is a runtime error.

## 10. Outcomes and errors

### 10.1 Transaction outcomes

| Outcome                       | Included | State               | Events in receipt |
| ----------------------------- | -------- | ------------------- | ----------------- |
| `ok`                          | yes      | committed           | yes               |
| `err`                         | yes      | discarded; fee paid | no                |
| aborted (runtime error)       | yes      | discarded; fee paid | no                |
| post-condition failure        | yes      | discarded; fee paid | no                |
| failed before execution (5.1) | yes      | none; fee paid      | no                |
| invalid (9.1, 9.2)            | no       |                     |                   |
| does not fit the block (9.1)  | no       |                     |                   |

A transaction is **invalid** when it cannot be charged: a bad signature or
nonce, a payer who cannot cover the maximum fee, an intrinsic charge above its
`fuel-limit`, or arguments over the arguments limit (9.3). Everything else a
miner does work on is included and paid for.

No other outcome exists (R6). In particular, the receipt of a discarded
transaction carries no events from the discarded execution, and a failed deploy
does not report `(ok true)`; both happen in legacy.

### 10.2 Runtime error classes

The receipt of an aborted transaction names one class:

| Class                 | Cause                                                             |
| --------------------- | ----------------------------------------------------------------- |
| `budget-exceeded`     | the transaction's `fuel-limit` (9.1)                              |
| `memory-exceeded`     | instance or transaction memory                                    |
| `stack-exceeded`      | Wasm stack limit                                                  |
| `depth-exceeded`      | contract-call depth                                               |
| `reentrancy`          | 7.3                                                               |
| `read-only-violation` | 7.4                                                               |
| `no-such-function`    | 5.1; 5.3, step 1                                                  |
| `no-result`           | an entry point returned without calling `result_set` (5.2)        |
| `bad-host-argument`   | 6.1                                                               |
| `unbalanced-frame`    | 7.1                                                               |
| `trap`                | any Wasm trap                                                     |
| `module-abort`        | `abort(code, msg)`; the receipt also carries the code and message |

`module-abort` codes belong to the source language. Clarity's compiler maps its
runtime errors (overflow, division by zero, `panic`, failed conversion, and a
value that fails validation at a call boundary, 5.4) to codes, which is how a
language vector's "abort, class arithmetic-overflow" is checked. Legacy and
clarity-wasm signalled these through exported globals and `unreachable`.

## 11. Versioning

- The import module name carries the ABI version: `stacks-abi-v1`. The interface
  section's `abi-version` must match.
- A frozen version never changes: its host functions, validation rules, and
  semantics are fixed for every module that targets it (R7). New functions and
  rules arrive as a new version, and the chain runs every frozen version it has
  ever accepted.
- The fuel schedule is versioned separately and applies to all modules (9.2).
- A module may target only one ABI version.
- Modules of different versions call each other freely; the call semantics of
  section 5 apply whichever version each side targets. Arguments and results are
  bytes the chain does not interpret (5.4), and interfaces carry no types (4.1),
  so the declared types are versioned with the interpretation layer
  ([08-value-interpretation.md](08-value-interpretation.md) section 8), not
  here, and never limit a call.

## 12. Changes to the earlier documents

Adopting this proposal changes the following. None of the changes is made yet.

1. **Hashes become host functions.** [03-architecture.md](03-architecture.md)
   section 2 compiles them into each module. Host wins on three counts: one
   audited implementation instead of one per compiler, a native-speed price for
   Merkle and SPV proofs that are central to sBTC, and every other source
   language needs the same functions (G2). The cost is a chain upgrade to speed
   up a hash, which the fuel schedule already covers.
2. **Exports have one Wasm type.** [03-architecture.md](03-architecture.md)
   section 3 requires "matching Wasm signatures". Under section 3.3 every entry
   is `[] -> []` and the check is that the export exists.
3. **Storage is an untyped key-value store** (4.2). The Clarity compiler lays
   out `define-data-var` and `define-map` in it by the declared layout of
   [08-value-interpretation.md](08-value-interpretation.md) section 7.2 and
   declares every variable and map in `abi.types`, so tools can read a Clarity
   contract's state; the Clarity spec must fix the prefixes it uses.
   [03-architecture.md](03-architecture.md) section 4 lists data-var and map
   host functions; they become one key-value store.
4. **A fungible token's cap is set by a host call during `init`** (6.2).
5. **`print` emits a string** (6.2). Legacy emits the printed value in SIP-005
   encoding, and spec section 3 types `print` as `(T) -> T`. Under this ABI the
   Clarity compiler renders the value as text, so the spec must define that
   rendering, and tools that decode legacy print events need a second path.
6. **NFT identifiers are bytes** (6.2). The identifier type of
   `define-non-fungible-token` stays in the Clarity spec and in the `abi.types`
   section, for tools, but leaves the interface the chain reads. The Clarity
   compiler encodes identifiers canonically
   ([08-value-interpretation.md](08-value-interpretation.md) section 3), so a
   Clarity token's identifiers have the same bytes as in legacy and in
   transaction post-conditions.
7. **Modules validate values; the chain does not** (5.4). The earlier documents
   have the chain validate every argument and result: [02-goals.md](02-goals.md)
   (the guarantees list), [03-architecture.md](03-architecture.md) sections 3,
   4, 5, and 7, [04-spec-plan.md](04-spec-plan.md) (the ABI chapter and the ABI
   vectors), and spec sections 2.3.3, 2.4.4, and 2.5.8. Under this ABI the
   Clarity compiler emits argument validation in every function it exports and
   result validation after every contract call, and the spec defines the abort
   codes for a failure, which replace the chain classes `bad-arguments`,
   `trait-mismatch`, and `bad-result`.
8. **Contract-call transactions carry their arguments as one byte string**
   (5.2). The legacy payload is a count and a list of encoded values, which the
   node decodes. Under this ABI the node passes the bytes to the entry point
   without parsing them, so the transaction format needs a payload that carries
   them opaquely. Wallets still build the bytes from canonical encodings
   ([08-value-interpretation.md](08-value-interpretation.md) section 6.1).
9. **The chain has no traits**
   ([08-value-interpretation.md](08-value-interpretation.md) section 5.2). Trait
   definitions, `impl-trait` claims, and trait-typed parameters leave the
   interface the chain reads, which [03-architecture.md](03-architecture.md)
   section 3 lists, and the chain checks conformance nowhere except in the
   legacy bridge (section 13, question 4). They move to `abi.types`: a compiler
   reads a trait's definition from the defining contract's section, checks
   conformance at compile time by the rule of
   [08-value-interpretation.md](08-value-interpretation.md) section 5.2, and
   validates the result of every call through a trait against the trait's
   declared result type (spec sections 2.4.4 and 2.5.8). A call to a function
   the trait marks `read-only` sets `call`'s `read_only` flag (5.3), so the host
   enforces the kind; the full signature is checked only at compile time. Spec
   section 2.3.2 refers to "chain ABI trait rules" for when a contract
   implements a trait; that becomes the same rule.

10. **Typed signatures leave the chain's interface** (4.1). The earlier
    documents put each function's parameter and result types in interface
    metadata that the chain validates: [02-goals.md](02-goals.md) (the single
    ABI), [03-architecture.md](03-architecture.md) section 3, and
    [04-spec-plan.md](04-spec-plan.md) (the ABI chapter). Under this ABI they
    are in `abi.types`, defined by
    [08-value-interpretation.md](08-value-interpretation.md), which the chain
    does not read. Provenance ([03-architecture.md](03-architecture.md)
    section 2) records, for each callee, the hash of both sections, since a
    build types its calls against `abi.types`.

## 13. Open questions

1. **Legacy costs in a fuel block.** Legacy transactions are costed in five
   dimensions, but a block has one fuel limit. Legacy costs need a defined
   conversion to fuel, and that conversion should deliberately overcharge legacy
   execution relative to Wasm, to encourage migration. How much, and whether the
   premium grows over time, are open.
2. **Wasm profile.** Section 3.1 hand-picks a subset of Wasm. The alternative is
   to adopt the deterministic profile of the Wasm specification, which would
   admit floating point and other features whose results it pins down. Open are
   which features that admits beyond 3.1, whether the chosen engine implements
   the profile exactly, and how each admitted operator is metered. Bulk memory
   is the known case: `memory.copy` and `memory.fill` need a per-byte charge,
   either from the engine or from deploy-time instrumentation of just those
   operators, and their real cost on the chosen engine, against the loops a
   compiler emits instead, decides whether that is worth it.
3. **Limit and price values** in 9.2 and 9.3, from benchmarks on the chosen
   engine, including the fuel per block and the storage prices.
4. **Legacy interop.** The mapping from legacy interfaces
   ([03-architecture.md](03-architecture.md) section 7) produces both an
   interface (4.1) and typed signatures
   ([08-value-interpretation.md](08-value-interpretation.md) section 5), and the
   type mapping's known mismatches (extra tuple fields, list union types, trait
   values carrying types) must each resolve to a rejection or a defined
   conversion. Legacy traits and `impl-trait` claims map to the `traits` and
   `implements` of `abi.types`. A call between a legacy and a Wasm contract is
   the one place the chain must interpret contract values, because the
   interpreter works on typed values: the host decodes the bytes coming from the
   Wasm side against the declared types, by canonical decoding
   ([08-value-interpretation.md](08-value-interpretation.md) section 3), and
   encodes the values coming from the legacy side the same way. That makes the
   interpretation layer's encoding consensus-critical, and the bridge the one
   part of this document that depends on it. For a Wasm contract calling a
   legacy one, the declared types are the legacy callee's own. For a legacy
   contract calling a Wasm one, they come from the callee's `abi.types`, so the
   chain must read and validate that section for any contract a legacy contract
   can call. When that call is through a trait, the bridge also checks, as the
   interpreter does for a legacy callee, that the callee conforms to the trait
   by the rule of [08-value-interpretation.md](08-value-interpretation.md)
   section 5.2. The mapping must also be deterministic and frozen, and produce
   canonical bytes for both sections: tokens, PoX, and sBTC are legacy
   contracts, so most Clarity builds read a legacy interface, and provenance
   records its hashes ([02-goals.md](02-goals.md) G5). If the mapping changed,
   those builds would no longer reproduce.
5. **Bounded and recoverable calls.** Two possible additions to `call` (5.3),
   both needed only for callees the caller cannot vouch for, such as a contract
   passed in as an argument or a module in another language:
   - A **fuel cap** passed into the callee's frame, as an additional check like
     an allowance. A callee that exceeds it stops having consumed at most the
     cap, so the static cost analyzer can bound such a call by its cap instead
     of the remaining budget ([05-roadmap.md](05-roadmap.md) risk 7). Without
     the second addition, exceeding the cap aborts the transaction.
   - **Catching a runtime error** from the callee: the callee's frame is
     discarded and the caller receives the error class instead of the
     transaction aborting. This relaxes "there is no catch" (5.3) and needs its
     own analysis against R6 and the language's abort semantics (spec 2.7.2).
6. **Formal definition** (R8). The host interface in section 6 should be
   published as one machine-readable file (WIT or a smaller purpose-made format)
   from which the host bindings, each compiler's import declarations, and the
   ABI vectors' function list are generated.
7. **Converting values in Wasm.** Every entry point decodes its arguments from
   canonical encoding into the module's memory layout, validating them on the
   way (5.4), and encodes its result back; every caller does the same for the
   result of each call. Whether that is fast enough as compiled Wasm, or whether
   it needs host functions that convert between canonical encoding and a defined
   memory layout, is open. Such functions would put one memory layout into the
   ABI, against R1, so the related question is whether canonical encoding can be
   brought closer to a natural Wasm layout (fixed-width little-endian integers,
   aligned fields) so that conversion is cheap or unnecessary, at the cost of
   SIP-005 compatibility
   ([08-value-interpretation.md](08-value-interpretation.md) section 3).
