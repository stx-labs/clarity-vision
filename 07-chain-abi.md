# Chain ABI Proposal

This is a proposal for the chain ABI: the contract between any compiler and the
chain, shared by every source language ([02-goals.md](02-goals.md) G2). It fills
in what [03-architecture.md](03-architecture.md) sections 3–5 sketch. It is
written to seed the joint draft with the chain team
([05-roadmap.md](05-roadmap.md) Phase 0), so it takes a position on every
question instead of listing options; the positions that change an earlier
document are collected in section 12, and the questions it cannot settle alone
are in section 13.

It draws on two prior systems:

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

## 2. Value model

### 2.1 Types

```
type ::= int | uint | bool | principal | never
       | (buff N) | (string-ascii N) | (string-utf8 N)
       | (list N type) | (optional type) | (response type type)
       | { name: type, ... }
```

The grammar describes the values in an interface (section 4) and the values the
host reads and writes itself (section 6). The chain does not check arguments or
results against it (5.4): it is the shared vocabulary that compilers, wallets,
and explorers use to describe and encode the values a contract exchanges. A
source language maps its own types onto these.

| Type               | Values                                                 |
| ------------------ | ------------------------------------------------------ |
| `int`              | signed 128-bit integers                                |
| `uint`             | unsigned 128-bit integers                              |
| `bool`             | `true`, `false`                                        |
| `principal`        | standard or contract principals                        |
| `never`            | none                                                   |
| `(buff N)`         | byte sequences of length at most `N`                   |
| `(string-ascii N)` | at most `N` bytes from the ASCII set of section 2.3    |
| `(string-utf8 N)`  | UTF-8 strings of at most `N` code points               |
| `(list N T)`       | sequences of at most `N` values of `T`                 |
| `(optional T)`     | `none`, or `(some v)` with `v` of `T`                  |
| `(response T E)`   | `(ok v)` with `v` of `T`, or `(err e)` with `e` of `E` |
| `{ f: T, ... }`    | records with exactly the listed fields                 |

- Every type is closed: no type variables, no unknown parts.
- `never` may appear anywhere a type may; a position of type `never` can hold
  nothing, and validation admits nothing for it.
- Tuples have exact field sets (R2). Zero-field tuples are allowed.

There is no trait type and no subtyping. Traits are a source-language concept: a
parameter that a language types as a trait is a `principal` in the interface,
and the language checks whatever it requires of that principal (5.4). Whether
one type may stand in for another is likewise the language's rule.

### 2.2 Names

| Kind                                              | Grammar                                                                       | Length      |
| ------------------------------------------------- | ----------------------------------------------------------------------------- | ----------- |
| Function, token, parameter, and tuple-field names | ASCII letters, digits, and `- _ ! ? + < > = / * ^`, not starting with a digit | 1–128 bytes |
| Contract names                                    | an ASCII letter, then letters, digits, `-`, `_`                               | 1–40 bytes  |

Every source language shares these rules. One contract-name limit applies
everywhere: in deploys, in values, and on the wire. Legacy has 40 at deploy and
128 inside values before epoch 4.1.

### 2.3 Canonical encoding

The encoding is SIP-005, byte for byte, for every value that exists in legacy,
so values pass between legacy and Wasm contracts and between the chain and
existing tooling without translation. The host uses it for every value it
decodes or produces: the arguments of host functions (6.1), chain data, and
allowance descriptors. It is also the standard encoding of arguments and results
(5.4), which the chain passes through without decoding. What changes from legacy
is decoding, which accepts only the canonical form.

| Prefix | Value              | Payload                                                         |
| ------ | ------------------ | --------------------------------------------------------------- |
| `0x00` | `int`              | 16 bytes, two's complement, big-endian                          |
| `0x01` | `uint`             | 16 bytes, big-endian                                            |
| `0x02` | `buff`             | u32 BE length, bytes                                            |
| `0x03` | `true`             |                                                                 |
| `0x04` | `false`            |                                                                 |
| `0x05` | standard principal | version (1 byte, < 32), hash160 (20 bytes)                      |
| `0x06` | contract principal | version, hash160, u8 name length, name                          |
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

- the prefix is one that `T` admits; `principal` admits `0x05` and `0x06`;
- lengths and counts are within `T`'s bounds; `string-utf8` bounds count code
  points;
- tuple fields are exactly `T`'s fields, in strictly ascending byte order of
  name, with no duplicates;
