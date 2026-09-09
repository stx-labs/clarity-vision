# Consensus Gate Classification

Every existing epoch or Clarity-version gate must be assigned to exactly one
owner before the gate-free Clarity 7 engine is activated. The owner determines
how historical replay and future behavior changes are represented.

## The three independent identities

1. **Contract language version** is stored with the contract. It defines the
   syntax, type system, native-function surface, and initial semantic profile.
2. **Engine revision** is selected by the current execution epoch for that
   contract language version. It permits an epoch to change already-deployed
   contracts without putting an epoch branch inside a clean engine.
3. **Kernel ruleset** is selected by the host for the current execution epoch.
   It covers the singly linked value/storage/transaction machinery shared by
   all engines.

The host therefore performs two related selections:

```text
current epoch -> kernel ruleset
(current epoch, contract language version) -> engine revision
```

Neither selection uses the contract's deployment epoch. Historical replay
obtains historical behavior because it executes each block under that block's
epoch manifest.

The epoch-to-language-availability table is host policy as well. The shared
`ClarityVersion` type names a language and has no epoch dependency; stackslib's
manifest decides whether that language can be deployed or selected in the
current protocol epoch. Only the frozen legacy engine keeps a private copy of
the historical default table for compatibility APIs that predate the
manifest.

An epoch value stored in a historical record is not necessarily a semantic
gate. During extraction, `StoredContractAnalysis.epoch` and
`ContractInterface.epoch` remain byte-compatible metadata even after the clean
engine stops consulting them. Engines should distinguish such an input as a
`recorded_epoch`; deleting a branch does not authorize changing the persisted
format. The eventual kernel format can replace this field only through an
explicitly versioned storage migration, not as incidental epoch inversion.

## Gate ownership

| Gate changes | Owner | Representation |
|---|---|---|
| Parser, analyzer, type system, native availability, evaluator semantics, engine metering sites | Language engine | New language version when behavior applies only to new contracts; otherwise a new major engine revision selected by the epoch manifest |
| Value encoding/decoding, canonicalization shared across engines, database and rollback behavior, call framing, shared cost-budget enforcement, asset/event merging | Kernel | Kernel ruleset selected by stackslib; the additive kernel remains singly linked |
| Transaction validity, post-condition policy, epoch activation, chain data supplied to contracts, receipt/block processing | stackslib host | Ordinary epoch-gated host policy; never visible as an engine language gate |
| Historical behavior inside Clarity 1–6 | Frozen legacy engine | Transitional exception: the legacy engine retains its accumulated epoch/version gates; its current major is selected by the manifest |

Cost schedules follow the engine-revision rule for clean engines. Clarity 6
contains only Costs 5 and has no cost-voting or epoch-selected fallback meter.
The host still owns the cumulative block tracker and lends it across engine
boundaries, so mixed-engine calls share one total and limit. The frozen legacy
tracker alone retains historical cost-contract and voting selection for
replay.

Clarity 6 parser and analyzer semantics follow the same rule. Their one
baseline is pinned to Epoch 4.0; parser APIs and analysis passes do not accept
the current epoch as a semantic selector. The current epoch is retained only
where the stored analysis format records it and where transitional shared
runtime framing still requires it.

The runtime frame distinguishes those roles explicitly. Clarity 6 evaluates
against a compile-time semantic baseline, while the actual `host_epoch` is
forwarded only when a nested call re-enters the manifest-selected dispatcher.
There is no semantic epoch field in the Clarity 6 runtime frame. This is
necessary because a clean-engine caller may invoke a frozen legacy contract,
whose engine still needs the block epoch. The caller's semantics, the shared
kernel ruleset, and the callee-selection epoch therefore remain independent.

Clarity 6 evaluator code reaches the remaining legacy-shaped shared APIs only
through revision-owned, epoch-free adapters. The compile-time baseline is
contained at that boundary for type/value operations, database access, asset
accounting, and transaction-frame merges. In particular, an explicit database
operation profile controls both admission and serialization; the stored
database epoch cannot silently override the engine revision's type semantics.

If a gate spans owners, split it at the interface instead of assigning the
whole feature to whichever file currently contains the branch. For example,
the host decides post-condition policy, while kernel transaction framing
provides the asset map and rollback operation used to enforce that decision.

## Representative existing gates

### `at-block`: language surface plus kernel execution policy

`at-block` is present in the Clarity 1–4 language surface, but epoch 3.4 made
it unavailable to both new analysis and runtime calls. A pre-3.4 contract may
therefore contain it, yet a call to that contract at epoch 3.4 or later must
fail with the post-3.4 behavior.

The language-version surface still decides whether an engine recognizes the
construct at all. The historical epoch-wide shutdown is now represented by
the host-selected kernel ruleset, which the frozen legacy analyzer and runtime
consult. This split lets old contracts retain their source language while all
engines in a transaction share one execution policy. A future gate-free engine
that does not implement `at-block` contains no check; a future change to an
engine-local construct would still use a new engine revision rather than grow
the kernel ruleset.

### Epoch 4.1 exact typed-tuple fields: kernel behavior

`from-consensus-buff?` began rejecting duplicate or missing typed-tuple fields
at epoch 4.1. The implementation is in shared value deserialization, so this
is a kernel ruleset change, even though contracts observe it. Copying this
branch into every engine would create inconsistent value semantics and defeat
the singly linked kernel ABI.

### `map` off-by-one and trait-check cost errors: engine behavior

The epoch 4.0 `map` correction changes evaluator behavior, and surfacing
trait-compliance cost errors changes analyzer behavior. These belong to an
engine semantic revision. They remain internal gates only in the frozen
legacy engine.

### Staking post-conditions: host plus kernel framing

Whether a transaction may use a staking post-condition is stackslib policy.
Recording and merging staking asset changes is shared transaction machinery,
so its representation and rollback semantics belong to the kernel ruleset.

## Revision policy

- Prefer a new Clarity language version for intentional language changes.
- Use a new engine major only when an epoch must change existing contracts of
  that language version.
- Use a kernel ruleset only for behavior that must be identical across all
  engines sharing kernel types and state.
- Reuse engine revisions and kernel rulesets across epochs with no relevant
  semantic change.
- Patch/minor engine releases must be consensus-neutral. A consensus change is
  always a linkable major so historical and current revisions can coexist.

This means there is no automatic epoch-by-version crate matrix. The number of
artifacts grows with distinct semantic profiles, which is the irreducible
amount of historical behavior the node must retain.

## Clarity 7 baseline

`Clarity7V1` copies one point in the semantic matrix: Clarity 6 behavior under
the activation epoch's manifest and kernel ruleset. It does not attempt to
reproduce every historical Clarity 6 epoch. Its source contains no runtime
epoch or language-version gates.

Before activation:

1. Inventory and classify every production Clarity gate using the table
   above.
2. Make cumulative costs, call depth/caller state, asset maps, events, and
   rollback framing explicit kernel transaction state.
3. Route nested `contract-call?` through the manifest-selected dispatcher.
4. Differential-test `Clarity7V1` against the selected Clarity 6 baseline,
   then test legacy-to-7 and 7-to-legacy calls in one transaction.
