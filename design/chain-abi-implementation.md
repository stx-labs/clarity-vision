# Chain ABI: Implementation Design

This is the design for building the chain ABI
([07-chain-abi.md](../07-chain-abi.md)) into stacks-core: where the code lives,
what it reuses, the decisions the ABI leaves to the chain, how it is tested, and
the order of work. Nothing here is normative. Where it disagrees with 07 or
[08-value-interpretation.md](../08-value-interpretation.md), they are right,
except where section 10 proposes an amendment. "Chain ABI 5.3" refers to
sections of 07, "interpretation 3" to sections of 08. It covers the chain side
of [05-roadmap.md](../05-roadmap.md) Phase 1 (reach ABI v1) and chain
integration (clarity-wasm epic 891).

## 1. Goals and non-goals

Goals:

1. **The node runs ABI v1.** It deploys and executes modules by chain ABI
   sections 3–11, from a new epoch. Legacy contracts keep running on the
   interpreter with unchanged semantics.
2. **Every rule has a vector.** Each rule of the runtime layer has a rule id and
   is covered by an ABI vector ([04-spec-plan.md](../04-spec-plan.md)) that runs
   against the host alone, in seconds, and again through the node.
3. **One definition.** The host interface has one definition, a Rust table in
   `stacks-abi`: the host's import checks read it, and the forms other consumers
   need are generated from it (chain ABI R8).
4. **Wasm contracts use the legacy ecosystem.** A Wasm contract calls any legacy
   contract, PoX included, and a legacy contract calls a Wasm contract through a
   trait, so an existing DEX can hold a Wasm token. No type mapping is needed:
   SIP-005 is self-describing and legacy's runtime checks apply. No legacy
   contract is deployed after the epoch (2.8), so none can name a Wasm contract
   by literal.
5. **A devnet runs modules before the compiler exists.** Hand-written modules
   deploy and run end to end, so the chain work does not wait on the compiler.

Non-goals: the Clarity compiler and the language vectors; interpretation-layer
tooling (the `abi.types` codec, typed decoding, the legacy interface mapping),
which the chain does not run; wallet, explorer, Clarinet, and Stacks.js changes
beyond what they consume (section 8); replacing the interpreter or moving PoX to
Wasm (section 9); final limit and price values, which M5 proposes.

## 2. Decisions

Each decision states what is chosen, why, and what it costs. **(SIP)** marks a
change to consensus rules or the transaction format.

### 2.1 The clarity-wasm host is not reused

The host in stacks-core's `feat/clarity-wasm-develop` branch (`clarity_wasm.rs`,
about 11,500 lines) links about 100 host functions shaped by Clarity's types, on
wasmtime; chain ABI 1 lists the problems that shape caused. This design starts
from an empty host. The clarity-wasm repository's crosscheck harness is the
model for the bridge crosscheck (section 5), and its benchmark methodology for
M5.

### 2.2 Engine: wasmi 2.0, pinned, with its built-in fuel

The engine is wasmi 2.0.x at one exact version, pinned in the workspace and
named by the fuel schedule (2.12). It is an interpreter with no
platform-dependent compiled form, and its fuel is priced per Wasm operator.
Every option is set explicitly, so a later default cannot opt the chain in to
anything:

- `consume_fuel(true)`; `Config::operator_cost`, and `Config::fuel_cost` with
  `CustomFuelCosts::bytes_copied_per_fuel`, from the schedule.
- `CompilationMode::Eager`, mandatory. The lazy modes translate a function on
  its first call, charge that caller's fuel for it, and share the result with
  every later call, so fuel would depend on what the node ran before.
- Floats off; mutable globals, sign extension, multi-value, and bulk memory on;
  every other proposal off, reference types and tail calls included.
- `Config::set_max_recursion_depth` and `set_max_stack_height` far above what
  the stack bound of 2.11 admits: a safety net, never the rule.

How wasmi charges, which the schedule takes as given: each operator's price is a
`u8`, so the most expensive operator is priced at most 255. The prices of a
region's operators (a function body, a loop body, a non-constant `if` arm, an
`else`, the join after an `if` with results and no `else`) are charged together
when the region is entered, so operators skipped by an early `br` or `return`,
and dead code, are charged, and an `if` whose condition the translator folds to
a constant is charged to its parent region. Running out traps before the region
and leaves the remaining fuel unchanged. Bulk-memory, table, and `memory.grow`
operators add ⌊bytes ÷ `bytes_copied_per_fuel`⌋ (4 bytes per table element), one
ratio for all, so a page of growth costs the `memory.grow` price plus 65,536 ÷
ratio, charged after the operator's bounds checks.

Fuel consumption is therefore defined by the pinned engine version and
configuration, identical on every platform but not reproducible by another
engine. An engine upgrade is a schedule-version change at an epoch, and CI
vectors keep an unintended one from landing (E4). Section 9 has the
engine-independent alternative.

wasmi cannot serialise translated code, so prepared modules (validated,
instrumented, translated) are cached in memory, keyed by module hash and
schedule version, under a node-set byte limit with least-recently-used eviction.
Eager translation, and an instantiation charge every call pays (chain ABI 9.2),
make the cache invisible to consensus. The host reaches wasmi through a small
internal trait, so an engine change stays local.

### 2.3 Where the code lives

| Crate                                 | Contents                                                                                                                                                                                                                                                                                            | Depends on                                                              |
| ------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------- |
| `crates/stacks-abi` (new)             | The definition: the host-interface table (2.15); codecs for names and principals (chain ABI 2), `abi.interface` (4.1), and allowance descriptors (7.2); limits (9.3), error classes (10.2), status codes (6.2), deploy rejection reasons (2.10); event size (8.3); the fuel schedule as data (2.12) | `stacks-common`, `clarity-types`                                        |
| `crates/stacks-wasm-host` (new)       | The runtime: engine trait and wasmi configuration, deploy pipeline, stack pass, the 66 host functions over a `ChainState` trait (3.1), frames and fuel on the host side, an in-memory `ChainState`, and the ABI vector runner                                                                       | `stacks-abi`, `stacks-transactions`, `clarity-types`, wasmi, wasmparser |
| Existing crates                       | `clarity-types`: the asset map extension; `stacks-transactions`: the shared post-condition evaluator and allowance check (2.7); `stacks-codec`: the new payloads (2.8); `clarity`: the commitment and key forms and a dispatch hook (2.4, 2.5, 2.14)                                                |                                                                         |
| stackslib, stacks-node, stacks-signer | `ChainState` over `GlobalContext`; transaction processing, fees, mempool, miner, tenure budget, receipts, events, RPC, epoch gating                                                                                                                                                                 | the above                                                               |

The new crates follow `crates/stacks-transactions`: no node dependency, a
`wasm-web` feature for browser builds (`stacks-abi` needs only `clarity-types`
and `stacks-common`, which build for the browser). `clarity` does not depend on
the host. It gets a hook in the pattern `pox-locking` uses
(`ClarityBackingStore::get_cc_special_cases_handler`): the store returns an
optional foreign-call handler for a callee, and stackslib supplies it.
Wasm-to-legacy calls enter through `ExecutionState::execute_contract`, so the
PoX special-case handler runs.

### 2.4 Contract identity

The MARF commits to every contract through `clarity-contract::{contract}`:
`sha512/256(source)` and the deploy height, 72 hex characters
(`ContractCommitment`). A Wasm contract's commitment hashes the module bytes and
appends a kind byte (74 characters); 72 characters read as legacy. Kinds: `00`
legacy (implied, never written), `01` Wasm module, `02` reserved for a compiled
legacy contract, the rest reserved. The module bytes go in the metadata store,
as legacy source does, under a new `ContractDataVarName` (`wasm-module`), with
`contract-size` set to the module length and `contract-data-size` to 0, as
`LoadContract` sizing needs; integrity rests on the committed hash.
`ContractCommitment::deserialize`, which rejects other lengths with an `Expect`
error, accepts 72 and 74 characters, and every reader handles kind `01`.

One existence check serves both runtimes: from the epoch, the deploy duplicate
check in `processing/payload.rs` (`StacksChainState::get_contract`, which reads
a metadata key Wasm contracts lack), mempool admission (`can_include_tx`), and
`ClarityDatabase::has_contract` (`contract-of`) test the commitment. A Wasm
deploy to a taken name is what a duplicate legacy deploy is today: invalid
(`Duplicate contract`), rejected by the mempool with `ContractAlreadyExists`.
`AnalysisDatabase::insert_contract` keeps its own test, since it runs after the
deploy writes its commitment. Legacy `contract-hash?` and Wasm `contract_hash`
both return the committed hash.

### 2.5 State layout: a key scheme for Wasm contracts

