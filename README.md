# Clarity Vision

This directory captures the goals, architecture, and rationale for the next
Clarity: a redesigned, independently specified language that compiles to Wasm.
It is the first source language for a new chain that executes Wasm.

These documents are working drafts intended to seed discussion. They are
expected to eventually move to a dedicated language repository.

## Documents

| Document                                                 | Purpose                                                                                                                                                                    |
| -------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [01-why-clarity.md](01-why-clarity.md)                   | Why a decidable language on a Wasm chain: what the VM provides, what only the language can provide, the honest gaps, and why not just compile a general-purpose language   |
| [02-goals.md](02-goals.md)                               | Goals, non-goals, and success criteria                                                                                                                                     |
| [03-architecture.md](03-architecture.md)                 | The Clarity toolchain, the module format and chain ABI, the guarantees the chain enforces for every module, and the compiler trust path                                    |
| [04-spec-plan.md](04-spec-plan.md)                       | Plan for the language specification, the chain ABI it depends on, and the conformance suite                                                                                |
| [05-roadmap.md](05-roadmap.md)                           | Phased execution plan with milestones, dependencies, and risks                                                                                                             |
| [06-issue-tracker.md](06-issue-tracker.md)               | Disposition of every open `clarity` issue against the spec draft, and candidate additions                                                                                  |
| [07-chain-abi.md](07-chain-abi.md)                       | Proposal for the runtime layer of the chain ABI shared by every source language: host value encoding, module format, interface, host functions, frames, fuel, and outcomes |
| [08-value-interpretation.md](08-value-interpretation.md) | Proposal for the interpretation layer of the chain ABI: declared types and the encoding conventions compilers, wallets, and explorers rely on                              |
| [spec/](spec/)                                           | The specification working draft: a minimal core language plus a standard library written in the language itself                                                            |

## Terminology

These terms have one meaning across every document here.

- **Contract**: a deployed program, identified by its principal. A contract has
  a source and a module.
- **Source**: the Clarity text a contract is written in.
- **Module**: the Wasm module a contract's source compiles to. It is what the
  chain validates at deploy, stores, and executes. "Module" always means
  compiled Wasm, never Clarity source. The standard library is not a separate
  module: the compiler links the parts a contract uses into that contract's
  module.
- **The chain**: any implementation of the chain ABI that executes modules.
- **Chain ABI**: the contract between compilers and the chain, shared by every
  source language. Its **runtime layer** ([07-chain-abi.md](07-chain-abi.md)) is
  what the chain enforces; its **interpretation layer**
  ([08-value-interpretation.md](08-value-interpretation.md)) is the conventions
  compilers, wallets, and explorers agree on.
- **Host function**: a function the chain provides to modules through the chain
  ABI. Everything a module does beyond pure computation goes through one.
- **Fuel**: the chain's unit of execution cost, consumed by a module's Wasm
  instructions and charged by host functions.
- **Build inputs**: everything a compilation depends on: the source, the
  compiler version, the deployed interfaces of the contracts the source refers
  to, and the deploying principal ([03-architecture.md](03-architecture.md)
  section 2).
- **Provenance section**: the custom section of a module that records the
  compiler version, the source hash, and the hashes of the callee interfaces it
  was compiled against, so that a module names its own build inputs.
- **Verified triple**: a (source, compiler version, module) triple for which
  rebuilding the source with that compiler version, and the other build inputs
  the module's provenance section records, produces the module byte for byte.
  Analyses, cost bounds, and proofs are stated for a verified triple. "Triple"
  means only this.
- **Legacy**: Clarity 1–6, which run on the existing interpreter.
- **vNEXT**: the working name of the new Clarity language.

## One-paragraph summary

The new chain executes Wasm modules, meters them in fuel, and enforces a set of
runtime guarantees for every module regardless of source language
([03-architecture.md](03-architecture.md) section 5). Wasm cannot give the
guarantees that made Clarity worth having, because Wasm is Turing-complete: fuel
makes execution _stop_, but it does not make the worst case _known in advance_.
Clarity adds that. Every Clarity program terminates by construction, and every
loop and value is bounded by its type, so a contract's worst-case cost is
computable before it runs, whole-program analysis is complete, and safety proofs
are tractable. This effort (1) specifies Clarity spec-first as a small core
language plus a standard library written in it, (2) builds a deterministic
compiler to Wasm held to the spec by a conformance suite, (3) defines, with the
chain, an ABI that every source language shares, and (4) builds the toolchain
that turns decidability into products: source verification, a static cost
analyzer, and a property checker.

Clarity 1–6 contracts on the existing chain keep running on the interpreter, and
the interpreter and the Wasm engine can call each other. That arrangement is
outside the scope of these documents.
