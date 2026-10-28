# Specification Plan

## Scope decision: two documents, one owner each

- **The Clarity specification** defines the language: syntax, types, semantics,
  the standard library, and what a correct compiler to Wasm produces. It is
  owned by the language project. Drafts live in [spec/](spec/).
- **The chain ABI** defines what any module can rely on, in two layers. The
  runtime layer ([07-chain-abi.md](07-chain-abi.md)) is what the chain
  implements: the module format and interface, host functions and their charges,
  call semantics, runtime guarantees, and the fuel schedule. The interpretation
  layer ([08-value-interpretation.md](08-value-interpretation.md)) is what
  compilers, wallets, and explorers rely on: declared types and value encoding.
  It is owned jointly with the chain and shared by every source language. The
  Clarity spec refers to it and never restates it.

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
  seventy primitive operations. A construct is core if it needs the host, cannot
  be expressed in the language, is a cryptographic standard, or is a base
  operation on a type's representation ([spec/README.md](spec/README.md) states
  the rule). Cost is not a test.
- The **standard library** is everything else: control flow (`if`, `unwrap!`,
  `try!`, `asserts!`, `default-to`), predicates, derived arithmetic (`max`,
  `pow`, `sqrti`), sequence helpers (`append`, `index-of?`, `replace-at?`),
  integer/string/byte conversions, `verify-merkle-proof`, `map-insert?`, and
  more, about thirty-five definitions. It is ordinary Clarity source
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
   the lowering of each core form and primitive, prelude linking, the
   `abi.interface`, `abi.types`, and provenance sections, the validation of
   arguments and call results and the abort codes of runtime errors, and the
   determinism rules. It also carries the argument that loop bounds guaranteed
   by the source types survive compilation, which is what makes "worst-case fuel
   of any function is statically boundable" a theorem. The static cost analyzer
   is derived from that argument.
7. **Primitives and standard library**: every core primitive with its signature,
   semantics, and error cases ([spec/03-primitives.md](spec/03-primitives.md));
   the standard library, specified by its source
   ([spec/std/prelude.clar](spec/std/prelude.clar)), plus the Clarity 1–6
   disposition table
   ([spec/04-standard-library.md](spec/04-standard-library.md)).

The chain ABI is specified separately, in two documents: the runtime layer
([07-chain-abi.md](07-chain-abi.md): module format and interface, host functions
and their charges, call dispatch, runtime guarantees, and the fuel schedule) and
the interpretation layer
([08-value-interpretation.md](08-value-interpretation.md): the type grammar,
canonical encoding, and the `abi.types` section).

## The conformance suite

The suite is what makes the spec real, and it is the highest-leverage artifact
of the effort. Without it the spec is a description that implementations
resemble to varying degrees; with it the spec is a contract that an
implementation either meets or does not.

### What a vector is

A **conformance vector** is one test case written as data rather than as code:
an input, the outcome the spec requires for that input, and the identifiers of
the normative rules it exercises. Because a vector is data, every implementation
runs the same vectors through its own runner, so the suite never depends on any
one implementation's language or test framework. When a vector fails, it names
the rule that was broken.

An illustrative language vector (the concrete format is Phase 0 work in
[05-roadmap.md](05-roadmap.md), and rule identifiers are not yet assigned):

```text
id:     lang/arith/add-uint-overflow
rules:  03 §3.1 (+ overflows), 02 §2.7.2 (runtime errors abort)
source: (define-public (f)
          (ok (+ u340282366920938463463374607431768211455 u1)))
call:   f
expect: abort, class arithmetic-overflow
```

### Four kinds of vector

| Kind             | Input                         | Expected outcome                                                                                                     | Who must pass                                                                 |
| ---------------- | ----------------------------- | -------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------- |
| **Language**     | Contract source, plus calls   | A compile error of a specified class, or for each call: return value, events, asset movements, and whether it aborts | Every Clarity compiler                                                        |
| **ABI**          | A module, plus chain actions  | Deploy validation, rollback, reentrancy and read-only rejection, host function results and charges                   | Every chain implementation, independent of source language                    |
| **Encoding**     | A declared type and bytes     | Whether the bytes decode canonically against the type, and to which value; `serialized-size` of the type             | Every compiler, every tool that decodes values, and the chain's legacy bridge |
| **Golden build** | Source and a compiler version | The exact module bytes                                                                                               | That compiler release, on every supported platform                            |

Language, ABI, and encoding vectors are the suite proper: they pin behavior the
specification requires, and they are written with the spec and versioned with
it. Golden build vectors are different in kind. They pin nothing about the
language; they pin a particular compiler release, so that reproducibility
(section 6 of [03-architecture.md](03-architecture.md)) is testable rather than
asserted. Each compiler release publishes its own.

