| [std/prelude.clar](std/prelude.clar) | Draft | The library itself |# Clarity vNEXT Specification (working draft)

This directory holds the working draft of the specification for the next
Clarity language version (working name **vNEXT**; expected to ship as
"Clarity 7"). It follows the scope decision in
[../04-spec-plan.md](../04-spec-plan.md): Clarity 1–6 are
implementation-defined and are not specified here.

> [!IMPORTANT]
> Everything in this directory is a draft intended to seed the RFC process.
> Nothing here is normative yet. Each chapter lists its open questions at the
> end; an open question tagged `RFC` needs its own design RFC before the
> chapter can be frozen.

## The two-layer design

vNEXT is specified as **a small core language plus a standard library written
in that core language**. This is the single most important structural
decision in the spec, and every chapter is organized around it:

| Layer | Contents | Where specified |
|---|---|---|
| **Core language** | Syntax, types, a fixed set of *special forms* (binding, branching, early exit, definitions, calls, context scoping) and a fixed set of *primitive operations* (arithmetic, sequences, storage, assets, chain data, crypto, serialization) | [02-core-language.md](02-core-language.md), [03-primitives.md](03-primitives.md) |
| **Standard library** | Every other construct a contract author uses: `if`, `and`, `or`, `unwrap!`, `try!`, `asserts!`, `default-to`, `append`, `map-insert`, `index-of?`, integer/string conversions, `verify-merkle-proof`, and so on. Written in vNEXT and shipped with the engine as a prelude | [04-standard-library.md](04-standard-library.md), [std/prelude.clar](std/prelude.clar) |

### The layering rule

A construct belongs in the core **only if** it passes at least one of these
tests; otherwise it belongs in the standard library:

1. **Host or kernel access.** It reads or writes contract state, moves
   assets, reads chain data, reads the transaction context, emits events, or
   calls another contract. (Examples: `map-get?`, `ft-transfer?`,
   `stacks-block-height`, `print`, `contract-call?`.)
2. **Not expressible.** It cannot be written in the language at all because
   it introduces binding, branching, early exit, definitions, generics, or
   type-directed behavior. (Examples: `let`, `match`, `return`,
   `define-map`, `is-eq`, `from-consensus-buff?`.)
3. **Asymptotic cost.** Writing it in the language would make its worst-case
   cost asymptotically worse than a primitive, which would distort the cost
   model for everyone. (Examples: `concat`, `slice?`, `sha256`, `pow`.)
4. **Cheap to specify, expensive to expand.** Its signature fits the uniform
   primitive notation, its semantics fit a sentence, and its expansion in
   the language would cost more than a small constant factor over a native
   implementation. Such a function costs one table row as a primitive and
   would cost users real fees as library code. (Examples: `int-to-ascii`,
   `index-of?`, `buff-to-int-le`, `verify-merkle-proof`.)

The library is therefore the home of **control flow and convenience**: the
early-exit family, branching, predicates, and small compositions of one or
two primitives whose expansion costs what a native would. Pure computation
with a plain signature stays primitive.

The standard library has **no special powers**. It is ordinary vNEXT source
that uses only features available to every contract. If the library needs a
feature (generics, inline functions, overloading, static references), that
feature is a user feature and is specified as such.

### Why this shape

- **The spec shrinks where it matters.** The legacy special forms with
  bespoke lazy-evaluation and typing rules (`if`, `and`, `or`, `unwrap!`,
  `try!`, `asserts!`, `default-to`, ...) become about twenty library
  definitions whose semantics are *defined by their source*. There is
  nothing to specify about `unwrap!` beyond the four lines that implement
  it. The remaining natives become about 90 primitives with uniform typing
  rules.
- **The cost model shrinks with it.** Cost is defined only for core forms and
  primitives. A library function costs exactly what its expansion costs. There
  is no separate cost table to keep in sync with behavior, and the static
  cost analyzer only ever sees core constructs.
- **Reference implementations cannot disagree about the library.** Any
  engine that implements the core correctly gets the library for free.
- **Design pressure goes the right way.** Each proposed addition must either
  pass the layering rule (and pay the full price of a core change) or be
  written as library code, where it is cheap, reviewable, and provably
  bounded.

## Chapters

| Chapter | Status | Maps to plan chapter |
|---|---|---|
| [01-principles.md](01-principles.md) | Draft | 1 (design principles) |
| [02-core-language.md](02-core-language.md) | Draft | 2, 3, 4, 5 (grammar, types, static and dynamic semantics) |
| [03-primitives.md](03-primitives.md) | Draft | 7 (native reference, reduced to primitives) |
| [04-standard-library.md](04-standard-library.md) | Draft | 7 (library), plus the legacy-to-vNEXT disposition table |
| [05-issue-tracker.md](05-issue-tracker.md) | Draft | Disposition of every open `clarity` issue and candidate additions |
| [std/prelude.clar](std/prelude.clar) | Draft | The library itself |
| Cost model | Not started | 6 |
| Kernel interfaces | Not started; tracked with the extraction work | 8 |
| Conformance vectors | Not started | Conformance suite |

## Conventions

- **MUST**, **MUST NOT**, **SHOULD**, **MAY** carry their RFC 2119 meanings.
- Type signatures use the notation `name : (arg-types) -> result-type`.
  Uppercase single letters (`T`, `E`, `K`, `V`) are type variables; `N`, `M`
  are size (length-bound) variables. A signature written "for `I` in
  {`int`, `uint`}" is a family of signatures, one per listed type.
- Source examples are written in vNEXT syntax, which differs from Clarity 1–6
  where noted.
- "Legacy" means Clarity 1–6 as implemented by the frozen legacy engine.
