# Specification Plan

## Scope decision: spec the new version only

Clarity 1–6 accumulated six generations of naming inconsistencies, semantic
quirks, and epoch-conditioned bugfixes. Formalizing that history would consume
the entire spec budget documenting behavior nobody would design on purpose.

Therefore:

- **Clarity 1–6 are implementation-defined.** Their normative definition is
  the frozen `clarity-legacy` engine crate, pinned per epoch. We write no spec
  for them.
- **The next language version (working name: vNEXT) is designed spec-first.**
  The spec is written and reviewed *before* the reference implementation, and
  the implementation is validated against it — not the other way around.
- **Kernel-level artifacts are specified for all versions**, because they
  cross version boundaries: the value model and wire format (formalizing
  SIP-005), stored contract-interface metadata, the host interface, and the
  cross-version call semantics. These are the only places the spec touches
  legacy behavior, and only at the boundary.

## Structure decision: minimal core plus a standard library

The vNEXT spec is organized as **a small core language and a standard
library written in that language**. Drafts live in [spec/](spec/).

- The **core** is the syntax, the type system, about a dozen special forms
  (binding, `match`, `return`, definitions, calls, context scoping), and
  about ninety primitive operations. A construct is core if it needs the
  host or kernel, cannot be expressed in the language, would be
  asymptotically more expensive if written in the language, or has a plain
  signature and would cost users materially more as library code than as a
  native ([spec/README.md](spec/README.md) states the rule).
- The **standard library** is control flow and convenience: `if`, `and`,
  `or`, `unwrap!`, `try!`, `asserts!`, `default-to`, the `is-*` predicates,
  `append`, `map-insert`, `stx-get-balance`, and a few more, about twenty
  definitions in all. It is ordinary vNEXT source shipped with the engine as a prelude
  ([spec/std/prelude.clar](spec/std/prelude.clar)), versioned and frozen with
  the language, and it has no powers a contract author lacks.
- **Cost is defined for core constructs only.** A library function costs
  what its expansion costs. This removes the "cost table disagrees with
  behavior" bug class and keeps the cost chapter proportional to the core.

Consequences for the chapter list below: chapter 7 becomes a reference for
primitives (not for every user-facing function), and the library's
normative definition is its source, with conformance vectors derived from
it.

## Spec structure

A versioned document set, one complete spec per language version (the
ECMAScript/Rust-edition model — no delta-chains to reconstruct):

1. **Design principles** — decidability as an invariant; every construct must
   preserve statically-bounded execution. This chapter is the rejection
   criterion for future proposals.
2. **Lexical structure & grammar** — complete EBNF for the surface syntax,
   including the honest edge cases (string escapes, integer literal bounds,
   principal literals, identifier rules).
3. **Type system** — types, admission rules, subtyping/compatibility,
   trait typing (fully static and decidable), inference rules written
   formally enough to derive a checker from. Every rule numbered and
   conformance-tested.
4. **Static semantics** — analysis passes the language *requires*:
   read-only enforcement, trait conformance, definition ordering. Specified
   as judgments, not as descriptions of the current checker.
5. **Dynamic semantics** — evaluation order, error/abort/rollback semantics,
   `as-contract`/`at-block`-style context manipulation, database visibility
   rules, event emission. Written in a proof-friendly style (small-step or
   big-step operational semantics) so verification tools can consume it.
6. **Cost model** — the semantics of cost accounting *and* the static
   bound-derivation rules: for every construct, both its runtime charge and
   the rule by which its worst case is computed from types. The static cost
   analyzer is derived from this chapter; "cost of any function is statically
   boundable" is a theorem the chapter must support.
7. **Primitives and standard library** — every core primitive: signature,
   cost, semantics, error cases ([spec/03-primitives.md](spec/03-primitives.md)).
   The standard library is specified by its source
   ([spec/std/prelude.clar](spec/std/prelude.clar)) plus a disposition table
   mapping every legacy native onto vNEXT
   ([spec/04-standard-library.md](spec/04-standard-library.md)).
8. **Kernel interfaces** (shared across versions) — value wire format,
   stored contract-interface format, host interface obligations,
   cross-version call and trait-compatibility rules.

## The conformance suite

The suite is what makes the spec real, and it is the highest-leverage artifact
of the whole effort:

- **Format**: implementation-independent test vectors — contract source plus
  expected outcome (analysis result or specific error, return value, events,
  asset movements, cost). Versioned alongside the spec; every normative rule
  cites the vectors that exercise it.
- **Consumers**: the reference interpreter, clar2wasm, and any future
  implementation must pass identically. This is precisely the parity harness
  the clar2wasm effort lacks today — the suite should be built to serve it
  from day one.
- **Legacy anchoring**: separately, vectors *captured from real mainnet
  transactions* (inputs → observed values/events/costs) pin `clarity-legacy`
  during the architecture refactor. These are regression armor, not spec.

## Language design opportunities for vNEXT

With no backwards-compatibility obligation, vNEXT can fix what six versions
could not. Candidate directions (each needs its own design RFC; listed here to
scope ambition, not to commit):

- Consistent naming and calling conventions across the standard library
  (the `unwrap!`/`unwrap-panic`/`try!` family, `?`/`!` suffix discipline).
- A trait system that is fully static, decidable, and pleasant — designed for
  the kernel's cross-version compatibility rules from the start.
- Cost transparency in the language: contracts and functions can declare cost
  bounds the analyzer verifies; callers can rely on them.
- Richer (still bounded) iteration and data manipulation, so common patterns
  stop requiring fold contortions — every addition passes the chapter-1
  decidability test.
- First-class annotations for verification (invariants, pre/postconditions)
  consumed by the proof toolchain.
- Remove the footguns the legacy engine must keep forever.

## Process and governance

- Spec development runs as an open RFC process in the language repo; each
  chapter and each vNEXT language feature is an RFC with a decidability and
  cost-boundability analysis as a required section.
- Activation on Stacks remains SIP-governed: the SIP for the activating epoch
  references the spec version and the engine crate release. The spec is the
  technical artifact; the SIP is the governance artifact.
- The spec versions with the language: vNEXT+1 gets its own complete spec.
  Kernel-interface chapters are shared and additive-only, like the kernel.