### What a vector deliberately does not pin

The suite checks what the spec requires and nothing more, so that
implementations keep room to improve:

- **Fuel.** A language vector never states how much fuel a call consumes. A
  better compiler is allowed to produce cheaper code, and a vector that pinned
  fuel would forbid it. Charges for host functions are pinned by ABI vectors,
  because the ABI's fuel schedule is normative for the chain.
- **Module bytes.** A language vector never states what Wasm a compiler emits,
  only how the result behaves. Byte-exactness is the job of golden build
  vectors, and only for one release at a time.
- **Error text.** A compile-error vector names the class of error (an arity
  mismatch, an undefined name, a read-only violation), not a message. Messages
  are a tool's own concern.

### How rules and vectors bind each other

Principle P8 ([spec/01-principles.md](spec/01-principles.md)) states the
contract: every normative rule cites the vectors that exercise it, and no rule
is frozen without vectors. The runner enforces this both ways. A rule that cites
no vector is unfrozen and shows up in a coverage report. A vector that cites no
rule is testing something the spec does not say, which is a spec bug to fix
before the vector is accepted.

Which side is the oracle depends on where the rule lives:

- For the core language, the prose rule is normative. If a compiler and a vector
  disagree, one of them has a bug, and the disagreement is adjudicated
  explicitly and recorded (P8).
- For the standard library, the prelude source is normative
  ([spec/04-standard-library.md](spec/04-standard-library.md)). Library vectors
  are derived from the source, and if a vector and the source disagree, the
  vector is wrong. The same vectors are what hold a hand-written or
  better-compiled replacement, linked by a later compiler in place of the
  source, to identical results, events, and errors.
- For the chain, the runtime layer is normative, and ABI vectors are its suite.
  For values, the interpretation layer is normative, and encoding vectors are
  its suite.

### Where the suite sits among the other defenses

The suite is the floor, not the ceiling. It is a fixed set of cases, so it
catches regressions and divergence on behavior someone thought to write down.
Differential testing against the direct evaluator and fuzzing (section 6 of
[03-architecture.md](03-architecture.md)) search above that floor for behavior
nobody wrote down. Every bug they find becomes a vector, so the floor only
rises.

## Language design opportunities

Candidates for the RFC process, listed to scope ambition, not to commit:

- Consistent naming and calling conventions across the standard library (the
  `unwrap!`/`unwrap-panic`/`try!` family, `?`/`!` suffix discipline).
- A trait system that is fully static, decidable, and pleasant, checked entirely
  at compile time against declared signatures that every language shares
  ([08-value-interpretation.md](08-value-interpretation.md) section 5.2).
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

## Findings from drafting the prelude

Writing the prelude is the test of the core design. Findings so far:

- An earlier draft returned the conversion, search, and Merkle functions to the
  core because their library versions cost more than a native under a
  per-operation cost table. With fuel as the metric and optimization done by a
  compiler linking faster code, that argument is gone, and they are library
  again. The core is smaller and there is no per-construct cost table.
- Template checking of generic bodies carries more weight than planned. It lets
  `index-of?` and the string parsers be one definition across sequence kinds
  instead of four, at the price of errors reported inside the prelude (spec
  2.6.2).
- Per-kind constants (digit tables, the minus sign) need small overloaded
  helpers, because a generic body cannot write a literal of an unknown kind.
- `replace-at?` exposed a gap in the size rules: an intermediate `concat` has a
  larger bound than any value it can hold. Intermediate expressions are checked
  against a separate, larger limit (spec 2.3.1).
- Rest parameters are strict: the extra arguments are built into a list before
  the body runs. That is right for `max`, `+`, and `concat`, but it means n-ary
  short-circuiting cannot be written in the language, so `and` and `or` moved
  from the library into the core (spec 2.5.3).
- `never` as the type of `(return ...)` and `(panic)` makes every early-exit
  form typeable with ordinary lub rules, with no special cases.
- Macros cannot be passed to `filter`, which forces predicates to be private
  functions (spec 2.6.3).
- Folds whose initial value has a smaller type than the step's result
  (`std-reverse-16` starts from `0x`, `std-render-decimal` from `""`,
  `index-of?` from `none`) rely on instantiation finding the accumulator type by
  iteration (spec 2.6.2). Each closes in two steps; a fold that needs a wider
  start states it with `as` (2.5.10).
- Overloading and static reference kinds are each justified by a small group of
  prelude functions (`unwrap!`/`try!` and the integer families; `map-insert?`).
