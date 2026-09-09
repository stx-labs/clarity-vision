# Why Clarity

There are recurring proposals to abandon Clarity and adopt an existing
language and VM (EVM/Solidity, CosmWasm, Move, SVM). This document makes the
case for the opposite: Clarity has properties that **cannot be retrofitted
onto any Turing-complete VM at any price**, and the rational move is to invest
in exploiting those properties rather than discarding them. It also states,
honestly, what Clarity lacks today and how each gap maps to a plan item.

## 1. What makes Clarity unique

### 1.1 Decidability

Clarity is deliberately **not Turing-complete**:

- There is no recursion (direct or mutual) and no unbounded loop construct.
  Iteration exists only as `map`/`fold`/`filter` over sequences whose maximum
  length is fixed by their type.
- Every type has a statically known maximum size — lists, buffers, and strings
  all carry length bounds; there are no unbounded data structures.
- Inter-contract calls cannot re-enter a contract already on the call stack,
  and call depth is bounded.

Consequence: **every Clarity program provably terminates**, and every
execution path is statically enumerable in principle. The halting problem —
the wall that makes complete static analysis *mathematically impossible* for
EVM bytecode, Wasm, Move, and every general-purpose VM — simply does not apply.

This is not an implementation detail. It is a language-level guarantee that no
amount of tooling investment can add to a Turing-complete platform.

### 1.2 What decidability enables (the unclaimed prize)

These are the capabilities that justify the language, and that this effort
commits to actually building:

- **Exact static cost bounds.** Because all loops and data are bounded by
  types, the worst-case execution cost of any public function is a computable
  function of its input types — derivable at *deploy time*, without
  simulation. A wallet can display a true maximum fee; a miner can pack blocks
  against guaranteed bounds; there is no "estimate gas by simulating and hope
  state doesn't change" pattern and no out-of-gas surprise semantics.
- **Complete static analysis.** Whole-program analyses (taint tracking, asset
  flow, authorization checks) terminate and can be made precise, not
  heuristic. An analyzer can enumerate every path by which a contract's assets
  can move.
- **Tractable safety proofs.** All functions are total, state access is
  explicit, and there is no reentrancy, so verification conditions stay inside
  decidable or well-behaved SMT fragments. Proving invariants — supply
  conservation, access control, "no execution path locks funds permanently" —
  is a realistic engineering task rather than a research program. This opens
  the door to *machine-checked contracts* as a standard deployment artifact.

### 1.3 Source is law

Clarity contracts are published **as source code** and that source is what the
chain executes. There is no compiler between the author and the chain, so
there is no compiler in the trust path (no Solidity-compiler-bug class of
vulnerabilities, no verifying that published source matches deployed
bytecode). Every analysis and proof applies directly to the deployed artifact.
Compilation (clar2wasm) is a performance optimization that must be
conformance-verified against the interpreted semantics — never a semantic
authority.

### 1.4 Safety by construction

- **No reentrancy**, the single largest exploit class in EVM history, is ruled
  out by the runtime, not by developer discipline.
- **No undefined behavior**: arithmetic overflow aborts deterministically;
  there are no null references; responses (`(response ok err)`) must be
  handled — ignoring an error is a type error.
- **Post-conditions** (a Stacks transaction-level feature co-designed with the
  language) let the *sender* bound what a transaction may do to their assets,
  regardless of what the called contract's code does.

### 1.5 Bitcoin-native

Clarity contracts read Bitcoin chain state directly (burn block info, PoX
state). No other contract language has the settlement chain's state as a
first-class primitive. Any imported VM would need this bolted on.

## 2. What Clarity lacks today (honest ledger)

| Deficit | Reality | Plan item |
|---|---|---|
| No specification | Behavior is defined by one implementation plus ~589 epoch-gated branches; SIP-002 is informal and outdated | Spec for the next version ([04-spec-plan.md](04-spec-plan.md)) |
| Properties unexploited | No production static cost analyzer, no prover, cost estimation is dynamic | Flagship toolchain deliverables ([05-roadmap.md](05-roadmap.md)) |
| Tangled into stacks-core | The crate depends on `stacks-common`, epoch IDs, and chainstate-shaped DB traits; hard for others to embed | Kernel/engine extraction ([03-architecture.md](03-architecture.md)) |
| Language inconsistencies | Six accreted versions with naming and semantic quirks; backwards-compatibility pressure blocks cleanup | Frozen-engine model removes the compatibility constraint |
| Performance | Interpreter is slow relative to compiled VMs | clar2wasm, held to conformance-suite equivalence |
| Developer experience | Tooling, docs, error messages behind mainstream ecosystems | Downstream of spec + independent crates (stable foundation for tools) |

Every deficit above is an **engineering-effort problem**. None is a
fundamental limitation. The reverse is not true for the alternatives: their
deficits relative to Clarity are fundamental.

## 3. Why not switch to an existing VM

### 3.1 The alternatives give up the differentiator permanently

| Platform | What you gain | What you permanently lose |
|---|---|---|
| EVM / Solidity | Largest ecosystem, developer familiarity | Decidability; reentrancy safety; source-is-law (bytecode + compiler trust); exact cost bounds. Stacks becomes an undifferentiated EVM chain competing on nothing but marginal fees |
| CosmWasm / Wasm + Rust | Mature toolchain, general-purpose language | Decidability; bounded costs (gas metering is dynamic); analyses become heuristic; huge attack surface of a general-purpose runtime |
| Move | Linear resource types (genuinely good) | Still Turing-complete: termination, exact costs, and complete analysis remain impossible; bytecode + compiler trust path |
| SVM / eBPF | Raw performance | Everything above, plus the weakest safety story of the set |

The ecosystem-size argument is real but conflates two different things:
**tooling maturity** (buyable with effort, which is exactly what this plan
funds) and **semantic guarantees** (not buyable at any price once you adopt a
Turing-complete VM).

### 3.2 The migration cost is existential, not incremental

Switching VMs is not "adopt a new SDK":

- **Consensus itself runs on Clarity.** PoX (`pox-4`/`pox-5`), signer
  coordination, and the boot contracts are Clarity contracts. A VM migration
  rewrites the consensus-critical heart of the chain.
- Every deployed contract (sBTC, DeFi protocols, BNS) must be rewritten,
  re-audited, and migrated with live state — the riskiest operation a chain
  can perform.
- Every wallet, API, indexer, and explorer integration breaks.
- The old VM must still be maintained *forever anyway* for historical replay.

The realistic cost of a migration is multiple years of ecosystem-wide effort
and risk — strictly more than the cost of making Clarity excellent — and at
the end of it, Stacks has a commodity VM and no language-level story.

### 3.3 The positive framing

The pitch for Clarity, post-plan, is one sentence:

> **The only smart contract language where the worst case is a theorem, not a
> hope** — every contract's maximum cost is known before it runs, its safety
> properties are machine-checkable, and the code you read on-chain is exactly
> the code that executes.

That is a defensible, durable differentiation. "We run Solidity too" is not.

## 4. The commitment this implies

Keeping Clarity is only justified if we stop treating decidability as trivia
and ship the things it makes possible. Concretely (see
[05-roadmap.md](05-roadmap.md)):

1. A **specification** for the next language version, designed spec-first.
2. **Independent crates** any project can embed (chains, tools, analyzers).
3. A **static cost analyzer** producing sound worst-case bounds per function.
4. **Proof-friendly semantics** and a verification toolchain path.
5. A **conformance suite** that pins interpreter and clar2wasm to identical
   semantics.

If we are not willing to fund those, the "ditch Clarity" argument gets
stronger every year. This plan is the alternative.
