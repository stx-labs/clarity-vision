# Clarity Vision

This directory captures the goals, architecture, and rationale for evolving
Clarity into a first-class, independently specified programming language — one
that justifies its existence by actually exploiting the properties that make it
unique among smart contract languages.

These documents are working drafts intended to seed discussion. They are
expected to eventually move to a dedicated language repository.

## Documents

| Document | Purpose |
|---|---|
| [01-why-clarity.md](01-why-clarity.md) | The case for investing in Clarity rather than replacing it — unique properties, what they enable, honest gaps, and rebuttals to "switch to an existing VM" |
| [02-goals.md](02-goals.md) | Goals, non-goals, and success criteria for the effort |
| [03-architecture.md](03-architecture.md) | Target crate architecture: a stable kernel plus frozen per-version engine crates, epoch pinning, and the interop boundary |
| [04-spec-plan.md](04-spec-plan.md) | Plan for the language specification (new version only) and the conformance suite |
| [05-roadmap.md](05-roadmap.md) | Phased execution plan with milestones, dependencies, and risks |
| [06-extraction-plan.md](06-extraction-plan.md) | File-level extraction plan: kernel carve-out, the three ABIs (informed by clar2wasm's host-function boundary), pins-not-branches version maintenance, and a hackathon slice |
| [07-consensus-gates.md](07-consensus-gates.md) | Classification and routing rules for language-version, engine-revision, kernel-ruleset, and host epoch gates |
| [spec/](spec/) | The vNEXT specification working draft: a minimal core language plus a standard library written in the language itself, with a disposition for every legacy construct |
| [Interactive walkthrough](demo/) | Web-based explanation of the extraction, call-routing model, gate ownership, and maintainability/security benefits |

## One-paragraph summary

Clarity is the only production smart contract language that is *decidable*:
every program provably terminates, so analyses that are mathematically
impossible for EVM, Wasm, Move, or any Turing-complete VM — exact worst-case
cost bounds, complete static analysis, tractable safety proofs — are possible
for Clarity. Today those properties are largely unexploited, the language is
tangled into stacks-core, and its behavior is defined by accumulated epoch
gating rather than a specification. This effort (1) extracts Clarity into
independent crates built around a stable kernel, (2) freezes each language
version as its own engine crate so new versions can evolve without backwards
compatibility constraints, (3) writes a real specification for the next
language version, and (4) builds the toolchain — starting with a static cost
analyzer and proof-friendly semantics — that turns decidability from a talking
point into a product.