- `string-ascii` bytes are 0x20–0x7E, tab, line feed, or carriage return (legacy
  also admits form feed), and `string-utf8` bytes are valid UTF-8 (no
  surrogates, no overlong forms);
- principals have a version below 32 and a valid contract name;
- nesting depth is at most 32, counted the same way everywhere;
- no bytes remain after the value.

There is no sanitizing and no untyped decoding in the host. Self-describing
prefixes are kept for tooling; every decode in the host is typed.

### 2.4 Sizes

`serialized-size(T)` is the largest encoding of any value of `T`:

| Type                           | `serialized-size`              |
| ------------------------------ | ------------------------------ |
| `int`, `uint`                  | 17                             |
| `bool`                         | 1                              |
| `principal`                    | 63 (1 + 1 + 20 + 1 + 40)       |
| `never`                        | 0                              |
| `(buff N)`, `(string-ascii N)` | 5 + N                          |
| `(string-utf8 N)`              | 5 + 4N                         |
| `(list N T)`                   | 5 + N × size(T)                |
| `(optional T)`                 | 1 + size(T)                    |
| `(response T E)`               | 1 + max(size(T), size(E))      |
| `{ f1: T1, ... }`              | 5 + Σ (1 + len(fi) + size(Ti)) |

The **value size limit** (section 9.3, 1 MiB) is a limit on `serialized-size`.
Legacy measures a separate abstract "size" that disagrees with the bytes (a
principal is 148 there and up to 151 on the wire); the ABI has one measure.

### 2.5 Type encoding

Interfaces carry types in a binary encoding that reuses the value prefixes:

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

Names are a u8 length and the bytes. Like values, a type has one encoding, and
an interface containing a type whose `serialized-size` exceeds the value size
limit is rejected at deploy.

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

| Section          | Required | Validated by the chain                                                                                                           |
| ---------------- | -------- | -------------------------------------------------------------------------------------------------------------------------------- |
| `abi.interface`  | yes      | yes (section 4)                                                                                                                  |
| `abi.provenance` | no       | only for size; contents are owned by the toolchain that produced the module ([03-architecture.md](03-architecture.md) section 2) |

Any other custom section, including `name`, is rejected. The module is the unit
that `contract-hash?` hashes and that `clarity-verify` compares, so it carries
nothing that is not either executed, validated, or provenance.

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

The `abi.interface` section is one canonically encoded record:

| Field         | Contents                                                                                 |
| ------------- | ---------------------------------------------------------------------------------------- |
| `abi-version` | the ABI version the module targets                                                       |
| `functions`   | per function: name, kind (`public` or `read-only`), parameters (name, type), result type |
| `fts`         | per fungible token: name                                                                 |
| `nfts`        | per non-fungible token: name                                                             |

Rules:

- Names are unique within each list. Lists are sorted by name, so the encoding
  is canonical and an interface has one hash: `sha512/256` of the section bytes.
  That hash is what provenance records for each callee
  ([03-architecture.md](03-architecture.md) section 2).
- A `public` function's result type is a `response`, whose arms describe the
  result for each value of the flag that `result_set` takes (5.2). A `read-only`
  function's result type is any type.
- Parameter and result types are declarations, not checks: the chain uses the
  interface to find functions, their kinds, and tokens, and does not check
  values against the declared types (5.4).
- At most 256 parameters per function, as legacy.
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
language structures its state.