Chain ABI 8.1 leaves the keys and value encodings to the chain. Wasm contracts
get their own, and each value is committed as a hash of a tag and its raw bytes:

| State         | MARF key                                         | Tag (hex)                  | Raw value                               |
| ------------- | ------------------------------------------------ | -------------------------- | --------------------------------------- |
| Storage entry | `wasm::{c}::kv::{hex(key)}`                      | `000101`; deleted `000102` | the value bytes; deleted: empty         |
| FT balance    | `wasm::{c}::ftb::{token}::{hex(principal)}`      | `000103`                   | `u128`, 16 bytes little-endian          |
| FT supply     | `wasm::{c}::fts::{token}`                        | `000104`                   | `u128`; written as 0 at deploy          |
| FT cap        | `wasm::{c}::ftc::{token}`                        | `000105`                   | `u128`; absent means no cap             |
| NFT owner     | `wasm::{c}::nft::{token}::{hex(sha512/256(id))}` | `000106`; burned `000107`  | owner's SIP-005 encoding; burned: empty |
| Contract      | `clarity-contract::{c}` (2.4)                    | legacy text                |                                         |
| STX           | the shared account structure                     |                            |                                         |

`{c}` is the contract's text form, `{token}` the token name, `hex` lowercase,
and `principal` its SIP-005 encoding. A tag is `00`, the scheme version `01`,
and the state kind. The MARF has no delete, so `kv_delete` and `nft_burn` write
the deleted forms, which read as absent.

**Commitment.** The MARF leaf is `MARFValue::from_value_hash(H(tag ‖ raw))`,
with `H` the hash `MARFValue::from_value` uses. The side-store row is keyed by
the leaf, as every row is, and holds `hex(tag ‖ raw)`, so a read recovers the
tag and a deleted or burned form reads as absent while an empty value does not;
`RollbackWrapper`'s pending map carries the same bytes. A legacy leaf hashes
text, which never starts with byte `00`, so the two never share a row.

**The hook.** Today the leaf is the hash of the stored text: `put_all_data` in
`stackslib/src/clarity_vm/database/marf.rs` computes
`MARFValue::from_value(&text)` over `(key, text)` edits buffered by
`RollbackWrapper`. An edit may now carry a precomputed leaf, which
`ClarityBackingStore::put_all_data` uses, in every implementation (MARF,
`EphemeralMarfStore` for simulate and replay, both in-memory stores, SQLite,
null, the test `RecordingStore`). Reads are unchanged; a `/v2/clarity/marf`
proof consumer hashes the decoded row. The cost is a type change in
`RollbackWrapper`'s edits and lookup map and a branch per store, about a week.

**Why not legacy's keys.** They would freeze serde-JSON principals in balance
keys, JSON balances, NFT identifiers of up to 1 MiB as hex inside keys, and a
hash of text as every leaf. Legacy's token methods also need typed metadata that
Wasm tokens lack, and legacy keeps the FT cap uncommitted.

**Frozen in consensus:** the key strings, the tags, the raw encodings, `H`, the
deleted forms, and the commitment's kind byte. **Not frozen:** the side store's
physical encoding (hex text now; binary later needs no consensus change,
section 9) and the module's encoding in the metadata store. Storage charges are
on raw bytes.

### 2.6 One transaction context

From the epoch, legacy's `GlobalContext` is the context of every transaction,
whichever runtime it starts in. Wasm frames open and close through its begin,
commit, and rollback, which already nest `RollbackWrapper` writes, an `AssetMap`
and `EventBatch` per level, and the read-only flag. The host adds only what
legacy does not track (3.2). There is one asset map and one event list, and the
stake and PoX-action entries `pox-locking` logs reach Wasm frames untranslated.

- **Reentrancy.** Legacy-to-legacy calls keep legacy's (contract, function)
  rule, since changing it would change deployed contracts. A call with Wasm on
  either side applies chain ABI 7.3's contract rule, against the host's active
  set and legacy's call stack.
- **Depth and memory.** The depth is the number of contract-call frames of both
  runtimes on the combined stack; a call with Wasm on either side fails with
  `depth-exceeded` if it would make that 65. Legacy's own depth and memory
  limits still apply inside legacy code.
- **Sender and caller** follow chain ABI 5.1. A legacy callee's `tx-sender` is
  the calling frame's `sender` and its `contract-caller` the Wasm caller (its
  `InvocationContext` holds a transient `ContractContext` of that name); a Wasm
  callee's `sender` is `tx-sender` and its `caller` the legacy caller. Sponsor
  is the transaction's.
- **Native stack.** Wasm calls within an instance use wasmi's heap stack, but
  each `call` re-enters the engine on the native stack and each bridged legacy
  frame recurses in the interpreter. Transaction execution runs on a thread
  whose stack is sized for 64 worst-case frames, pinned by a vector (D6).

### 2.7 Post-conditions and allowances

