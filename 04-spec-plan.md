# Specification Plan

## Scope decision: two documents, one owner each

- **The Clarity specification** defines the language: syntax, types, semantics,
  the standard library, and what a correct compiler to Wasm produces. It is
  owned by the language project. Drafts live in [spec/](spec/).
- **The chain ABI** defines what any module can rely on: the module format,
  interface metadata, value encoding, host functions and their charges, call
  semantics, runtime guarantees, and the fuel schedule. It is owned jointly with
  the chain and shared by every source language. The Clarity spec refers to it
  and never restates it.

Clarity 1–6 are out of scope. They remain defined by their implementation on the
legacy track. The new language owes them nothing in syntax or semantics, and the
disposition table in [spec/04-standard-library.md](spec/04-standard-library.md)
serves as the porting guide.

The language is designed **spec-first**: the spec is written and reviewed before
the reference compiler, and the compiler is validated against it, never the
other way around.

## Structure decision: minimal core plus a standard library

The spec is organized as **a small core language and a standard library written
in that language**.

- The **core** is the syntax, the type system, about a dozen special forms
  (binding, `match`, `return`, definitions, calls, context scoping), and about
  eighty primitive operations. A construct is core if it needs the host, cannot
  be expressed in the language, is a cryptographic standard, or is a base
  operation on a type's representation ([spec/README.md](spec/README.md) states
  the rule). Cost is not a test.
- The **standard library** is everything else: control flow (`if`, `unwrap!`,
  `try!`, `asserts!`, `default-to`), predicates, derived arithmetic (`mod`,
  `pow`, `sqrti`), sequence helpers (`append`, `index-of?`, `replace-at?`),
  integer/string/byte conversions, `verify-merkle-proof`, `map-insert`, and
  more, about forty definitions. It is ordinary Clarity source
  ([spec/std/prelude.clar](spec/std/prelude.clar)), versioned and frozen with
  the language, compiled and linked into each module like user code, and it has
  no powers a contract author lacks.
- **Cost is Wasm fuel, not a language concern.** Contracts are metered by the
  fuel their Wasm consumes, plus the chain's charges for host functions. The
  language has no cost table, so the "cost table disagrees with behavior" bug
  class cannot occur. The prelude's source defines results; a later compiler may
  link a faster implementation, which changes nothing for contracts already
  deployed.

## Spec structure

A versioned document set, one complete spec per language version (the
ECMAScript/Rust-edition model; no delta chains to reconstruct):

1. **Design principles**: decidability as an invariant; every construct must
   preserve statically bounded execution. This chapter is the rejection
   criterion for future proposals.
2. **Lexical structure and grammar**: complete EBNF for the surface syntax,
   including the honest edge cases (string escapes, integer literal bounds,
   principal literals, identifier rules).
3. **Type system**: types, subtyping, trait typing (fully static and decidable),
   inference rules written formally enough to derive a checker from. Every rule
   numbered and conformance-tested.
4. **Static semantics**: the analysis passes the language requires: read-only
   checking, trait conformance, definition ordering. Specified as judgments, not
   as descriptions of a checker.
5. **Dynamic semantics**: evaluation order, error, abort, and rollback
   semantics, context scoping (`as-contract?`, `restrict-assets?`), storage
   visibility, event emission. Written in a proof-friendly style (small-step or
   big-step operational semantics) so verification tools can consume it. This is
   the semantics every compiler must preserve.
6. **Compilation to Wasm**: the module layout Clarity uses within the chain ABI,
   the lowering of each core form and primitive, prelude linking, the interface
   and provenance sections, and the determinism rules. It also carries the
   argument that loop bounds guaranteed by the source types survive compilation,
   which is what makes "worst-case fuel of any function is statically boundable"
   a theorem. The static cost analyzer is derived from that argument.
7. **Primitives and standard library**: every core primitive with its signature,
   semantics, and error cases ([spec/03-primitives.md](spec/03-primitives.md));
   the standard library, specified by its source
   ([spec/std/prelude.clar](spec/std/prelude.clar)), plus the Clarity 1–6
   disposition table
   ([spec/04-standard-library.md](spec/04-standard-library.md)).

The chain ABI is a separate document with its own chapters: value model and wire
format, module format and interface metadata, host functions and their charges,
call dispatch and boundary validation, runtime guarantees, and the fuel
schedule.

## The conformance suite

The suite is what makes the spec real, and it is the highest-leverage artifact
of the effort. It has two layers:

- **Language vectors**: contract source plus the expected outcome (a compile
  error of a specified class, or return values, events, asset movements, and
  aborts for given calls). They do not pin fuel, because a better compiler is
  allowed to produce cheaper code. Every normative rule cites the vectors that
  exercise it. Every Clarity compiler must pass them.
- **ABI vectors**: modules plus expected chain behavior (deploy validation,
  boundary validation, rollback, reentrancy and read-only rejection, host
  function results and charges). Every chain implementation must pass them, and
  they are language-independent.

Separately, each compiler release publishes **golden build vectors** (source to
exact module bytes) so reproducibility is testable.

## Language design opportunities

Candidates for the RFC process, listed to scope ambition, not to commit:

- Consistent naming and calling conventions across the standard library (the
  `unwrap!`/`unwrap-panic`/`try!` family, `?`/`!` suffix discipline).
- A trait system that is fully static, decidable, and pleasant, designed for
  boundary validation by the chain from the start.
- Cost transparency in the language: contracts and functions can declare fuel
  bounds that the analyzer verifies; callers can rely on them.
- Richer (still bounded) iteration and data manipulation, so common patterns
  stop requiring fold contortions. Every addition passes the chapter-1
  decidability test.
- First-class annotations for verification (invariants, pre/postconditions)
  consumed by the proof toolchain.
- Remove the footguns of Clarity 1–6.

## Process and governance

- Spec development runs as an open RFC process in the language repo. Each
  chapter and each language feature is an RFC with a decidability analysis as a
  required section.
- A new language version is a spec release plus a compiler release. It needs the
  chain only when it depends on a new host function or ABI feature, and those
  changes follow the chain's own governance.
- The spec versions with the language: each version gets its own complete spec.
  The chain ABI versions separately and is additive once frozen.