The cost is that state is not self-describing: an explorer, a wallet, or the
node's state read endpoint returns raw bytes, and decoding them needs the source
language's layout. A language that wants its state readable by tools publishes
that layout, as the Clarity spec will (section 12).

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
  takes them as `args`. The chain does not parse them. By convention they are
  each argument's canonical encoding, concatenated in parameter order (5.4).
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
call(target: val<principal>, fn: bytes, args: bytes, out: buf, ok: out<1>) -> len
```

In the notation of 6.1, this is the Wasm type
`(param i32 i32 i32 i32 i32 i32 i32 i32 i32) (result i32)`.

- `target` is the callee, a principal.
- `fn` is the function name's bytes (2.2), not an encoded value.
- `args` is the arguments as in 5.2, passed to the callee unchanged.
- `ok` receives the callee's result flag (5.2), as one byte.

The host, in order:

1. Resolves the target. A standard principal, a missing contract, or a missing
   function is a runtime error (`no-such-function`).
2. If the current frame is read-only, requires `fn` to be `read-only` (section
   7.4).
3. Applies the reentrancy and depth rules (section 7.3).
4. Opens the callee's frame, instantiates a fresh instance, runs the export, and
   closes the frame: for a public function, commit if the result flag is ok and
   discard if it is err.
5. Writes the result flag to `ok`, writes the result to `out`, and returns its
   length. If `cap` is too small, it writes the flag but not the result, keeps
   the result, and returns the negated length; `result_read(dst, offset, len)`
   then copies the kept result, whole or in pieces. A kept result lasts until
   the next `call`; `result_read` with no kept result is a `bad-host-argument`
   runtime error. The callee's frame has already closed either way. A Clarity
   module sizes `out` for the `serialized-size` of the declared result and
   treats a longer result as one that fails validation (5.4), so it never needs
   the second step.

Steps 1–3 failing, and any runtime error in the callee, abort the transaction.
There is no catch.

### 5.4 Values at a call boundary

The chain does not validate the values that cross a call boundary: the arguments
of a transaction or query (5.1), the arguments of a `call` (5.3), and every
result (5.2) pass through as bytes. A module validates what it receives. A
callee validates its arguments, and a caller validates the result of every call,
since nothing guarantees that either matches the declared types; that includes
whatever a language requires of a principal it types as a trait. Validation is
module code, charged as execution (9.2) like any other work.

The declared types still matter outside the chain. Wallets encode arguments and
clear-sign transactions from them, explorers decode results with them, and
compilers type calls against them. The standard encoding of an argument list or
a result is canonical encoding (2.3), which is what every tool expects. A
language that has no use for structured values declares `(buff N)` parameters
and results and treats them as bytes.

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

| Kind       | Wasm parameters      | Meaning                                                                                                                            |
| ---------- | -------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| `i32`      | `i32`                | an integer, as the function describes                                                                                              |
| `u128`     | `i64 lo`, `i64 hi`   | an unsigned 128-bit integer, low 64 bits first                                                                                     |
| `val<T>`   | `i32 ptr`, `i32 len` | the canonical encoding (2.3) of a value of `T`, decoded against `T`; a failed decode is `bad-host-argument`                        |
| `bytes`    | `i32 ptr`, `i32 len` | raw bytes, not an encoded value                                                                                                    |
| `bytes<N>` | `i32 ptr`            | exactly `N` raw bytes                                                                                                              |
| `out<N>`   | `i32 ptr`            | the host writes exactly `N` bytes; a `u128` result is written as 16 bytes, little-endian                                           |
| `buf`      | `i32 ptr`, `i32 cap` | the host writes at most `cap` bytes and returns the length; what it writes (an encoded value, or raw bytes) is stated per function |

| Result   | Wasm result | Meaning                                                                                                                   |
| -------- | ----------- | ------------------------------------------------------------------------------------------------------------------------- |
| none     | none        |                                                                                                                           |
| `len`    | `i32`       | the number of bytes written to the `buf`, with the short-buffer rule of 5.3; `-1` means "none" where the function says so |
| `status` | `i32`       | `0` for success, otherwise one of the codes listed with the function                                                      |
| `bool`   | `i32`       | `1` for true, `0` for false                                                                                               |

For example, `stx_burn(amount: u128, from: val<principal>) -> status` is
imported with Wasm type `(param i64 i64 i32 i32) (result i32)`.

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

#### Context and chain data

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

The three chain-data lookups below are total: each returns `-1` for any height
the host cannot serve, and no height is ever a runtime error or a reason to drop
the transaction.

##### `stacks_block_info`

```
stacks_block_info(height: u128, out: buf) -> len
```

Writes the encoded record of the Stacks block at `height`:

| Field            | Type        |
| ---------------- | ----------- |
| `id-header-hash` | `(buff 32)` |
| `header-hash`    | `(buff 32)` |
| `time`           | `uint`      |

Serves heights below `stacks_height`. The current block's hashes do not exist
until it is sealed, after this transaction runs; its time is what `time`
returns.

##### `tenure_info`

```
tenure_info(height: u128, out: buf) -> len
```

Writes the encoded record of the tenure at `height`:

| Field                   | Type              |
| ----------------------- | ----------------- |
| `burnchain-header-hash` | `(buff 32)`       |
| `miner-address`         | `principal`       |
| `time`                  | `uint`            |
| `vrf-seed`              | `(buff 32)`       |
| `block-reward`          | `(optional uint)` |
| `miner-spend-total`     | `uint`            |
| `miner-spend-winner`    | `uint`            |

Serves every tenure up to and including `tenure_height`, since all fields are
fixed at sortition. `block-reward` is `none` until the reward matures; maturity
is defined by the host in terms of the tenure height at which the reward was
recorded.

##### `burn_block_info`

```
burn_block_info(height: u128, out: buf) -> len
```

Writes the encoded record of the burn block at `height`:

| Field         | Type                                                                             |
| ------------- | -------------------------------------------------------------------------------- |
| `header-hash` | `(buff 32)`                                                                      |
| `pox-addrs`   | `{ addrs: (list 2 { hash-bytes: (buff 32), version: (buff 1) }), payout: uint }` |

Serves every burn block up to and including `burn_height`.

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
ft_mint(token: i32, amount: u128, to: val<principal>) -> status
```