- **Asset map.** `clarity-types`' `AssetMap` already records STX transfers and
  burns, FT and NFT outflows (burns as the burner's outflows), stakes, and PoX
  actions. It gains FT and NFT mints, recorded by the Wasm host for events and
  chain ABI 8.2 (nothing evaluates them: a mint is not outgoing), and raw-byte
  NFT identifiers for Wasm tokens. Legacy code records what it records today.
- **Post-conditions.** `check_transaction_postconditions` in
  `crates/stacks-transactions` evaluates every payload; for a byte identifier it
  compares the SIP-005 serialization of the post-condition's value. The wire
  format is unchanged, so an identifier that is not a valid SIP-005 encoding
  cannot be named (section 10).
- **Allowances.** Legacy's `check_allowances` and `Allowance` move from
  `clarity/src/vm/functions/post_conditions.rs` into `stacks-transactions`. Wasm
  `frame_close(1)`, `as-contract?`, and `restrict-assets?` call it over the same
  map, so each sees the other runtime's movements.

This meets chain ABI 7.2 and 8.4 as written: allowance kinds and the returned
index (first violated, or 128), post-condition kinds, codes, coverage, the three
modes, and the origin account; A4b and A5 run their vectors against the shared
code. Legacy behaviour does not change and no gate is added: the only new input
a legacy evaluation can see is a Wasm callee's movements, which cannot exist
before the epoch.

### 2.8 Transaction format (SIP)

- Two payloads in `stacks-codec`: Wasm deploy (id 9: version byte, contract
  name, `fuel-limit`, module bytes) and Wasm call (id 10: version byte, contract
  principal, function name, `fuel-limit`, argument bytes, carried opaquely as
  chain ABI 12 item 8 needs). The version byte allows later fields. Both are
  on-chain only, follow the 40-byte name rule, and are invalid before the epoch.
- The authorization's fee field carries `fuel-rate`, in uSTX per million fuel.
  The maximum fee is ⌈`fuel-limit` × `fuel-rate` ÷ 10⁶⌉ in `u128`; one that does
  not fit `u64` makes the transaction invalid. `StacksTransaction::max_fee()`
  returns it for the new payloads and the fee field otherwise, and every reader
  needing an absolute amount uses it (2.9).
- When sponsored, the origin signs `fuel-limit` and the sponsor's field is the
  rate: the origin bounds the work, the sponsor the price.

Every wallet keeps its signing path; only the payload codec is new.

**Validity** (chain ABI 10.1) is consensus. `precheck_transaction`, run by block
processing and the miner, and `validate_transaction_static_epoch` check the
epoch, that the maximum fee fits, that the intrinsic charge is within
`fuel-limit`, and the arguments limit; the nonce check and the fee debit check
that the payer holds the maximum fee. A block with an invalid Wasm transaction
is invalid, at `/v3/block_proposal` too. `can_include_tx` applies the same
checks at admission.

**No legacy deploys** (SIP). From the epoch the same checks make the legacy
deploy payloads (`SmartContract`, versioned or not) invalid: every new contract
is a module. Boot contracts the node installs at an epoch transition
(`initialize_epoch_*` in `clarity_vm/clarity.rs`) do not pass through these
checks and stay legacy. Activation therefore waits on the Clarity compiler (G1).

### 2.9 Readers of the fee field

For a Wasm transaction, each place that reads the fee field as uSTX:

| Reader                           | Where                                                                                                 | Behaviour                                                                                                                                    |
| -------------------------------- | ----------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| Fee debit                        | `TransactionProcessor::process`, `accounts::pay_transaction_fee`                                      | Debit the maximum fee before the payload runs; after it, credit maximum minus charged back to the payer; `process()` returns the charged fee |
| Charged fee                      | the same                                                                                              | ⌈fuel consumed × rate ÷ 10⁶⌉; the maximum after `budget-exceeded`; the intrinsic charge's fee when failed before execution                   |
| Problematic skip                 | `process()` with a `problematic_txs` marker                                                           | Charge the maximum fee, as a skipped legacy transaction pays its full fee                                                                    |
| Block fees, miner reward         | `process_block_transactions`, the tenure's fee total, the miner's and `/v3/block_proposal`'s fee sums | The charged fees                                                                                                                             |
| Minimum relay fee, balance check | `can_include_tx`                                                                                      | The per-byte minimum against the intrinsic charge × rate, the least the transaction pays; the balance against the maximum fee                |
| Replace-by-fee                   | `MemPoolDB`                                                                                           | Compare maximum fees, across payload kinds                                                                                                   |
| Eviction, mempool sync order     | the mempool `tx_fee` column                                                                           | The column holds the maximum fee                                                                                                             |
| Miner ordering                   | the mempool `fee_rate` column                                                                         | uSTX per million fuel for both: a Wasm transaction's rate; a legacy one's 10⁶ × fee ÷ `conv`(estimated cost) (2.13)                          |
| Fee estimators                   | `cost_estimates` (pessimistic, fee scalar, fee medians), `/v2/fees/transaction`                       | Cost from `fuel-limit`, learning from receipts' fuel consumed and fee charged; the endpoint returns rates for the new payloads               |
| Receipts, indexers               | receipt, event observer                                                                               | `fee_charged` and `fuel_consumed` (2.16); the raw transaction's fee field is a rate                                                          |

### 2.10 Deploy

After the name check (2.4), the pipeline is chain ABI 3.5 steps 1 and 2, in the
host (section numbers in it are the ABI's):

1. Size within the module limit (9.3), set below the 2 MiB block limit.
2. Parse and validate with wasmparser, with the features of 2.2.
3. Profile: no `start`; at most one table, within the table limit; exactly one
   memory, maximum within the instance limit, exported as `memory` (3.1, 3.2).
4. Imports: each from `stacks-abi-v1` with the name and type the host-interface
   table gives (3.2).
5. Custom sections: exactly the allowed set with `abi.interface` present (3.4);
   the other two are bounded only by the module size and never decoded.
6. `abi.interface` decodes and validates (4.1), its `abi-version` matches the
   import module (11), and the exports match it (3.3).
7. Stack instrumentation (2.11), then `Module::new`; a wasmi error is a
   rejection with reason `engine`.

A rejection is "failed before execution" (chain ABI 10.1): included, charged its
intrinsic fuel, nothing stored, with a reason in the receipt from an enum in
`stacks-abi` (`module-size`, `invalid-wasm`, `profile`, `imports`,
`custom-sections`, `interface`, `abi-version`, `exports`, `engine`), pinned by
vectors.

An accepted module runs in a public frame (3.5 step 3), and everything is
written inside it: commitment and module (2.4), a zero supply per declared FT,
then instantiation and `init`. A runtime error discards the frame, so nothing is
stored. Without `init` the frame still opens and post-conditions are evaluated.

### 2.11 Stack bound by instrumentation

Chain ABI 9.3 bounds stack height in the ABI's own units, independent of the
engine. A deploy-time pass gives each function a frame cost of 1 plus its locals
plus its maximum operand-stack height, so every frame costs at least one unit,
and injects a global counter that each function raises by its cost on entry and
lowers on every exit. Overflow calls an internal import the host maps to
`stack-exceeded`; it exists only in the node-local instrumented module.

Every function is instrumented: `call_indirect` and recursion make a static
bound unavailable in general, and v1 does not try to exempt functions it could
bound. The counter is per instance, so the bound is per contract frame; 2.6
bounds the nesting of frames.

The pass is ours, on wasmparser and wasm-encoder; `wasm-instrument` has had no
release since 2022 and parses neither bulk memory nor multi-value. It is
consensus: its version is part of the schedule version, vectors pin its output
bytes, and injected instructions are charged like any other.

### 2.12 Fuel and the schedule

Fuel schedule v1 is one versioned structure in `stacks-abi`. It names the wasmi
and stack-pass versions and holds: the operator prices and
`bytes_copied_per_fuel`; per host function, a base charge and charges per input
and output byte; storage prices per read, per write, and per raw byte;
instantiation prices per module byte, initial memory page, and initial table
entry; intrinsic prices per transaction byte, per signature, and per deployed
module byte for validation and compilation (computable before validation, chain
ABI 3.5); and the tenure fuel limit and conversion constants (2.13). The limits
of chain ABI 9.3 are fixed per ABI version instead (section 10).

A host function charges its inputs from their lengths before any work, and its
outputs before writing them. wasmi 2.0 has no public charge call, so the host
reads the fuel and either sets it to the remainder or, on underflow, sets it to
zero and fails. wasmi leaves the fuel unchanged after an out-of-fuel trap, so
the host records the whole limit as consumed (9.1). Instantiation charges are
the host's. The host records which bound set the fuel (2.13):

| Engine outcome                                                                                                                       | Class                               |
| ------------------------------------------------------------------------------------------------------------------------------------ | ----------------------------------- |
| `TrapCode::OutOfFuel`, including inside `memory.grow`, or a host charge exceeding the fuel left, with `fuel-limit` the binding bound | `budget-exceeded`                   |
| The same, with the tenure remainder `R` the binding bound                                                                            | not an outcome: does not fit (2.13) |
| The stack pass's internal import; `TrapCode::StackOverflow`, which CI shows no vector reaches                                        | `stack-exceeded`                    |
| The resource limiter denying growth, or initial memory, past the transaction memory cap                                              | `memory-exceeded`                   |
| An error a host function returns                                                                                                     | the class it carries                |
| Any other trap                                                                                                                       | `trap`                              |
| `OutOfSystemMemory`, a host panic                                                                                                    | not an outcome; 2.16                |

The resource limiter is the host's own: wasmi's `StoreLimits` with
`trap_on_grow_failure` reports fuel exhaustion inside `memory.grow` as
`GrowthOperationLimited`. Growth past the declared maximum returns `-1`.

### 2.13 The tenure fuel budget (SIP)

Nakamoto has no per-block limit. The budget is per tenure in five dimensions:
`StacksEpoch.block_limit` is an `ExecutionCost`; a block starts from its
parent's `total_tenure_cost` (a `nakamoto_block_headers` column) unless it
starts a tenure or carries a full extend; the SIP-034 causes
(`TenureChangeCause::ExtendedRuntime` to `ExtendedWriteLength`) reset one
dimension each; the block's `LimitedCostTracker` enforces it. The miner caps
each block at `tenure_cost_limit_per_block_percentage` and times extends by
`proportion_largest_dimension`; signers accept full and read-count extends; and
`/v3/block_proposal` returns `BlockValidateOk.cost`.

From the epoch the tenure budget is one number, the tenure fuel limit `F`:

- A **Wasm transaction** consumes its fuel, converted legacy callees included.
- A **legacy transaction** consumes, for its cost `c`, plus any Wasm callee's
  fuel, `conv(c) = max over d of ⌈F × a × c_d ÷ (b × L_d)⌉` in `u128` integers.
  `L_d` are the last pre-epoch block limits, frozen; `p` = `a`/`b` ≥ 1 is the
  premium of chain ABI 13 question 1.
- **Guarantee.** If a tenure stays within `F`, its legacy transactions use at
  most `L_d ÷ p` of every dimension. The maximum is the smallest per-transaction
  charge that adds across transactions and still guarantees every dimension (_n_
  copies of one transaction must keep _n_ × `c_d` within `L_d` for every `d`); a
  sum would also guarantee it but charge a transaction up to five times over for
  dimensions it barely uses. It is the shape of the miner's
  `proportion_largest_dimension`.
- **During execution.** With `R` the tenure fuel remaining, each legacy
  transaction's tracker limit is its current total plus ⌊`L_d` × `R` × `b` ÷
  (`F` × `a`)⌋ per dimension (`LimitedCostTracker` gains `set_limit`); `c` is
  the growth, and exceeding the limit is "does not fit", as a cost overflow is
  today. A Wasm transaction runs on min(`fuel-limit`, `R`); running out is
  `budget-exceeded` if `fuel-limit` bound it and "does not fit" if `R` did
  (2.12). A legacy callee in it gets its limit from that remainder, is charged
  the growth of `conv` over the running legacy total, and overflows the same
  way. A Wasm callee in a legacy transaction runs on what is left of `R`.
- **Too big.** A transaction that does not fit is `TransactionTooBigError`
  (dropped from the mempool) when the tenure had used under
  `TX_BLOCK_LIMIT_PROPORTION_HEURISTIC`% of `F` before it.
- **Epoch boundary.** A tenure can span activation: the first block in the
  epoch, unless it starts a tenure or carries a full extend, starts its fuel
  total at `conv` of its parent's `total_tenure_cost`.
- **Extends.** A new tenure or a full extend (cause 1) resets the total. Causes
  2–6 have nothing to reset and are invalid from the epoch
  (`supports_specific_budget_extends` turns false). The miner stops proposing
  read-count extends, signers stop accepting them, and the signer database's
  read-count extend timestamp is retired.
- **Carried.** `nakamoto_block_headers` gains `total_tenure_fuel` beside
  `total_tenure_cost`, which still reports legacy work. `BlockValidateOk` gains
  `fuel`, defaulted for older signers, and the signer's validation-time logic,
  which treats a zero `cost` as an empty block, reads it. The miner's budget,
  per-block share, and extend threshold are in fuel. The event observer's block
  payload carries the tenure fuel.
- **Repricing.** Legacy packing is repriced. When one dimension binds a tenure,
  the usual case, legacy capacity falls by `p`; when transactions saturate
  different dimensions it falls further, at worst to 1 ÷ 5p. A transaction using
  more than 1 ÷ `p` of a dimension fits no tenure, so E3b measures mined mainnet
  transactions and `p` is chosen so they fit. This is acceptable because legacy
  semantics and fees are untouched, the loss is bounded, and pricing legacy
  above Wasm is the intent of chain ABI 13 question 1.

`F`, `L_d`, and `p` are consensus, in the schedule version, and part of the
activation SIP (G1).

### 2.14 The legacy bridge

The chain never decodes `abi.types` and runs no legacy interface mapping: the
canonical encoding is SIP-005, which legacy decodes without a type.

**Wasm calling legacy** (`call` on a legacy target):

1. The host pre-checks, so legacy's rejectable `Unreachable` errors (a read-only
   call to a public function in `inner_execute_contract`, a trait call in
   read-only context) cannot arise: the function exists and is public or
   read-only (`no-such-function`), the read-only rule (`read-only-violation`),
   reentrancy and depth (2.6).
2. Legacy's deserializer reads the argument bytes as SIP-005 values without a
   type; each must re-serialize to its own bytes, none may remain, and the count
   must match, or the call fails with `legacy-error`.
3. The call goes through `ExecutionState::execute_contract` in a nested frame,
   with sender and caller as in 2.6, so legacy's runtime type check (a
   non-rejectable `TypeValueError`) and the PoX handler, which locks STX and
   logs stake and PoX-action entries, run as for any caller.
