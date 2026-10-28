# Clarity vNEXT Specification (working draft)

This directory holds the working draft of the specification for the new Clarity
language (working name **vNEXT**), which compiles to Wasm for the new chain. It
follows the scope decision in [../04-spec-plan.md](../04-spec-plan.md): Clarity
1–6 are not specified here, and the chain ABI that every source language shares
is specified separately, in [../07-chain-abi.md](../07-chain-abi.md) and
[../08-value-interpretation.md](../08-value-interpretation.md), which this spec
refers to.

> [!IMPORTANT] Everything in this directory is a draft intended to seed the RFC
> process. Nothing here is normative yet. A chapter with open questions lists
> them at the end; an open question tagged `RFC` needs its own design RFC before
> the chapter can be frozen.

## The two-layer design

vNEXT is specified as **a small core language plus a standard library written in
that core language**. This is the single most important structural decision in
the spec, and every chapter is organized around it:

| Layer                | Contents                                                                                                                                                                                                                                                                                      | Where specified                                                                        |
| -------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------- |
| **Core language**    | Syntax, types, a fixed set of _special forms_ (binding, branching, early exit, definitions, constructors, tuple access, type ascription, calls, context scoping) and a fixed set of _primitive operations_ (host access, cryptography, and the base operations on each type's representation) | [02-core-language.md](02-core-language.md), [03-primitives.md](03-primitives.md)       |
| **Standard library** | Every other construct a contract author uses: `if`, `unwrap!`, `try!`, `asserts!`, `default-to`, `max`, `pow`, `append`, `index-of?`, `map-insert?`, integer/string conversions, `verify-merkle-proof`, and so on. Written in vNEXT and linked into every module by the compiler              | [04-standard-library.md](04-standard-library.md), [std/prelude.clar](std/prelude.clar) |

### The layering rule

A construct belongs in the core **only if** it passes at least one of these
tests; otherwise it belongs in the standard library:

1. **Host access.** It reads or writes contract state, moves assets, reads chain
   data, reads the transaction context, emits events, or calls another contract.
   (Examples: `map-get?`, `ft-transfer?`, `get-current-context`, `print`,
   `contract-call?`.)
2. **Not expressible.** It cannot be written in the language at all because it
   introduces binding, branching, early exit, definitions, generics, or
   type-directed behavior, takes a type or size argument, or needs a function
   argument that the language cannot close over. (Examples: `let`, `match`,
   `return`, `define-map`, `is-eq`, `as-max-len?`, `from-consensus-buff?`,
   `uint-to-buff-be`, `map`, `filter`.)
3. **Cryptographic standard.** It is an operation that an external standard
   defines for a hash function or signature scheme: hashing, signature
   verification, or public-key operations such as recovery and decompression.
   These are implemented once, by audited host libraries, not reimplemented in
   the language, even where one operation of a scheme could be derived from
   another. Constructions built from them are library code. (Examples: `sha256`,
   `secp256k1-verify`, `secp256k1-recover?`, `secp256k1-decompress?`; but
   `hash160`, `verify-merkle-proof`, and `principal-of?` are library.)
4. **Representation base.** It is part of a built-in type's ordinary operator
   vocabulary: the integer arithmetic operators `+ - * / mod`, the bitwise
   operators (`bit-and`, `bit-or`, `bit-xor`, `bit-not`, and the shifts), the
   comparisons (`<`, `<=`, `>`, `>=`), the base conversions (`to-int`,
   `to-uint`, `buff-to-uint-be`), and sequence length, concatenation, indexing,
   and slicing. Named functions over that vocabulary are library (`max`, `abs`,
   `pow`, `sqrti`, `buff-to-int-le`, `int-to-ascii`). The list is a decision,
   not a derivation: some members can be written in terms of others, and the
   choice assumes nothing about how a compiler represents values or what an
   operation costs. Adding to it is a core change. (The `*-to-buff-*` family is
   core by test 2, not this one: each takes a size argument.)

Two primitives fail every test and stay core only until their library
definitions are written (chapter 3.12).

Cost is not a test. Contracts are metered by the fuel their compiled Wasm
consumes, so a library function costs what its code costs to run, and a function
that turns out to be hot is optimized by a compiler that links a faster
implementation, not by moving it into the core (chapter 4.1).

The standard library has **no special powers**. It is ordinary vNEXT source that
uses only features available to every contract. If the library needs a feature
(generics, macros, overloading, static references), that feature is a user
feature and is specified as such.

### Why this shape

- **The spec shrinks where it matters.** The legacy special forms with bespoke
  lazy-evaluation and typing rules (`if`, `unwrap!`, `try!`, `asserts!`,
  `default-to`, ...) and the derived arithmetic, sequence, and conversion
  natives become library definitions whose semantics are _defined by their
  source_. There is nothing to specify about `unwrap!` beyond the four lines
  that implement it. The remaining natives become about 70 primitives with
  uniform typing rules.
- **The language has no cost table.** Execution is metered in Wasm fuel, and the
  only other charges are the chain ABI's charges for host functions. There is no
  per-construct cost table to keep in sync with behavior, and nothing about cost
  to specify for the library.
- **Compilers cannot disagree about the library.** Any compiler that implements
  the core correctly gets the library for free.
- **Design pressure goes the right way.** Each proposed addition must either
  pass the layering rule (and pay the full price of a core change) or be written
  as library code, where it is cheap, reviewable, and provably bounded.

## Chapters

| Chapter                                          | Status                                                                                                                                                                                        | Maps to plan chapter                                                                 |
| ------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------ |
| [01-principles.md](01-principles.md)             | Draft                                                                                                                                                                                         | 1 (design principles)                                                                |
| [02-core-language.md](02-core-language.md)       | Draft                                                                                                                                                                                         | 2, 3, 4, 5 (grammar, types, static and dynamic semantics)                            |
| [03-primitives.md](03-primitives.md)             | Draft                                                                                                                                                                                         | 7 (native reference, reduced to primitives)                                          |
| [04-standard-library.md](04-standard-library.md) | Draft                                                                                                                                                                                         | 7 (library), plus the legacy-to-vNEXT disposition table                              |
| [std/prelude.clar](std/prelude.clar)             | Draft                                                                                                                                                                                         | The library itself                                                                   |
| Compilation to Wasm                              | Not started                                                                                                                                                                                   | 6 (lowering, prelude linking, determinism, bound preservation)                       |
| Chain ABI                                        | Proposal, shared by every source language: [../07-chain-abi.md](../07-chain-abi.md) (runtime layer) and [../08-value-interpretation.md](../08-value-interpretation.md) (interpretation layer) | ABI (module format, host functions, frames, fuel; declared types and value encoding) |
| Conformance vectors                              | Not started                                                                                                                                                                                   | Conformance suite                                                                    |

## Conventions

- **MUST**, **MUST NOT**, **SHOULD**, **MAY** carry their RFC 2119 meanings.
- **Rule identifiers.** While a chapter is a draft, a normative rule is
  identified by the section that states it (for example 2.6.5). When a chapter's
  conformance vectors are written, each rule in it gains the identifier
  `<section>-<n>`, numbered in order of appearance within the section, and
  vectors cite that identifier. Identifiers are assigned at that point and not
  before, so that a moving draft is not renumbered.
- **Open questions.** Each chapter ends with its open questions. One tagged
  `RFC` needs its own design RFC before the chapter can be frozen.
- Type signatures use the notation `name : (arg-types) -> result-type`.
  Uppercase single letters (`T`, `E`, `K`, `V`) are type variables; `N`, `M` are
  size (length-bound) variables. A signature written "for `I` in {`int`,
  `uint`}" is a family of signatures, one per listed type.
- Source examples are written in vNEXT syntax, which differs from Clarity 1–6
  where noted.
- "Legacy" means Clarity 1–6. It appears only in comparisons and in the porting
  table of chapter 4.
- "The chain" means any chain implementation of the chain ABI, and "host
  function" means a function the chain provides to modules through it.
