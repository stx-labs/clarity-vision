# 1. Design Principles

These principles are the rejection criteria for every construct in vNEXT,
present and future. A proposal that violates one of them is out of scope
regardless of its merit on other axes.

## P1. Decidability is the invariant

Every vNEXT program terminates, and the worst-case cost of every function is a
computable function of its parameter types. Concretely, the language MUST keep
all of the following true:

- Every type has a statically known maximum size. Lists, buffers, and strings
  carry length bounds. There are no unbounded data structures.
- There is no recursion, direct or mutual, and no unbounded loop. Iteration
  exists only over sequences whose length is bounded by their type.
- Inline expansion and generic instantiation terminate, because the definition
  graph is acyclic.
- Call depth is bounded, and a contract cannot be re-entered while a call into
  it is active.

Any construct that cannot be shown to preserve these properties is rejected.
This is the property that makes exact static cost bounds (in fuel, P4), complete
static analysis, and tractable proofs possible
([../01-why-clarity.md](../01-why-clarity.md)).

## P2. Minimal core

The core language contains only what passes the layering rule in
[README.md](README.md): host access, constructs that cannot be expressed in the
language, hash functions and signature schemes defined by external standards,
and the base operations on each type's representation. Everything else is
standard library.

The core is therefore small enough to hold in one head: about a dozen top-level
definition forms, about a dozen expression forms, and about eighty primitive
operations with uniform typing rules. The library holds everything else a
contract author uses, about forty definitions.

## P3. The standard library has no special powers

The standard library is ordinary vNEXT source. It uses only features that every
contract can use, it is type-checked by the same rules, and it is compiled and
metered like any other code. Anything the library can do, a contract author can
do. If the library needs a language feature, that feature is designed and
specified as a user feature.

Corollary: a proposal to "just add a native" for something expressible in the
language is rejected. The right fix is a library function, or if the library
cannot express it well, a general language feature that lets it. Speed is not a
reason to add a native; see P4.

## P4. Cost is not a language concern

The language assigns no cost to any construct. Execution is metered in the fuel
the chain's Wasm engine consumes running a contract's module, plus the chain
ABI's charges for host functions (storage I/O, asset operations, chain-data
lookups, contract calls, cryptography). Both belong to the chain ABI, not to
this specification.

Consequences:

- There is no per-construct cost table, so there is no class of bugs where a
  cost table disagrees with behavior, and no cost chapter that grows with the
  language.
- A library function costs the fuel of its compiled code, like user code.
- The static bound still exists. By P1, every loop and every value is bounded by
  its type, so the worst-case fuel of every function is computable from the
  source, its compiled module, and the chain's charge table (chapter 6 of the
  plan carries the argument that compilation preserves the bounds).

## P5. The deployed Wasm is law; the source is its specification

The chain stores and executes Wasm modules and never sees Clarity source. What a
deployed contract does is what its module does.

This specification defines what a module compiled from a given source MUST do:
its results, state changes, events, and aborts. A compiler that produces a
module whose behavior differs from the source's meaning has a bug. The language
keeps its guarantees on chain only through compilers that meet this spec, which
is why compilers are held to the conformance suite and to deterministic,
verifiable builds ([../03-architecture.md](../03-architecture.md)).

The standard library is versioned with the language and frozen when the language
version is frozen; its source defines its results. The compiler links the
library code a contract uses into that contract's module. A later compiler MAY
link a faster implementation, which MUST produce identical results; contracts
already deployed keep the code they were deployed with. A contract never
observes a library change.

## P6. One way to do each thing

- No aliases. Legacy pairs such as `element-at`/`element-at?`,
  `index-of`/`index-of?`, and `xor`/`bit-xor` collapse to one name.
- No overlapping forms. `as-contract` is gone; `as-contract?` remains.
  `stx-transfer-memo?` is folded into `stx-transfer?`. `(tuple ...)` is gone;
  `{...}` remains. `begin` is sugar for `let` with no bindings.
- Naming discipline, applied uniformly to core and library:
  - `name?` returns an `optional` or a `response`.
  - `name!` may return early from the enclosing function.
  - `is-name` is a predicate returning `bool`.
  - Names are lowercase words separated by `-`. Tuple fields follow the same
    rule (`error-code`, not `error_code`).
- Declared arity. Every call's arity is fixed by its definition: exactly the
  declared parameters, or, for a definition ending in a rest parameter
  `(name T...)`, the fixed parameters plus one or more arguments collected into
  a list (2.6.5). `(+ a b c)` works because `+` has a rest parameter, not
  because `+` is special; a user function can have one the same way. There are
  no optional parameters and no per-arity typing rules.

## P7. No undefined behavior, no silent failure