4. The result, sanitized by legacy as today, is the flag from `ok` or `err` and
   the encoding of the inner value (interpretation 6.2), or for a read-only
   function flag 1 and the whole value.
5. In a Wasm transaction a legacy callee's error is an outcome (R6): cost as in
   2.13, `MemoryBalanceExceeded` to `memory-exceeded`, `MaxStackDepthReached`
   and `MaxContextDepthReached` to `depth-exceeded`, and every other `Runtime`,
   `EarlyReturn`, or `RuntimeCheck` error, rejectable ones included, to
   `legacy-error`. `VmExecutionError::Internal` (`Expect`, database and MARF
   failures) is a node fault, never an outcome: as today, the transaction is
   rejected and a block holding it is invalid. `ExecutionResourceBudgetExceeded`
   is as in 2.16. Legacy-started transactions keep legacy's rules.
6. Legacy `print` is a contract event named `print` with the value's SIP-005
   encoding as data, counted in event bytes. A legacy callee's read-only calls
   drop their events, as legacy's do.

**Legacy calling Wasm, through a trait.** `special_contract_call` checks the
callee's kind before loading a `ContractContext`; a Wasm callee goes to the
foreign-call hook (2.3), which only `contract-call?` reaches:

- Trait conformance is not checked: there is no legacy signature, and the callee
  validates its own arguments (chain ABI 5.4). The function must exist, be
  read-only in a read-only context, and pass reentrancy and depth (2.6), or the
  call fails with a new non-rejectable runtime error.
