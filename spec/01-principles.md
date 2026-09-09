# 1. Design Principles

These principles are the rejection criteria for every construct in vNEXT,
present and future. A proposal that violates one of them is out of scope
regardless of its merit on other axes.

## P1. Decidability is the invariant

Every vNEXT program terminates, and the worst-case cost of every function is
a computable function of its parameter types. Concretely, the language MUST
keep all of the following true:

- Every type has a statically known maximum size. Lists, buffers, and strings
  carry length bounds. There are no unbounded data structures.
- There is no recursion, direct or mutual, and no unbounded loop. Iteration
  exists only over sequences whose length is bounded by their type.
- Inline expansion and generic instantiation terminate, because the
  definition graph is acyclic.
- Call depth is bounded, and a contract cannot be re-entered while a call
  into it is active.

Any construct that cannot be shown to preserve these properties is rejected.
This is the property that makes exact static cost bounds, complete static
analysis, and tractable proofs possible ([../01-why-clarity.md](../01-why-clarity.md)).

## P2. Minimal core

The core language contains only what passes the layering rule in
[README.md](README.md): host or kernel access, constructs that cannot be
expressed in the language, and operations whose worst-case cost would be
asymptotically worse if written in the language. Everything else is standard
library.

The core is therefore small enough to hold in one head: about a dozen
top-level definition forms, about a dozen expression forms, and about ninety
primitive operations with uniform typing rules. The library holds control
flow and convenience, about twenty definitions, and nothing whose expansion
would cost users materially more than a native would.

## P3. The standard library has no special powers

The standard library is ordinary vNEXT source. It uses only features that
every contract can use, it is type-checked by the same rules, and its cost is
the cost of its expansion. Anything the library can do, a contract author can
do. If the library needs a language feature, that feature is designed and
specified as a user feature.

Corollary: a proposal to "just add a native" for something expressible in
the language is rejected. The right fix is a library function, or if the
library cannot express it well, a general language feature that lets it.

## P4. Cost is defined for core constructs only

The cost model assigns a runtime cost and a static bound-derivation rule to
each core form and each primitive. Library functions have no cost entries.
Their cost is whatever their expansion costs, which the static analyzer
computes like any other user code.

This eliminates an entire class of consensus bugs (a native's cost table
disagreeing with its behavior) and keeps the cost chapter proportional to the
core, not to the library.

An engine MAY implement a library function natively for speed, but it MUST
charge exactly the expansion cost. This rule is only fair to users if
expansions are cheap, which is why the layering rule keeps heavy pure
computation out of the library.

## P5. Source is law, and the library is part of the language

A contract's meaning is fixed by its language version and its source text.
The standard library is versioned with the language, shipped with the engine,
and frozen when the language version is frozen. A later language version MAY
ship a different library. A contract never observes a library change.

There is no compiler between the author and the chain. Compilation
(clar2wasm or any other backend) is an optimization that MUST be
conformance-verified against these semantics.

## P6. One way to do each thing

- No aliases. Legacy pairs such as `element-at`/`element-at?`,
  `index-of`/`index-of?`, and `xor`/`bit-xor` collapse to one name.
- No overlapping forms. `as-contract` is gone; `as-contract?` remains.
  `stx-transfer-memo?` is folded into `stx-transfer?`. `(tuple ...)` is
  gone; `{...}` remains. `begin` is sugar for `let` with no bindings.
- Naming discipline, applied uniformly to core and library:
  - `name?` returns an `optional` or a `response`.
  - `name!` may return early from the enclosing function.
  - `is-name` is a predicate returning `bool`.
  - Names are lowercase words separated by `-`. Tuple fields follow the same
    rule (`error-code`, not `error_code`).
- Fixed arity. Every function and primitive takes a fixed number of
  arguments. `(+ a b c)` is written `(+ (+ a b) c)`. See the open question
  on associative operators in [02-core-language.md](02-core-language.md).

## P7. No undefined behavior, no silent failure

- Arithmetic overflow, division by zero, out-of-range conversions, and
  invalid shift amounts abort the transaction deterministically.
- Errors are values (`response`, `optional`) or aborts. There is no third
  kind of outcome, and a `response` cannot be discarded without handling it.
- There are no null values, no implicit conversions, and no reentrancy.

## P8. Spec first, then implementation

The reference engine implements this specification. Where they disagree, one
of them has a bug, and the disagreement is adjudicated explicitly and
recorded. Every normative rule cites the conformance vectors that exercise
it, and no rule is frozen without vectors.

## What vNEXT is not

- **Not backwards compatible.** vNEXT contracts are written for vNEXT.
  Legacy contracts keep running on the frozen legacy engine forever and can
  be called from vNEXT through the kernel's cross-version call boundary.
- **Not Turing-complete.** See P1.
- **Not general-purpose.** No I/O, no foreign functions, no off-chain
  execution.

## Footguns removed

This list is the concrete payoff of having no compatibility obligation. Each
item is a legacy behavior that vNEXT does not have.

| Legacy behavior | vNEXT |
|---|---|
| `as-contract` grants unrestricted asset access | Only `as-contract?` with explicit allowances |
| `at-block` (already disabled in legacy at epoch 3.4) | Absent |
| `bit-shift-left`/`bit-shift-right` silently reduce the shift amount modulo 128 | Shift amount of 128 or more aborts |
| Variadic `is-eq`, `and`, `or`, `+`, ... with subtly different typing per arity | Fixed binary arity; uniform typing |
| `map-set`, `var-set` return a `bool` that is always `true` | Unchanged for now; see open questions |
| Hashing an `int`/`uint` hashes an unspecified 16-byte encoding | Hash primitives accept buffers only |
| Trait types written `<name>` require `use-trait` aliasing with a distinct lexical form | Trait types are ordinary type expressions `(trait id)`; aliases use `define-type` |
| `principal-construct?` returns a tuple with an `error_code` field | `error-code` |
| Two ways to write tuples, two names for several functions | One way |
| `(with-all-assets-unsafe)` accepted at runtime inside `restrict-assets?` but rejected by the type checker | Rejected by the grammar; valid only in `as-contract?` |
| `secp256r1-verify` accepts high-S (malleable) signatures | All ECDSA primitives require low-S |
| Tuple lub admits a smaller tuple for a larger one, creating hidden fields that must be sanitized at boundaries | Tuple subtyping requires identical field sets |
| Function arguments may shadow constants, and the checker and evaluator resolve them differently | No shadowing of any in-scope name |
| `get-tenure-info? block-reward` aborts the transaction during the maturity gap | Returns `none`; maturity defined by coinbase height |
| Any chain-data lookup the host cannot serve makes the transaction "problematic" and unmineable | All chain-data lookups are total and return `none` |
| Binding a reserved keyword as a local name passes analysis and fails at runtime | No shadowing, checked at analysis time |
| A trait defined in the current contract cannot be used in the contract's own top-level expressions | Local definitions are fully usable at the top level |
| Duplicate parameter names are accepted | Static error |
| A read-only function cannot call a trait function even when every implementation is read-only | Traits may mark functions `read-only`; read-only callers may call those |
| Constants cannot be used where a literal is required (`as-max-len?` bounds, `contract-call?` targets) | Static constants are usable anywhere a literal is |
| Trait-typed values cannot be extracted from tuples and called directly | Any trait-typed expression is a valid `contract-call?` target |