- Arithmetic overflow, division by zero, out-of-range conversions, and invalid
  shift amounts abort the transaction deterministically.
- Errors are values (`response`, `optional`) or aborts. There is no third kind
  of outcome, and a `response` cannot be discarded without handling it.
- There are no null values, no implicit conversions, and no reentrancy.

## P8. Spec first, then implementation

The reference compiler implements this specification. Where they disagree, one
of them has a bug, and the disagreement is adjudicated explicitly and recorded.
Every normative rule cites the conformance vectors that exercise it, and no rule
is frozen without vectors.

## What vNEXT is not

- **Not backwards compatible.** vNEXT contracts are written for vNEXT. Chapter
  4's disposition table maps every Clarity 1–6 construct for porting.
- **Not Turing-complete.** See P1.
- **Not general-purpose.** No I/O, no foreign functions, no off-chain execution.
- **Not privileged.** Clarity is the first language on the chain, not a special
  one. Everything a Clarity contract does on chain goes through the same chain
  ABI as any other module.

## Footguns removed

This list is the concrete payoff of having no compatibility obligation. Each
item is a legacy behavior that vNEXT does not have.

| Legacy behavior                                                                                                               | vNEXT                                                                                                                                                                                   |
| ----------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `as-contract` grants unrestricted asset access                                                                                | Only `as-contract?` with explicit allowances                                                                                                                                            |
| `at-block` (already disabled in legacy at epoch 3.4)                                                                          | Absent                                                                                                                                                                                  |
| `bit-shift-left`/`bit-shift-right` silently reduce the shift amount modulo 128                                                | Shift amount of 128 or more aborts                                                                                                                                                      |
| Variadic `is-eq`, `and`, `or`, `+`, ... with subtly different typing per arity                                                | Arity is declared: a rest parameter collects extra arguments into a list, typed by the ordinary rules; `and`/`or` are core short-circuit forms; `is-eq` and comparisons are binary only |
| Hashing an `int`/`uint` hashes an unspecified 16-byte encoding                                                                | Hash primitives accept buffers only                                                                                                                                                     |
| `buff-to-int-be`/`buff-to-int-le` zero-pad a short buffer, so `0xff` is `255` but the same bytes in a 16-byte buffer are `-1` | Signed conversions sign-extend from the buffer's actual length; `(buff-to-int-be 0xff)` is `-1`                                                                                         |
| Trait types written `<name>` require `use-trait` aliasing with a distinct lexical form                                        | Trait types are ordinary type expressions `(trait id)`; aliases use `define-type`                                                                                                       |
| `principal-construct?` returns a tuple with an `error_code` field                                                             | `error-code`                                                                                                                                                                            |
| Two ways to write tuples, two names for several functions                                                                     | One way                                                                                                                                                                                 |
| `(with-all-assets-unsafe)` accepted at runtime inside `restrict-assets?` but rejected by the type checker                     | Rejected by the grammar; valid only in `as-contract?`                                                                                                                                   |
| `secp256r1-verify` accepts high-S (malleable) signatures                                                                      | All ECDSA primitives require low-S                                                                                                                                                      |
| Tuple lub admits a smaller tuple for a larger one, creating hidden fields that must be sanitized at boundaries                | Tuple subtyping requires identical field sets                                                                                                                                           |
| Function arguments may shadow constants, and the checker and evaluator resolve them differently                               | No shadowing of any in-scope name                                                                                                                                                       |
| `get-tenure-info? block-reward` aborts the transaction during the maturity gap                                                | Returns `none`; maturity defined by coinbase height                                                                                                                                     |
| Any chain-data lookup the host cannot serve makes the transaction "problematic" and unmineable                                | All chain-data lookups are total and return `none`                                                                                                                                      |
| Binding a reserved keyword as a local name passes analysis and fails at runtime                                               | No shadowing, checked at analysis time                                                                                                                                                  |
| A trait defined in the current contract cannot be used in the contract's own top-level expressions                            | Local definitions are fully usable at the top level                                                                                                                                     |
| Duplicate parameter names are accepted                                                                                        | Static error                                                                                                                                                                            |
| A read-only function cannot call a trait function even when every implementation is read-only                                 | Traits may mark functions `read-only`; read-only callers may call those                                                                                                                 |
| Constants cannot be used where a literal is required (`as-max-len?` bounds, `contract-call?` targets)                         | Static constants are usable anywhere a literal is                                                                                                                                       |
| Trait-typed values cannot be extracted from tuples and called directly                                                        | Any trait-typed expression is a valid `contract-call?` target                                                                                                                           |
| `is-standard` is true for a contract principal on the current network and false for a standard principal on the other network | `is-current-network` for the network test; `is-standard` is true exactly for standard principals                                                                                       |