Mints `amount` to `to`. Exceeding the supply cap is a runtime error.

- `1` amount is zero

##### `ft_burn`

```
ft_burn(token: i32, amount: u128, from: val<principal>) -> status
```

Burns `amount` from `from`.

- `1` insufficient balance, or amount is zero

##### `ft_transfer`

```
ft_transfer(token: i32, amount: u128, from: val<principal>, to: val<principal>) -> status
```

Moves `amount` from `from` to `to`.

- `1` insufficient balance
- `2` `from` is `to`
- `3` amount is zero

##### `ft_balance`

```
ft_balance(token: i32, owner: val<principal>, out: out<16>)
```

Writes `owner`'s balance as a `u128`.

##### `ft_supply`

```
ft_supply(token: i32, out: out<16>)
```

Writes the circulating supply as a `u128`.

##### `nft_mint`

```
nft_mint(token: i32, id: bytes, to: val<principal>) -> status
```

Mints the identifier `id` to `to`.

- `1` already exists

##### `nft_burn`

```
nft_burn(token: i32, id: bytes, from: val<principal>) -> status
```

Burns `id`, which `from` must own.

- `1` not owned by `from`
- `3` does not exist

##### `nft_transfer`

```
nft_transfer(token: i32, id: bytes, from: val<principal>, to: val<principal>) -> status
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
stx_transfer(amount: u128, from: val<principal>, to: val<principal>,
             memo: val<(optional (buff 34))>) -> status
```

Moves `amount` uSTX from `from` to `to`, recording the memo in the event if it
is `some`.

- `1` insufficient balance
- `2` `from` is `to`
- `3` amount is zero
- `4` `from` is not the frame's `sender`

##### `stx_burn`

```
stx_burn(amount: u128, from: val<principal>) -> status
```

Burns `amount` uSTX from `from`.

- `1` insufficient balance
- `3` amount is zero
- `4` `from` is not the frame's `sender`

##### `stx_account`

```
stx_account(owner: val<principal>, out: buf) -> len
```

Writes `owner`'s STX account state, encoded as a record:

| Field           | Type   |
| --------------- | ------ |
| `locked`        | `uint` |
| `unlock-height` | `uint` |
| `unlocked`      | `uint` |

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
call(target: val<principal>, fn: bytes, args: bytes, out: buf, ok: out<1>) -> len
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
contract_hash(contract: val<principal>, out: out<32>) -> status
```

Writes the `sha512/256` of the contract's module.

- `1` the principal is a standard principal
- `2` no such contract

##### `principal_to_ascii`

```
principal_to_ascii(p: val<principal>, out: buf) -> len
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
rendered, and a module that wants to emit structured data formats it itself.
Asset events are emitted by the asset functions themselves.

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
`desc` starts with the owner's canonical encoding (a `principal`). Then, for
both kinds:

- a u8 count of allowances, at most 128;
- per allowance, a kind byte, then its fields in the order of the table below,
  each as a canonical encoding of the field's type;
- for `nft`, the `ids` field is a u32 BE count, then per identifier a u32 BE
  length and the identifier's bytes (6.2).

No bytes may follow the last allowance. A descriptor that does not decode this
way is a `bad-host-argument` runtime error. The allowance kinds are ABI data:

| Byte | Kind      | Fields                                                                 | Covers                                                  |
| ---- | --------- | ---------------------------------------------------------------------- | ------------------------------------------------------- |
| `0`  | `stx`     | `amount: uint`                                                         | the owner's uSTX transferred plus burned                |
| `1`  | `ft`      | `contract: principal`, `token: (string-ascii 128)`, `amount: uint`     | the owner's movements of that token, summed             |
| `2`  | `nft`     | `contract: principal`, `token: (string-ascii 128)`, `ids`: identifiers | each moved identifier must be listed, compared by bytes |
| `3`  | `all`     | none                                                                   | everything; only in an `as-contract` frame              |
| `4`  | `staking` | `amount: uint`                                                         | the uSTX the owner locks for staking, summed            |
| `5`  | `pox`     | none                                                                   | any position-altering PoX action by the owner           |

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
only `read-only` callees. Legacy checks storage writes at runtime but relies on
analysis for asset functions; here every mutation is checked.

## 8. State and effects

### 8.1 State layout

Contract storage is keyed by contract and the key's bytes, and stores the
value's bytes as given (4.2). Token state is keyed by contract, token name, and,
for NFTs, the identifier's bytes. Balances and supplies are `uint` in canonical
encoding. Legacy uses serde JSON for principals in token-balance keys and for
persisted type metadata; nothing here depends on a language's in-memory
representation. The concrete key strings are the chain's choice, made once.

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
| Value size                  | 1 MiB               | `serialized-size` of any type in an interface                      |
| Type nesting depth          | 32                  |                                                                    |
| Contract-call depth         | 64                  | 7.3                                                                |
| Instance memory             | 16 MiB              | bounds every intermediate value a module holds                     |
| Table entries               | TBD                 | bounds the allocation at instantiation                             |
| Transaction memory          | 64 MiB              | sum over live instances; caps depth × instance memory              |
| Wasm stack                  | TBD                 | in schedule-defined units, enforced by deploy-time instrumentation |
| Module size                 | TBD                 | the only bound on a contract's size                                |
| NFT identifier              | 1 MiB               | bytes per identifier, the same as the value size limit             |
| Storage key                 | 1 KiB               | bytes per key                                                      |
| Storage value               | 1 MiB               | bytes per value                                                    |
| Arguments                   | 1 MiB               | bytes per transaction, query, or `call`                            |
| Result                      | 1 MiB               | bytes per `result_set`                                             |
| Print message               | 1 MiB               | bytes per `print`, the same as the value size limit                |
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
  bytes the chain does not interpret (5.4), so a type that one version's
  interfaces can declare and another's cannot is a matter for the caller's
  compiler, not a limit on the call.

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
3. **Storage is an untyped key-value store** (4.2). The Clarity spec must define
   how `define-data-var` and `define-map` lay out keys and values in it, both
   for the compiler and so tools can read a Clarity contract's state.
   [03-architecture.md](03-architecture.md) section 4 lists data-var and map
   host functions; they become one key-value store.
4. **A fungible token's cap is set by a host call during `init`** (6.2).
5. **`print` emits a string** (6.2). Legacy emits the printed value in SIP-005
   encoding, and spec section 3 types `print` as `(T) -> T`. Under this ABI the
   Clarity compiler renders the value as text, so the spec must define that
   rendering, and tools that decode legacy print events need a second path.
6. **NFT identifiers are bytes** (6.2). The identifier type of
   `define-non-fungible-token` stays in the Clarity spec but leaves the
   interface. The Clarity compiler encodes identifiers canonically (2.3), so a
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
   them opaquely. Wallets still build the bytes from canonical encodings (5.4).
9. **The chain has no traits** (2.1). Trait definitions, `impl-trait` claims,
   and trait-typed parameters leave the interface, which
   [03-architecture.md](03-architecture.md) section 3 lists, and the chain
   checks conformance nowhere. The Clarity spec must say where a compiler reads
   a trait's definition from, for example the defining contract's
   `abi.provenance` section (3.4), and its compiler checks conformance at
   compile time and validates trait-typed arguments and results at runtime (spec
   sections 2.4.4 and 2.5.8).

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
4. **Legacy interop.** The mapping from legacy interfaces to this type grammar
   ([03-architecture.md](03-architecture.md) section 7) targets the types in
   2.1, and its known mismatches (extra tuple fields, list union types, trait
   values carrying types) must each resolve to a rejection or a defined
   conversion. A call between a legacy and a Wasm contract is the one place the
   host must still decode arguments and results, because the interpreter works
   on typed values; the conversion happens there. The mapping must also be
   deterministic and frozen, and produce canonical interface bytes: tokens, PoX,
   and sBTC are legacy contracts, so most Clarity builds read a legacy
   interface, and provenance records its hash ([02-goals.md](02-goals.md) G5).
   If the mapping changed, those builds would no longer reproduce.
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
   SIP-005 compatibility (2.3).