- From the epoch a Wasm contract principal is a value of any trait type, without
  a conformance check, wherever legacy admits one. The mempool's
  `check_args_by_allowing_trait_cast`, the only admission check (its 2.05 and
  2.1 checkers load the principal's analysis), admits it; the payload and
  contract-to-contract paths bind a principal in
  `DefinedFunction::execute_apply` without a lookup, and `contract-of` tests
  existence (2.4). Cost: a contract relying on admission to reject a
  non-conforming argument gets a runtime error at the call instead, for Wasm
  arguments only.
- `LoadContract` is charged on the module size; the arguments are serialized and
  concatenated (interpretation 6.1); the callee's fuel adds to the transaction's
  (2.13).
- The result is decoded with legacy's typed deserializer: for a public callee,
  against the arm of the trait's return type the flag selects, wrapped in `ok`
  or `err`; for a read-only callee, against the whole return type, and the flag
  must be 1 (interpretation 6.2). It must re-serialize to the same bytes, then
  passes legacy's existing return-type check. A failure, or a runtime error in
  the callee, is a non-rejectable runtime error naming the class.
- Under `at-block` the callee resolves through its commitment at that block.

**No literal path.** Every legacy contract was deployed before the epoch (2.8),
so none names a Wasm contract by literal. For a legacy contract-call payload
naming a Wasm contract, transaction processing checks the kind before
`run_contract_call`, so it fares as a missing contract does today (2.18), and
only a trait-typed value reaches a Wasm callee from legacy.

### 2.15 Formal definition and generated code

Chain ABI 13 question 6 is answered with a Rust table, `host::HOST_FUNCTIONS` in
`stacks-abi`, not WIT: the parameter kinds of 6.1 are not WIT's types, and WIT
implies the component model. A separate text file was considered and dropped: it
needed a parser, a generator, a checked-in generated table, and a staleness
check, and every consumer is Rust or is served by output generated from the
table. The table gives each host function's name, group, parameters in the kinds
of 6.1, result, status codes (from the crate's status-code types), and charge
formula; the expanded Wasm type is computed from the parameter kinds. Deploy
validation and linking read the table, and a `.wat` import block for compilers
and hand-written modules and the runner's coverage list are generated from it.
The rules every entry keeps are tests over the table, for example that every
`bytes`, `principal`, and `buf` parameter has a per-byte charge term. CI checks
the table against the signatures and status codes of 6.2, not only its headings,
because the crate's tests cannot catch a fact that only 6.2 states: a wrong
kind, size, status type, or storage access count.

### 2.16 Receipts, events, and block-level limits

- **Receipt.** `StacksTransactionReceipt` (`result: Value`) cannot describe a
  Wasm transaction. It gains `fee_charged` (for legacy, the fee) and, for Wasm,
  the outcome (chain ABI 10.1), result flag and bytes, class, `abort` code and
  message, deploy rejection reason, and fuel consumed. `execution_cost` holds
  bridged legacy work.
- **Event observer.** Its transaction payload panics on a result that is not a
  `Response` (`stacks-node/src/event_dispatcher/payloads.rs`). For Wasm it takes
  status, `raw_result`, and the new fields from the outcome; `raw_result` is
  `07` or `08` by flag, then the result bytes, which for a Clarity module equals
  legacy's encoding of `(ok v)` or `(err v)`. H1 fixes the payload with the
  devtools team.
- **Event shapes.** Contract events and NFT events with byte identifiers get a
  raw-bytes variant, serialized as hex in the existing `raw_value` field, where
  legacy puts the SIP-005 encoding, so one decoder serves Clarity data from
  both. Mints, burns, and transfers reuse the STX, FT, and NFT shapes; a stake
  is `pox-locking`'s existing `stx_lock_event`. Only the PoX-action event is
  new.
- **Receipt size.** A block whose receipts reach 50 MiB (`MAX_RECEIPT_SIZES`, by
  `receipt.size()`) is invalid. A Wasm receipt counts its event bytes (chain ABI
  8.3) plus its result length; a raw-bytes event in a legacy transaction counts
  its data length.
- **Burns.** `stx_burn` feeds the asset map's burn map, so `stx_burned` and the
  block burn total include it.
- **Miner budgets.** `TransactionResourceBudgets` apply: the wall clock is
  checked at each host call, and fuel bounds the rest, priced against time
  (E3b). Exceeding a budget, a host panic, or `OutOfSystemMemory` is handled as
  legacy's `ExecutionResourceBudgetExceeded`: not included, marked problematic.
- **Signers** decode blocks with `stacks-codec`, so they must run a release that
  knows payloads 9 and 10 before activation. `/v3/block_proposal` runs block
  processing, so validity (2.8) and the tenure budget (2.13) are enforced there.

### 2.17 Read-only queries and RPC

- `/v2/contracts/call-read` and `/v3/contracts/fast-call-read` dispatch on kind.
  For Wasm, the request's hex arguments concatenated (interpretation 6.1), or an
  optional raw field, are the argument bytes; the query runs in a read-only
  frame under a new `read_only_call_fuel_limit` and the existing
  `read_only_max_execution_time`, and returns the `raw_result` form of 2.16 or
  the class.
- `/v3/transactions/simulate` and `/v3/blocks/simulate` and `replay` handle Wasm
  receipts. There is no public-function simulation query (section 10).
- New endpoints serve a module and each of its three sections, for compilers and
  `clarity-verify`.
- Endpoints that assume source or analysis (source, interface, data variable,
  map entry, constant, and `/v2/clarity/metadata/...` for `analysis`) return 404
  naming the kind; `/v2/traits/...` answers not implemented;
  `/v2/clarity/marf/...` serves Wasm keys. A Wasm contract cannot control a
  StackerDB in v1. `docs/rpc/openapi.yaml` follows.

### 2.18 Points the ABI leaves open

Besides the deploy outcome and order (2.10), initial charges (2.12),
`contract_hash` of a legacy contract (2.4), legacy `print` (2.14), and the
receipt (2.16):

| Point                                           | Decision                                                                                                                                                                                                                                           |
| ----------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Deploy to an existing name                      | Invalid, as a duplicate legacy deploy is (`Duplicate contract`); the mempool rejects it with `ContractAlreadyExists` (2.4). A legacy deploy is invalid from the epoch (2.8)                                                                        |
| Legacy contract-call payload to a Wasm contract | What a missing contract gets today: the mempool rejects it (`NoSuchContract`); in a block, included with the runtime `NoSuchContract` error, fee paid (2.14)                                                                                       |
| Wasm call payload to a legacy contract          | Failed before execution, `no-such-function`                                                                                                                                                                                                        |
| `ft_set_cap` outside `init`, or twice           | `bad-host-argument`                                                                                                                                                                                                                                |
| `ft_mint` past the cap, or a supply past `u128` | New class `supply-exceeded`                                                                                                                                                                                                                        |
| Limits and R7                                   | The limits of 9.3 are fixed per ABI version; prices, the tenure fuel limit, and the read-only query limit (node setting) may move                                                                                                                  |
| Read-only query naming a public function        | Runs in a read-only frame; a write is `read-only-violation` (chain ABI 5.1)                                                                                                                                                                        |
| Context values                                  | Those of legacy `stacks-block-height`, `burn-block-height`, `tenure-height`, `stacks-block-time`, `stx-liquid-supply`, and `chain-id`, read through the same `ClarityDatabase` methods                                                             |
| Served heights, reward maturity                 | Exactly what legacy `get-stacks-block-info?`, `get-tenure-info?`, and `get-burn-block-info?` serve at the same height, through the same `HeadersDB` and `BurnStateDB` methods; maturity as `block-reward`'s; heights of 2³² or more are not served |
| `ed25519_verify`                                | Strict verification (`verify_strict`), which also rejects small-order and non-canonical points                                                                                                                                                     |

## 3. Architecture

The crates are those of 2.3. The host reaches the chain only through
`ChainState`, and the chain reaches the host only through transaction processing
and the foreign-call hook.

### 3.1 The `ChainState` trait

Everything the host functions need from the chain; stackslib implements it over
`GlobalContext`, tests in memory.

| Group (chain ABI 6.2) | `ChainState` provides                                                                                   | Backed in stackslib by                                               |
| --------------------- | ------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------- |
| Boundary and control  | nothing; the host owns arguments, results, and abort                                                    |                                                                      |
| Context               | sender, sponsor, heights, time, liquid supply, chain id, network flags                                  | the transaction and the `ClarityDatabase` methods legacy uses (2.18) |
| Block data            | one lookup per field, by height, returning "not served"                                                 | `HeadersDB` and `BurnStateDB` through `ClarityDatabase` (2.18)       |
| Storage               | get, has, set, delete under (contract, key)                                                             | the key scheme of 2.5                                                |
| Assets                | FT and NFT state; STX balance, lock state, transfer, burn; record asset-map entries and asset events    | 2.5; the STX account structure; the shared `AssetMap` (2.7)          |
| Frames                | nest, commit, discard                                                                                   | `GlobalContext` begin, commit, rollback (2.6)                        |
| Calls and principals  | resolve a principal to a module or a legacy contract; the committed hash; call a legacy function        | the commitment (2.4); `ExecutionState::execute_contract` (2.14)      |
| Events                | record a contract event                                                                                 | the `EventBatch` of the current level                                |
| Cryptography          | nothing; the host implements it from `stacks-common`, adding the low-S and 33-byte key checks 6.2 needs |                                                                      |

The host functions and chain ABI 6.1 (marshalling), 7 (frames, reentrancy,
depth, read-only), and 9 (fuel) are host code and behave identically over any
`ChainState`.

### 3.2 Execution context

A host `Transaction` holds the Wasm side of a transaction: the fuel budget, the
frame stack (each frame's `sender`, `caller`, kind, allowances, and instance),
event bytes, the active-contract set, the memory total, the kept result of the
last `call`, and the running legacy cost (2.13). Instances live exactly as long
as their frames (R5); the asset map and events live in `GlobalContext`.

## 4. Transaction flow

**Wasm call** (5.1, 5.2). Validity (2.8) → hold the maximum fee → intrinsic
charge → resolve function from the interface (missing, read-only, or a legacy
target: failed before execution, `no-such-function`) → public frame on the
origin, instantiate, run the export to `result_set` → ok: post-conditions
(failure: discard, `post-condition failure`), commit; err: discard; runtime
error: discard, aborted with its class → charge fuel × rate, release the rest. A
deploy follows 2.10 within the same fee steps.

**Legacy transaction after the epoch.** As today, with its tracker limit and
tenure fuel from 2.13; a trait call may reach a Wasm callee (2.14).

**Read-only query** (2.17). No fee; a read-only frame on the stated sender under
the node's limit; everything discarded.

## 5. Testing

- **ABI vectors** ([04-spec-plan.md](../04-spec-plan.md)) in the common format
  of clarity-wasm issue 913: a module in text format, chain actions with
  context, and the expected outcome (deploy reason, flag and bytes, events,
  asset map, class, fuel). The runner runs them in memory and the node runs the
  same files through the transaction path. Vectors cite rule ids, and the runner
  reports rules, host functions, and classes no vector reaches.
- **Consensus tests** in `stackslib/src/chainstate/tests/consensus.rs` for every
  C and D item, including an invalid Wasm transaction in a block, a tenure at
  the fuel limit, and the extend rules.
- **Fuzzing.** wasm-smith modules with the profile's features, and random
  host-function arguments and memory: a class every time, never a panic or an
  unmineable outcome (R6).
- **Engine pinning.** Reference-module fuel, cold and warm, on every platform
  (E4).
- **Legacy unaffected.** Mainnet replay with `contrib/stacks-inspect`, epoch not
  active, gives the same state roots; it gates the release branch (C9b).
- **Bridge crosscheck.** SIP-010 tokens, PoX, and an sBTC-shaped contract called
  from hand-written modules, compared with the interpreter calling them
  directly; and legacy contracts calling Wasm tokens through traits (D6).
- **Devnet** with signers: every host-function group, fees, and the tenure
  budget end to end (C10).

## 6. Work breakdown

Each item is a week or less of one engineer's work and lands with its vectors
and consensus tests. Sizes are in engineer-weeks. Refs are chain ABI sections; §
marks a section of this document.

### M1 — The definition and the epoch gate

| Id  | Item                                                                                                                                                                 | Refs            | Size | Depends on |
| --- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------- | ---- | ---------- |
| S0  | Test-only epoch: epoch id, predicates, network tables, release epoch unchanged; every later consensus change lands behind it; A4a, A4b, A5 preserve legacy behaviour | 11              | 1    |            |
| A1  | `crates/stacks-abi` skeleton; name and principal codecs; limits; classes and status codes as types; CI for native and `wasm32`                                       | 2, 9.3, 10.2    | 1    |            |
| A2  | `abi.interface` codec, validation, hash; custom-section rules; deploy rejection reasons                                                                              | 3.4, 4.1, §2.10 | 1    | A1         |
| A3a | Rust table of all 66 host functions, with tests for the Wasm types of 6.1 and the rules every entry keeps                                                            | 6.1, 6.2, 13 Q6 | 1    | A1         |
| A3b | `.wat` generator from the table; check of the table against 6.2                                                                                                      | R8              | 1    | A3a        |
| A4a | `AssetMap`: mint entries and byte NFT identifiers; legacy recording unchanged                                                                                        | 8.2, §2.7       | 1    | A1         |
| A4b | Allowance descriptor codec; `check_allowances` moved to `stacks-transactions` and shared                                                                             | 7.2, §2.7       | 1    | A4a        |
| A5  | `check_transaction_postconditions` over byte identifiers; the 8.4 vectors against it                                                                                 | 8.4, §2.7       | 1    | A4a        |
| A6  | Schedule v1 as data with placeholder values (2.12), mapped onto wasmi's operator table and copy ratio                                                                | 9.2, §2.12      | 1    | A3a        |
| A7  | Vector runner implementing issue 913's format; coverage by host function and class                                                                                   | spec plan       | 1    | A3a        |

### M2 — The host runs a module in memory

| Id   | Item                                                                                                                                                          | Refs          | Size | Depends on                                        |
| ---- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------- | ---- | ------------------------------------------------- |
| B1a  | `crates/stacks-wasm-host`; engine trait; wasmi configuration (2.2); pipeline steps 1–4                                                                        | 3.1, 3.2      | 1    | A3a                                               |
| B1b  | Pipeline steps 5–7 and the rejection vectors, including a passive-segment acceptance and a reference-types rejection                                          | 3.3–3.5       | 1    | B1a, A2, A7                                       |
| B2a  | Stack pass: frame-cost analysis                                                                                                                               | 9.3, §2.11    | 1    | B1a, A6                                           |
| B2b  | Stack pass: rewrite, internal import, determinism vectors                                                                                                     | 9.3, §2.11    | 1    | B2a                                               |
| B3a  | `ChainState` trait and in-memory implementation                                                                                                               | 3.1           | 1    | B1a                                               |
| B3b  | Transaction context, frames, fresh instance per call, the resource limiter and memory limits, the 6.1 marshalling rules                                       | 6.1, 7.1, R5  | 1    | B3a, B1b                                          |
| B4   | `args_size`, `args_read`, `result_set`, `abort`; the export protocol; `init`                                                                                  | 5.2, 6.2      | 1    | B3b                                               |
| B5   | Context and block-data functions                                                                                                                              | 6.2           | 1    | B3b                                               |
| B6   | Storage functions with the key and value limits                                                                                                               | 4.2, 6.2      | 1    | B8                                                |
| B7a  | FT and NFT functions, asset-map entries, asset events, status codes, `supply-exceeded`                                                                        | 6.2, 8.2      | 1    | B8                                                |
| B7b  | STX functions                                                                                                                                                 | 6.2, 8.2      | 1    | B8                                                |
| B8   | `frame_open`, `frame_close`, allowance frames, `unbalanced-frame`, the read-only guard every mutating function calls                                          | 7.1, 7.2, 7.4 | 1    | B3b, A4b                                          |
| B9   | `call` and `result_read`: resolution, kept results, reentrancy, depth, `read_only`; the legacy-target path as a `ChainState` method the in-memory state mocks | 5.3, 7.3      | 1    | B4, B8                                            |
| B10  | `emit`, `log`, event size, `events-exceeded`                                                                                                                  | 6.2, 8.3      | 1    | B3b, A6, B7a                                      |
| B11  | Cryptography, with the low-S, key-form, and strict Ed25519 vectors                                                                                            | 6.2           | 1    | B3b                                               |
| B12a | Engine fuel from the schedule, instantiation and initial-memory charges, the host charge helper, `budget-exceeded`, cold and warm vector                      | 9.1, 9.2      | 1    | A6, B3b, B2b                                      |
| B12b | Host charges for every function; the full class mapping of 2.12                                                                                               | 9.2, 10.2     | 1    | B12a, B4, B5, B6, B7a, B7b, B8, B9, B10, B11, B14 |
| B13  | Prepared-module cache (2.2)                                                                                                                                   | 3             | 1    | B12a                                              |
| B14  | `contract_hash` and `principal_to_ascii`                                                                                                                      | 6.2           | 0.5  | B3b                                               |

### Vertical slice

A hand-written module with `init` and one function deploys and is called through
a Nakamoto devnet test behind S0, with a flat placeholder charge, before the
full host exists. Scheduled first, it lands around week 7; its exit opens the
riskiest node surfaces early.

| Id  | Item                                                                                                                                                                                                                                                 | Refs      | Size | Depends on       |
| --- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- | ---------------- |
| C1a | Payloads 9 and 10 in `stacks-codec` with round-trip and fixed vectors; every `TransactionPayload` match given an arm that rejects them                                                                                                               | 12 item 8 | 1    | A1, S0           |
| C2a | Contract identity: commitment with kind and its 72/74-character parser, module store, the existence check of 2.4, the stackslib `ChainState` skeleton; legacy loaders, the contract-call payload, and RPCs fail deterministically on a Wasm contract | §2.4      | 1    | B3a, S0          |
| C4a | Deploy and call dispatch in transaction processing; minimal receipt                                                                                                                                                                                  | 3.5, 5.1  | 1    | C1a, C2a, B4, S0 |
| D0  | Bridge spike: a host frame nested in `GlobalContext`, calling `execute_contract` and back                                                                                                                                                            | §2.6      | 0.5  | B3b              |

### M3 — The node runs it

| Id  | Item                                                                                                                                                                                                              | Refs            | Size | Depends on                             |
| --- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------- | ---- | -------------------------------------- |
| C1b | Validity in `precheck_transaction`, `validate_transaction_static_epoch`, and admission, legacy deploys invalid included; invalid-block vector                                                                     | 9.1, 10.1, §2.8 | 1    | C1a, A6, S0                            |
| C1c | Transaction-format and fee SIP draft (2.8, 2.9)                                                                                                                                                                   | 9.1, 12 item 8  | 1    | C1a                                    |
| C1d | Per-site handling of the new payloads across mempool, miner, RPC, `stacks-inspect` (`deserialize-db` included), and the CLI; anchor mode and name rules                                                           | §2.8            | 1    | C1a                                    |
| C2d | Tagged-leaf commitment hook in `RollbackWrapper` and every backing store                                                                                                                                          | 8.1, §2.5       | 1    | S0                                     |
| C2b | `ChainState` storage, FT, and NFT on the key scheme                                                                                                                                                               | 4.2, 8.1        | 1    | C2a, C2d, B6, B7a                      |
| C2c | `ChainState` STX through the account structure; burns into `stx_burned`                                                                                                                                           | 6.2             | 1    | C2a, B7b                               |
| C3a | `ChainState` context and Stacks block data through `ClarityDatabase` (2.18)                                                                                                                                       | 6.2             | 1    | B5, C2a, S0                            |
| C3b | `ChainState` tenure and burn block data, reward maturity (2.18)                                                                                                                                                   | 6.2             | 1    | B5, C2a, S0                            |
| C4b | Deploy path: intrinsic charges, rejection outcomes and reasons, the store inside the `init` frame                                                                                                                 | 3.5, 10.1       | 1    | C4a, B12b, C1b, C2b, C2c               |
| C4e | Call path: every 10.1 outcome, post-conditions on the transaction path, classes on the node path                                                                                                                  | 5.1, 8.4, 10    | 1    | C4b, A5, C3a, C3b                      |
| H1  | Receipt and event observer payload agreed with the devtools team                                                                                                                                                  | §2.16           | 1    |                                        |
| C4c | Receipt fields, event dispatcher payload, receipt-size rule                                                                                                                                                       | §2.16           | 1    | C4a, H1                                |
| C4f | Event shapes; simulate and replay endpoints                                                                                                                                                                       | 8.3, §2.16      | 1    | C4c, B10                               |
| C4d | Miner resource budgets and problematic handling for Wasm                                                                                                                                                          | R6, §2.16       | 1    | C4e                                    |
| C6a | Fee hold, charge, and release; `process()` returns the charged fee; block fee totals; problematic charge                                                                                                          | 9.1, §2.9       | 1    | C4e, C1d                               |
| C6b | Mempool: minimum fee, balance, replace-by-fee, eviction and sync order, `fee_rate`, mixed ordering                                                                                                                | 9.1, §2.9       | 1    | C6a, C7a                               |
| C6c | Tenure fuel budget in block processing: epoch limit, header column, enforcement, extend rules, the epoch-boundary start                                                                                           | 9.1, §2.13      | 1    | C6a, C7a                               |
| C6f | Tenure fuel budget in the miner and `/v3/block_proposal`: budget, per-block share, extend decisions, no read-count extends, too-big in fuel, `BlockValidateOk`; tenure fuel in the event observer's block payload | §2.13           | 1    | C6c                                    |
| C6d | Fee estimators and `/v2/fees/transaction`                                                                                                                                                                         | §2.9            | 1    | C6b                                    |
| C6e | Signer: extend acceptance and validation time after the epoch; read-count extend timestamp retired; release before activation                                                                                     | §2.13, §2.16    | 1    | C6c                                    |
| C7a | Legacy-to-fuel conversion as an integer function of schedule constants                                                                                                                                            | 13 Q1, §2.13    | 1    | A6                                     |
| C7b | Legacy transactions under the tenure budget: `set_limit`, per-transaction fuel, "does not fit", too-big in fuel                                                                                                   | 13 Q1, §2.13    | 1    | C6c                                    |
| C8a | Read-only and simulate for Wasm on the existing endpoints; fuel-limit setting                                                                                                                                     | 5.1, §2.17      | 1    | C4e                                    |
| C8b | Module and section endpoints; legacy endpoints on Wasm contracts; StackerDB; OpenAPI                                                                                                                              | §2.17           | 1    | C2a                                    |
| C9b | Schedule-version selection by epoch; version-keyed validation profile and import table; the mainnet-replay gate of section 5                                                                                      | 9.2, 11         | 1    | C4b, S0                                |
| C10 | Devnet with signers: every host-function group, fees, and the tenure budget end to end; the vector files through the node; a CI job runs the README                                                               | all             | 1    | C4e, C4f, C6b, C6e, C6f, C7b, C8a, C9b |

### M4 — The legacy bridge

| Id  | Item                                                                                                                                                                | Refs          | Size | Depends on         |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------- | ---- | ------------------ |
| D3a | One transaction context: Wasm frames on `GlobalContext`; the cross-runtime reentrancy and depth rules                                                               | 7.1–7.3, §2.6 | 1    | C4e, D0            |
| D3b | Cross-runtime effects: legacy allowances and post-conditions over Wasm movements and the reverse; deny-mode vectors                                                 | 7.2, 8.4      | 1    | D3a, D4a, D5b      |
| D4a | Wasm calling legacy: pre-checks, argument checks, sender and caller, `execute_contract` behind B9's `ChainState` method, result encoding                            | 5.3, §2.14    | 1    | D3a, C2a           |
| D4b | Wasm calling legacy: error mapping, cost conversion, legacy `print`; PoX locking vector                                                                             | 8.3, §2.14    | 1    | D4a, C7a, C7b      |
| D5a | `clarity` dispatch hook; kind check in `special_contract_call`                                                                                                      | §2.3, §2.14   | 1    | C2a                |
| D5b | Legacy calling Wasm through a trait: argument encoding, the call in the shared context, result decoding against the trait                                           | §2.14         | 1    | D5a, D3a           |
| D5c | Legacy calling Wasm: errors, `LoadContract` and fuel charges, `at-block`, `contract-hash?` across runtimes                                                          | §2.13, §2.14  | 1    | D5b, C7a, C7b      |
| D5d | Trait values: a Wasm principal admitted as any trait type at mempool admission and by `contract-of`; a Wasm token passed to a legacy DEX through `/v2/transactions` | 5.4, §2.14    | 1    | D5b                |
| D6  | Bridge crosscheck (section 5); the depth-64 native-stack vector and the execution thread's stack size                                                               | 7.3, §2.6     | 1    | D4b, D5c, D3b, D5d |

### M5 — Hardening and the ABI v1 release candidate

| Id  | Item                                                                                                                                  | Refs       | Size | Depends on                                                            |
| --- | ------------------------------------------------------------------------------------------------------------------------------------- | ---------- | ---- | --------------------------------------------------------------------- |
| E1  | Fuzzing harnesses (section 5), run 24 CPU-hours per target with no crash                                                              | R6         | 1    | B12b                                                                  |
| E2a | Benchmarks: operator prices and the stack counter on reference hardware                                                               | 9.2, 13 Q3 | 1    | B12a, B2b                                                             |
| E2b | Benchmarks: host-function charges at the limits; the cost of canonical decoding in Wasm (13 Q7)                                       | 9.2, 13 Q3 | 1    | B12b                                                                  |
| E3a | Benchmarks: storage and instantiation prices on a node                                                                                | 9.2, 13 Q3 | 1    | C4e                                                                   |
| E3b | Benchmarks: the tenure fuel limit; the conversion constants and premium against mainnet's largest legacy transactions                 | 9.3, 13 Q1 | 1    | C6f, C7b                                                              |
| E4  | Engine pinning CI on every platform; configuration assertions; the upgrade policy written down                                        | 9.2        | 1    | B12a, B2b                                                             |
| E5a | A Rust module against the generated import block, exercising every host function in memory                                            | 05 risk 1  | 1    | B12b, A3b                                                             |
| E5b | The Rust module on devnet; review of the ABI for Clarity-shaped assumptions, findings filed against 07                                | 05 risk 1  | 1    | E5a, C10                                                              |
| E7  | Rule ids in 07; vectors cite them; coverage by rule                                                                                   | spec plan  | 1    | A7                                                                    |
| E6  | Release candidate: apply section 10's amendments, close or defer each open question, tag the definition, schedule values, and vectors | 11, 12, 13 | 1    | E1, E2a, E2b, E3a, E3b, E4, E5b, E7, D6, C6d, C8b, B13, C4d, C10, C1c |

Outside the engineer-week count:

- **G1.** The activation SIP: the runtime, the epoch, the end of legacy deploys,
  the state scheme, the tenure fuel budget and conversion, drafted from E6. It
  gates the hard fork (stacks-core 7767), and since no Clarity contract can be
  deployed after it except as a module, activation waits on the Clarity compiler
  as the final freeze does.
- **G2.** Security review of the host, the stack pass, and the bridge: scoped at
  C10, completed before the freeze.
- **Final freeze** is the existing tracker issue (stacks-core 7766, ABI 1.0
  freeze). It depends on E6 and on the Clarity compiler shipping against the
  ABI, its back end passing the ABI vectors on devnet (clarity-wasm 889), as
  05-roadmap.md risk 1 requires.

### Schedule

The breakdown is 78 items and 77 engineer-weeks. The critical path is 17 weeks:
A1 → A3a → B1a → B3a → B3b → B8 → B7a → B10 → B12b → C4b → C4e → C6a → C6c → C6e
or C6f → C10 → E5b → E6. A list-scheduling model over these items and edges,
with the slice prioritised, gives:

| Engineers | Slice (C4a) | M3 (C10) | M4 (D6) | M5 (E6) |
| --------- | ----------- | -------- | ------- | ------- |
| 2         | week 7      | week 29  | week 35 | week 40 |
| 3         | week 7      | week 19  | week 23 | week 27 |
| 4         | week 7      | week 15  | week 18 | week 21 |

These are model outputs that assume each item takes its stated size. They
exclude the external gates: issue 913's format, H1's agreement, the SIP reviews,
G2, and the compiler for the final freeze. Until C4e, every engineer works on
the host and the slice; the node and bridge tracks separate after it.

## 7. Risks

| Risk                                                                                  | Mitigation                                                                                                               |
| ------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| Engine fuel accounting changes under an upgrade                                       | Exact pin, reference-module fuel vectors on every platform, schedule names the engine version (2.2, E4)                  |
| wasmi's price table is `u8` per operator, and one copy ratio covers memory and tables | E2a fits the schedule to that shape; if it cannot price an operator, section 9's injected metering is the fallback       |
| The premium makes the largest legacy transactions unmineable                          | E3b measures mainnet shares and bounds `p` (2.13)                                                                        |
| Signers on an old release reject every block with a Wasm transaction                  | C6e ships in a release before activation; activation waits on signer adoption                                            |
| The fee-field sweep misses a reader                                                   | C1a and C1d sweep every `TransactionPayload` match; `max_fee()` is the single accessor; C10 runs the fee path end to end |
| The bridge touches legacy paths that are not yet opened                               | D0 opens them during the slice; D6 crosschecks both directions against the interpreter                                   |
| The stack pass is consensus                                                           | Deterministic, pinned by vectors (B2b); part of the schedule version                                                     |
| Limits and prices are placeholders until M5                                           | Schedule data (2.12); charge vectors name the schedule version and are regenerated when values change                    |
| The transaction-format SIP stalls                                                     | C1a lands behind S0; the SIP can change the codec without touching the runtime                                           |
| An NFT identifier that is not a SIP-005 encoding cannot be named in a post-condition  | Recorded as an amendment (section 10); the Clarity compiler emits canonical identifiers                                  |

## 8. What other teams consume

- **Compiler track.** The import block and Rust table (A3a, A3b), the
  `abi.interface` codec (A2), the vector runner (A7), and rule ids (E7). It
  owns, as tooling the node never runs, the `abi.types` codec, typed canonical
  decoding, and the legacy interface mapping (deterministic and versioned, since
  provenance records its output), built from `/v2/contracts/interface`.
- **DevTools (Stacks.js, Clarinet, explorers, indexers).** The payload codec and
  fee semantics (C1a, C1c), the receipt and event payload (H1, C4c), the RPC
  endpoints (C8a, C8b), and `stacks-abi` built for the browser.
- **Signer operators.** The signer release of C6e, before activation.
- **Chain governance.** The SIPs (C1c, G1), the epoch, and the schedule's first
  values (E2a, E2b, E3a, E3b).

## 9. Later

Larger changes deliberately not in v1:

| Change                                                 | Why not in v1                                                                | Trigger                                                                                              | Hook v1 leaves                                                                                                                |
| ------------------------------------------------------ | ---------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| Compiling engine with engine-independent metering      | Weeks of work and an interpreter slowdown from injected fuel, for no v1 need | wasmi throughput limits the tenure fuel limit, or the cost analyzer needs exact fuel from the module | Stack bound in ABI units; prices per Wasm operator; a consensus deploy pass that can inject fuel; schedule versions at epochs |
| Binary side store                                      | Hex text works and matches legacy                                            | Side-store size or hashing shows in profiles                                                         | Leaves commit to tag and raw bytes (2.5)                                                                                      |
| State rent or size accounting                          | No measured need; a major economic design                                    | Measured state growth from Wasm contracts                                                            | Versioned tags, so rent can apply to values written after its activation, with no migration                                   |
| Capped and recoverable calls (13 Q5)                   | Needs its own analysis against R6                                            | The cost analyzer or multi-language callers need them                                                | Fuel tracked per frame; a new `call` variant in a new ABI version                                                             |
| Rate-native fee fields, or a new authorization version | Every wallet would need a new signing path                                   | A fee-market redesign (base fee or burn)                                                             | Payload version byte; `max_fee()` as the single accessor                                                                      |
| Partial tenure extends in fuel                         | One budget needs only the full extend                                        | Tenures run out of fuel before their time                                                            | Cause values 2–6 retired; a new cause value is free                                                                           |
| Legacy contract-call payloads to Wasm contracts        | Two argument forms for one call                                              | Wallets lag in adopting payload 10                                                                   | The outcome today is a defined failure that an epoch can relax                                                                |
| StackerDB controlled by a Wasm contract                | Its config is read through legacy analysis                                   | Demand from a Wasm application                                                                       | The read-only query path (2.17)                                                                                               |

Not planned:

- **PoX and boot contracts in Wasm.** `pox-locking` is wired to `GlobalContext`
  and legacy values, a Wasm PoX would need a privileged host function outside
  the ABI, and Wasm contracts already reach PoX through the bridge.
- **Recompiling legacy contracts.** The interpreter must stay to replay history,
  and reproducing legacy errors, epoch rules, and costs exactly is what the
  clarity-wasm crosscheck kept failing at. Kind `02` stays reserved.

## 10. Proposed ABI amendments

Changes to 07 and 08 this design relies on. E6 applies them.

| Section                           | Current text                                                                                | Proposed                                                                                                                                                                                                                                                                                                              | Why                                                        |
| --------------------------------- | ------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------- |
| 07 2, 3.4, 13 Q4; 08 1, 5.3, 9 Q1 | The bridge reads and validates `abi.types`                                                  | The chain never reads `abi.types` or runs a legacy interface mapping; Wasm calls any legacy contract and legacy calls Wasm only through a trait (2.14). 08 question 1: no                                                                                                                                             | Decision on bridge scope                                   |
| 08 3                              | "There is no sanitizing and no untyped decoding"                                            | Except the bridge's argument decoding into a legacy callee: untyped SIP-005, each value re-encoding to its bytes, then legacy's runtime type check (which admits form feed)                                                                                                                                           | Legacy decodes self-describing values                      |
| 07 3.4                            | `abi.types`, `abi.provenance` validated "only for size"                                     | Bounded only by the module size limit                                                                                                                                                                                                                                                                                 | No separate limits exist                                   |
| 07 3.5, 10.1                      | "A failed deploy … pays its charges"; outcome row cites 5.1 only                            | A deploy rejected in steps 1–2 is "failed before execution", with a reason code in the receipt                                                                                                                                                                                                                        | Rejection had no outcome row                               |
| 07 5.1                            | "Simulating a public function is a separate query that runs a public frame and discards it" | No such query in v1: a read-only query naming a public function runs it in a read-only frame; `/v3/transactions/simulate` (operator-authorized) runs a whole transaction                                                                                                                                              | No existing endpoint fits                                  |
| 07 5.4                            | "The chain does not validate the values that cross a call boundary"                         | Except at the legacy bridge: a legacy callee's arguments are decoded, re-encoded, and type-checked by legacy, and a Wasm callee's result is decoded against the trait's return type (2.14)                                                                                                                            | Legacy checks its own values                               |
| 07 6.2 `ft_set_cap`, `ft_mint`    | "Otherwise a runtime error"; "Exceeding the supply cap is a runtime error"                  | `ft_set_cap` misuse is `bad-host-argument`; a cap or `u128` supply overflow is a new class `supply-exceeded`                                                                                                                                                                                                          | Classes were unnamed                                       |
| 07 6.2 `contract_hash`            | The hash of "the contract's module"                                                         | For a legacy contract, the committed hash of its source                                                                                                                                                                                                                                                               | Legacy contracts have no module                            |
| 07 6.2 `ed25519_verify`           | RFC 8032                                                                                    | Strict verification, rejecting small-order and non-canonical points                                                                                                                                                                                                                                                   | What `stacks-common` implements                            |
| 07 7.3                            | Contract unit; depth 64                                                                     | Legacy-to-legacy keeps the (contract, function) rule; depth counts frames of both runtimes                                                                                                                                                                                                                            | Deployed legacy behaviour                                  |
| 07 7.1, 8.3                       | "Events of a read-only frame are kept"; events named from the interface                     | A legacy `print` inside a Wasm transaction is a contract event named `print`; a legacy callee's read-only calls drop their events as legacy does                                                                                                                                                                      | Legacy callees still print                                 |
| 07 8.2, 8.3                       | "Every asset operation records an entry: kind (transfer, mint, burn)"                       | Not inside a legacy callee: in a Wasm transaction it records what legacy records, with no mint entries and token burns merged into transfers; its asset events are legacy's (2.7)                                                                                                                                     | Legacy recording unchanged                                 |
| 07 8.4; 08 7.3                    | A post-condition names an identifier "by the same bytes"                                    | Only an identifier that is a valid SIP-005 encoding can be named, since the wire carries a value                                                                                                                                                                                                                      | Wire format unchanged                                      |
| 07 9.1, 9.3, 10.1                 | "A block has one fuel limit"; "Fuel per block"; "does not fit the block"                    | One fuel limit per tenure, reset by a full tenure extend; legacy transactions consume fuel by the conversion of 2.13                                                                                                                                                                                                  | Nakamoto budgets per tenure                                |
| 07 9.1, 10.1                      | Maximum fee `fuel-limit × fuel-rate / 10^6`; the invalid list                               | The maximum fee is rounded up; one over `u64`, and a deploy to an existing name, are invalid (2.4, 2.8)                                                                                                                                                                                                               | Fee field is `u64`; names checked where legacy checks them |
| 07 9.2 execution                  | Each operator consumes its fuel                                                             | Charged when its region is entered, as the pinned engine defines; bulk and growth by one byte ratio                                                                                                                                                                                                                   | How wasmi meters                                           |
| 07 9.2 instantiation              | Per callee module byte                                                                      | Also per initial memory page and per initial table entry                                                                                                                                                                                                                                                              | Initial memory was free                                    |
| 07 9.3, R7                        | Wasm stack "in schedule-defined units"                                                      | All 9.3 limits are fixed per ABI version; the stack limit is per contract frame; only prices, the tenure fuel limit, and the node's query limit move                                                                                                                                                                  | R7: semantics never move                                   |
| 07 10.2                           | 13 classes                                                                                  | Add `supply-exceeded` and `legacy-error` (a legacy callee's argument or runtime error in a Wasm transaction)                                                                                                                                                                                                          | Outcomes with no class                                     |
| 07 13                             | Seven open questions                                                                        | Q1 answered (2.13), the premium's value at E6, blocking activation; Q2 left open, additive in a new ABI version; Q3 deferred to M5; Q4 answered (2.14, first row); Q5 left open, additive (section 9); Q6 answered by the Rust table in `stacks-abi` (2.15); Q7 left open, additive as new functions, measured by E2b | Close or place each                                        |
| 08 9                              | Two open questions                                                                          | Q1 answered no (first row); Q2 left open, additive as a new `emit` variant in a new ABI version                                                                                                                                                                                                                       | Close or place each                                        |

[03-architecture.md](../03-architecture.md) section 7, which has the chain own
the legacy mapping, needs the matching change.
