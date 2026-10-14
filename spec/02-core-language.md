# 2. Core Language

This chapter defines the vNEXT core: lexical structure, types, top-level forms,
expression forms, functions, and dynamic semantics. Primitive operations are
enumerated in [03-primitives.md](03-primitives.md); everything else a contract
author uses is defined in the standard library
([04-standard-library.md](04-standard-library.md)).

The presentation here is semi-formal. Typing rules are given as prose with
signatures. The formal judgment-style rules and the full EBNF are follow-up work
once the design questions at the end of this chapter are settled.

## 2.1 Notation

- `name : (A B) -> R` is a signature: `name` takes an `A` and a `B` and produces
  an `R`.
- `T`, `E`, `K`, `V`, `A`, `U` are type variables. `N`, `M` are size variables
  (natural numbers bounding sequence lengths).
- `S <: T` means `S` is a subtype of `T` (2.3.2). `lub(S, T)` is their least
  upper bound when it exists.
- `never` is the empty type (2.3.1).

## 2.2 Lexical structure

vNEXT source is a sequence of S-expressions.

- **Comments** begin with `;;` and run to end of line.
- **Identifiers** are non-empty sequences of ASCII letters, digits, and the
  characters `- _ ! ? + < > = / * ^`, not starting with a digit, at most 128
  bytes long. Identifiers are case-sensitive.
- **Integer literals**: `uint` literals are `u` followed by decimal digits
  (`u42`); `int` literals are optional `-` followed by decimal digits (`42`,
  `-7`). Values outside the 128-bit range are a parse error.
- **Boolean literals**: `true`, `false`.
- **Buffer literals**: `0x` followed by an even number of hex digits (`0x`,
  `0xdeadbeef`).
- **ASCII string literals**: `"..."` with escapes `\\`, `\"`, `\n`, `\t`, `\r`.
  The **`string-ascii` character set** is the printable ASCII characters 0x20
  through 0x7E plus tab (0x09), line feed (0x0A), and carriage return (0x0D).
  A literal may contain only these characters, the three control characters
  only through their escapes, and no value of a `string-ascii` type ever holds
  any other byte.
- **UTF-8 string literals**: `u"..."` with the same escapes plus `\u{XXXX}` code
  point escapes.
- **Principal literals**: standard principals `'SP...` / `'ST...` (c32check
  encoded); contract principals `'SP....name` or the deployer-relative `.name`;
  trait identifiers `'SP....contract.trait`, `.contract.trait`, or a bare local
  trait `name` where a trait identifier is expected. A contract name is 1 to 40
  characters, starts with an ASCII letter, and continues with letters, digits,
  `-`, or `_`. The same limit applies wherever a contract name appears,
  including `principal-construct?`, `principal-destruct?`, and
  `principal-to-ascii` (3.5). There are no reserved or special-cased contract
  names (legacy admitted `__transient`).
- **Tuple literal syntax**: `{ name: expr, ... }`. This is the only tuple
  constructor syntax.
- **`none`** is the literal of type `(optional never)`.

Parentheses delimit lists; `{`, `}`, `:`, `,` are used only by tuple syntax.

**Keywords and reserved names.** Two kinds of identifier cannot be bound by a
contract:

- A **keyword** is an identifier whose meaning is fixed by the grammar. It is
  never a name of anything and cannot appear where a name is expected: the
  literals `true`, `false`, `none`; the heads of special forms (2.5) and
  definition forms (2.4.1); the allowance forms (2.5.9); the pattern and
  constructor heads `some`, `ok`, `err`, `list`; the type names and reference
  kinds of 2.3.1 and 2.3.6; and the `read-only` marker in trait definitions.
  Type names are keywords in value position too: `(let ((int u5)) ...)` is a
  static error.
- A **reserved name** is a definition that is in scope in every contract: every
  primitive ([03-primitives.md](03-primitives.md)) and every prelude definition
  (chapter 4). It behaves like a top-level definition of the contract itself and
  so cannot be rebound (2.5.2). Reserved names are fixed per language version,
  because the prelude is part of the language version.

## 2.3 Types

### 2.3.1 Type grammar

```
type      ::= int | uint | bool | principal | never
            | (buff size) | (string-ascii size) | (string-utf8 size)
            | (list size type)
            | (optional type)
            | (response type type)
            | { name: type, ... }              ;; tuple; zero or more fields
            | (trait trait-identifier)
            | alias-name                       ;; introduced by define-type
            | type-variable                    ;; see 2.3.4
            | contract-literal-type            ;; internal; see below

size      ::= uint-literal | size-variable | static-constant-name
```

Meaning of each type:

| Type               | Values                                                                                                                      |
| ------------------ | --------------------------------------------------------------------------------------------------------------------------- |
| `int`              | signed 128-bit integers                                                                                                     |
| `uint`             | unsigned 128-bit integers                                                                                                   |
| `bool`             | `true`, `false`                                                                                                             |
| `principal`        | standard or contract principals                                                                                             |
| `never`            | no values. The type of `return`, `panic`, and the "other side" of `ok`/`err`/`none`; it stays in a type that nothing widens |
| `(buff N)`         | byte sequences of length at most `N`                                                                                        |
| `(string-ascii N)` | strings of at most `N` bytes from the `string-ascii` character set (2.2)                                                    |
| `(string-utf8 N)`  | UTF-8 strings of at most `N` code points                                                                                    |
| `(list N T)`       | sequences of at most `N` values of type `T`                                                                                 |
| `(optional T)`     | `none` or `(some v)` with `v : T`                                                                                           |
| `(response T E)`   | `(ok v)` with `v : T` or `(err e)` with `e : E`                                                                             |
| `{ f: T, ... }`    | records with exactly the listed fields                                                                                      |
| `(trait X)`        | contract principals whose interface implements trait `X`                                                                    |
| contract literal   | the one contract principal named by a literal `'SP...123.c` or `.c`, or by a static constant holding one (2.4.1). Internal: it cannot be written in source, is never an interface or storable type, and exists so that a literal can be used wherever a trait type is expected (2.3.2) and as a `contract-call?` target (2.5.8) |

`(buff N)`, `(string-ascii N)`, `(string-utf8 N)`, and `(list N T)` are the four
**sequence types**. Their **element types** are `(buff 1)`, `(string-ascii 1)`,
`(string-utf8 1)`, and `T` respectively.

Every type has a statically known maximum serialized size (defined in the chain
ABI's wire format). Two limits (2.8) apply to it, depending on where the type
occurs:

- The **value size limit** applies to the type of every name (a `let` or `match`
  binding, or a parameter of a function that is not inline), every function
  result, every type written in source, and every value written to storage,
  emitted in an event, or passed to `contract-call?`.
- The **intermediate size limit** applies to the type of every other expression:
  a primitive's argument, a list or tuple under construction, or an inline
  function's argument before it is bound. Inline arguments are checked after
  expansion, at the position where they land.

A type that exceeds the limit for its position is a type error. So no value
larger than the value size limit can be bound, returned, or stored, and a value
that lives only during the evaluation of one expression is bounded by the
intermediate limit. `replace-at?`'s
`(concat (concat prefix (list item)) suffix)` has bound `2N + 1` before
`as-max-len?` brings it back to `N`, which fits the intermediate limit even when
`N` is near the value limit. Type nesting depth MUST NOT exceed the type depth
limit.

### 2.3.2 Subtyping

Subtyping formalizes what legacy Clarity calls "admission". It is the smallest
reflexive, transitive relation such that:

- `never <: T` for every `T`.
- `(buff N) <: (buff M)`, `(string-ascii N) <: (string-ascii M)`,
  `(string-utf8 N) <: (string-utf8 M)` when `N <= M`.
- `(list N S) <: (list M T)` when `N <= M` and `S <: T`.
- `(optional S) <: (optional T)` when `S <: T`.
- `(response S1 S2) <: (response T1 T2)` when `S1 <: T1` and `S2 <: T2`.
- `{ f1: S1, ... } <: { f1: T1, ... }` when both have exactly the same field
  names and `Si <: Ti` for every field.
- The contract literal type of `c` (2.3.1) `<: (trait X)` when the interface of
  `c` implements `X` (chain ABI trait rules), and `<: principal` always.
- `(trait X) <: (trait Y)` when every function required by `Y` is present in `X`
  with an identical signature (structural sub-trait).
- `(trait X) <: principal`.

`lub(S, T)` is defined pointwise by the same rules (taking the larger bound, the
lub of components, and so on) and is undefined when `S` and `T` have different
shapes (for example `int` and `uint`, or tuples with different field sets). An
undefined lub where one is required is a type error.

Among the principal-like types the join is always defined, and it is the most
specific type the rules above name, falling back to `principal`:

- `lub(S, S) = S`.
- `lub(S, (trait X)) = (trait X)` when `S <: (trait X)`; symmetrically for the
  other argument.
- Otherwise `lub(S, T) = principal`, including two different contract literals,
  two trait types neither of which is a sub-trait of the other, and anything
  with `principal`.

The join of two unrelated trait types is `principal` rather than an anonymous
trait of their common functions, because such a trait has no name, could not be
written in an interface, and would give a value a type no one declared. A list
of contract literals meant as trait values therefore states the trait once:
`(list (as (trait X) .a) .b .c)` has type `(list 3 (trait X))` when all three
implement `X`.

Because tuple subtyping requires identical field sets, every runtime tuple has
exactly the fields of its static type. There are no hidden fields, so no value
ever needs to be re-shaped ("sanitized") when it crosses a function or contract
boundary.

### 2.3.3 Storable types and interface types

A type is **storable** if it contains no trait type and no type or size
variable. Only storable types may appear in `define-data-var`, `define-map`,
`define-non-fungible-token`, and in `from-consensus-buff?`. A storable type may
contain `never`; such a position can hold no value, which is harmless.

Excluding trait types keeps every call target traceable to the transaction: a
trait-typed value can only come from a contract literal or a public function's
argument, so the contracts a transaction can reach are named in its payload or
in the code, never in chain state. A registry therefore stores principals and
has the caller name the target:

```
(define-map extensions uint principal)

(define-public (run (id uint) (ext (trait extension)))
  (begin
    (asserts! (is-eq (map-get? extensions id) (some ext)) (err u1))
    (contract-call? ext execute)))
```

`(trait extension) <: principal` (2.3.2), so the comparison needs no conversion.
The restriction is not needed for termination or cost bounds (a call through a
trait parameter already has a statically unknown callee). It is kept because
lifting it later is backward compatible and restoring it would not be.

A type is an **interface type** if it contains no type or size variable. Trait
types are allowed. Only interface types may appear in the parameter and result
types of public and read-only functions and in trait definitions.

An interface type may contain `never`. A public function whose body is
`(ok true)` has the result type `(response bool never)`, which states that the
function cannot return `err`. The chain ABI's type grammar includes `never`, and
boundary validation (2.5.8) admits no value for it. An author who wants a wider
type in the interface states it with `as` (2.5.10):
`(as (response bool uint) (ok true))`.

### 2.3.4 Type variables and size variables

An identifier in type position that is not a built-in type name, a `define-type`
alias, or a trait identifier denotes a **type variable**. An identifier in size
position that is not a literal denotes a **size variable**. Both are implicitly
universally quantified over the definition in which they appear, and each MUST
occur in at least one parameter type of that definition.

Type and size variables may appear only in `define-private` and `define-inline`
definitions. Public and read-only functions, traits, storage definitions, and
constants are monomorphic.

> [!NOTE] Size arithmetic (`N + M`, `N + 1`, `K × M`) appears only in primitive
> signatures in [03-primitives.md](03-primitives.md). Contract authors never
> write it, because function result types are inferred, not declared.

A **static constant** (2.4.1) of type `uint` may be used as a size, and a static
constant of contract principal type may be used wherever a contract principal
literal is required.

### 2.3.5 Type aliases

`(define-type name type)` introduces a transparent alias. The alias is
interchangeable with its definition everywhere. Aliases may not be recursive
(2.4.3) and may not contain type or size variables.

This form replaces legacy `use-trait`:
`(define-type sip010 (trait 'SP....sip-010-trait.sip-010-trait))`.

### 2.3.6 Static reference kinds

Some parameters do not hold runtime values but refer statically to a definition
in the current contract. These **reference kinds** are not types: they cannot
appear in `let` bindings, storage, interfaces, tuples, or sequences.

```
ref-kind  ::= (var type)
            | (map type type)
            | (fungible-token)
            | (non-fungible-token type)
            | (function (type ...) type)
```

An argument in a reference-kind position MUST be either the name of a definition
of the matching kind in the current contract, or a parameter of the same kind in
the enclosing function. References are resolved at instantiation time (2.6.2)
and have no runtime representation.

Reference kinds let one helper serve every map (or variable, or token) of a
given shape; each distinct reference is its own instance, so which storage a
function touches stays statically known. Reference kinds may appear only in
`define-private` and `define-inline` parameters. `(function ...)` arguments may
name any function defined in the current contract or the prelude except inline
functions, or any primitive that is not a special form.

## 2.4 Contracts and top-level forms

A contract is a version declaration followed by a sequence of top-level forms. A
definition may refer to any other definition in the contract, earlier or later,
as long as the definition graph is acyclic (2.4.3). Source order matters only
for code evaluated at deploy (2.4.2).

### 2.4.0 Version declaration

```
(clarity-version version)
```

The first form of every contract MUST be a version declaration naming the
language version the contract is written for. There is no default: a contract
without one is a syntax error, so a contract is never silently reinterpreted
under a later version's prelude or rules. A compiler MUST reject a contract
whose declared version it does not implement, and a compiler that implements
several versions uses the declared one for the whole contract. The declared
version is what the module's provenance section records as the language version
([../03-architecture.md](../03-architecture.md) section 2).

Nothing else in the language varies by version. The declaration selects one
complete specification, with its prelude and reserved names (2.2), for the whole
contract.

### 2.4.1 Definition forms

| Form                                                                                                                      | Introduces                                                                                                                                                                                                                                                                          | Rules                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| ------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `(define-constant name expr)`                                                                                             | A named value                                                                                                                                                                                                                                                                       | `expr` is deploy-time code (2.4.2), evaluated once; its type is inferred and MUST satisfy the value size limit (2.3.1). The type may contain `never`, so `(define-constant ERR-NOT-FOUND (err u404))` has type `(response never uint)` and is usable in any function whose error type is `uint`. If `expr` is a literal, or is built only from literals and other static constants using primitives that read neither state nor context (arithmetic, sequence, conversion, and hash primitives), the constant is **static**: its value is known at analysis time and it may be used wherever a literal is required (size terms, `contract-call?` targets, `as-max-len?` bounds) |
| `(define-type name type)`                                                                                                 | A type alias                                                                                                                                                                                                                                                                        | 2.3.5                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| `(define-data-var name type expr)`                                                                                        | A persistent variable                                                                                                                                                                                                                                                               | `type` storable; `expr : T <: type` is deploy-time code (2.4.2)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| `(define-map name key-type value-type)`                                                                                   | A persistent map                                                                                                                                                                                                                                                                    | both types storable                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| `(define-fungible-token name)` and `(define-fungible-token name expr)`                                                    | A fungible token, optionally with a total supply cap `expr : uint`                                                                                                                                                                                                                  |                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| `(define-non-fungible-token name type)`                                                                                   | A non-fungible token with identifier type `type`                                                                                                                                                                                                                                    | `type` storable                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| `(define-trait name ((fn-name (type ...) type) ...))` and `(define-trait name ((fn-name (type ...) type read-only) ...))` | A trait: a set of function names with interface-typed signatures whose result types are `response` types. A function marked `read-only` may only be implemented by a read-only function, and may be called through the trait from read-only code (2.7.4)                            |                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| `(impl-trait trait-identifier)`                                                                                           | A conformance claim, checked statically: every function in the trait MUST be defined as a public or read-only function with a compatible signature (parameters contravariant, result covariant), and a function the trait marks `read-only` MUST be defined with `define-read-only` |                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| `(define-public (name (param type) ...) expr ...)`                                                                        | An externally callable function                                                                                                                                                                                                                                                     | parameter types are interface types; result type MUST be a `response`; monomorphic                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| `(define-read-only (name (param type) ...) expr ...)`                                                                     | An externally callable function that MUST NOT mutate state (2.7.4)                                                                                                                                                                                                                  | parameter types are interface types; monomorphic                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| `(define-private (name (param type-or-ref-kind) ...) expr ...)`                                                           | An internal function called by value                                                                                                                                                                                                                                                | may be generic and overloaded, and may end with a rest parameter (2.6)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| `(define-inline (name (param type-or-ref-kind) ...) expr ...)`                                                            | An internal function expanded at each call site, with call-by-name parameters (2.6.3)                                                                                                                                                                                               | may be generic and overloaded                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |

Parameter names within one definition MUST be distinct (a duplicate is a static
error, not a runtime one). A function body is a non-empty sequence of
expressions evaluated in order; the value of the last is the value of the body.
Result types are inferred (2.6.4).

**Intermediate responses MUST be handled.** In any expression sequence (a
function body, a `let` or `begin` body, or a `match` arm), every expression
other than the last MUST NOT have a `response` type. A `response` is consumed by
returning it, matching on it, or passing it to a function; it cannot be dropped
(P7). This is a static error.

### 2.4.2 Top-level expressions

**Deploy-time code** is every `define-constant` initializer, `define-data-var`
initializer, `define-fungible-token` supply cap, and top-level form that is not
a definition. It is evaluated once, at deploy, in source order. Deploy-time code
is ordinary code: it may read and write state, call other contracts, and emit
events, subject only to the `return` restriction below.

**Definitions used at deploy must come first.** Deploy-time code MUST NOT use,
directly or through the definitions it calls (2.4.3), a definition that has an
initializer and appears later in the source: a constant that is not static
(2.4.1), a data variable, or a fungible token with a supply cap. This is a
static error. Every other kind of definition (functions, types, traits, maps,
tokens without a cap, and static constants) may be used from any position,
because nothing about it is evaluated at deploy: a static constant's value is
substituted at analysis time, so its position in the file is irrelevant.

The contract's own definitions, including its traits, are fully usable in
top-level expressions: a trait defined in the contract is resolved against the
contract's own analysis, not against a deployed copy of the contract, so
`(f .other-contract)` with `f` taking a locally defined trait type is valid at
the top level. `return` MUST NOT appear in a top-level expression, so the
early-exit library functions (`unwrap!`, `try!`, `asserts!`, `unwrap-err!`),
which expand to `return`, are unusable in top-level expressions and in
`define-constant` and `define-data-var` initializers; `unwrap-panic` and `match`
serve there. A runtime error in any top-level expression aborts the deploy.

### 2.4.3 The definition graph is acyclic

Definition `a` depends on `b` if the body, type, or initializer of `a` mentions
the name `b` anywhere: in call position, in type position, or as a reference
argument. The dependency graph over all definition names in a contract MUST be
acyclic. This single rule excludes recursion (direct, mutual, and through
function references), recursive types, and recursive constants.

The graph is over names, not instances, and is computed from the source alone,
before overload resolution and instantiation (2.6.2). All definitions of an
overloaded name are one node, so one overload of a name MUST NOT use another;
the shared part lives in a helper, as the prelude's `std-sqrti-uint` does for
the two `sqrti` overloads. Because the graph is acyclic before instantiation
begins, every chain of instantiations and inline expansions is finite (P1), and
the deploy-order check of 2.4.2 can be made on the source.

### 2.4.4 Contract interface

The compiler emits the contract's interface into its module in the chain ABI's
interface format: its public and read-only functions with their signatures and
read-only marks, its implemented traits, its defined traits, and its token
definitions. The chain validates the interface against the module at deploy.
Other contracts, whatever their source language, compile calls against this
interface only, and the chain validates every call against it at runtime
(2.5.8).

### 2.4.5 Standard library names

The standard library prelude ([std/prelude.clar](std/prelude.clar)) is in scope
in every contract as if it were part of the contract's own top-level forms. A
contract MUST NOT define a top-level name that the prelude defines.

## 2.5 Expression forms

Beyond literals, names, and function application, the core has the following
special forms. Anything not listed here is either a primitive
([03-primitives.md](03-primitives.md)) or a library definition.

### 2.5.1 Names

A bare identifier denotes a `let`- or `match`-bound variable, a function
parameter, or a `define-constant`; because there is no shadowing (2.5.2), at
most one of these applies at any point. Function, map, variable, and token names
are not values and may appear only in application or reference-argument
position. There are no other bare names: the execution context is read with
`get-current-context` (3.9).

### 2.5.2 `let`

```
(let ((name expr) ...) body-expr ...)
```

Bindings are evaluated left to right; each binding is in scope for the following
bindings and the body. The type is the type of the last body expression.

**No shadowing.** A `let` binding, a `match` binding, or a function parameter
MUST NOT reuse a name that is already in scope: a local, a parameter, a
top-level definition of the contract, or a reserved name (2.2). A keyword (2.2)
cannot be bound at all. Every name therefore has exactly one meaning at each
point in the program, and the type checker and the evaluator cannot disagree
about which one applies.

Legacy is equally strict about locals, top-level definitions, and builtin names.
Legacy source that uses a name reserved only in vNEXT (such as `max`, `min`,
`abs`, or `fold-left`) or a keyword new in vNEXT (such as `as`) as a local must
rename it when ported.

`(begin expr ...)` is sugar for `(let () expr ...)`.

### 2.5.3 `match`, `and`, `or`

```
(match expr arm arm)
arm     ::= (pattern body-expr ...)
pattern ::= (some name) | none | (ok name) | (err name) | true | false
```

`match` is the core's branching construct. The scrutinee type determines the
required patterns, each of which MUST appear exactly once:

| Scrutinee type   | Required patterns   | Bindings         |
| ---------------- | ------------------- | ---------------- |
| `(optional T)`   | `(some x)`, `none`  | `x : T`          |
| `(response T E)` | `(ok x)`, `(err e)` | `x : T`, `e : E` |
| `bool`           | `true`, `false`     | none             |

The type of the `match` is the lub of the arm types. Exactly one arm is
evaluated.

`if` is a library function defined over `match` on `bool`.

```
(and expr expr ...)
(or expr expr ...)
```

`and` and `or` take two or more `bool` expressions and evaluate them left to
right, stopping at the first `false` (`and`) or the first `true` (`or`). They
are core forms, not library functions, because short-circuiting over any number
of arguments cannot be written in the language: an inline function has a fixed
number of by-name parameters, and a rest parameter (2.6.5) is a list value whose
elements are all evaluated before the body runs. `(and a b c)` means exactly
`(match a (true (match b (true c) (false false))) (false false))`.

### 2.5.4 `return`

```
(return expr)
```

Evaluates `expr`, then terminates the innermost enclosing function body (after
inline expansion, 2.6.3) with that value. `return` has type `never`. The type of
`expr` contributes to the enclosing function's inferred result type (2.6.4).
`return` MUST NOT appear in a top-level expression.

When a `return` crosses an `as-contract?` or `restrict-assets?` boundary, the
rules in 2.5.8 apply.

`unwrap!`, `try!`, `asserts!`, and the rest of the early-exit family are library
functions defined over `match` and `return`.

### 2.5.5 Application

```
(f arg ...)
```

`f` is a primitive, a function defined in the current contract or the prelude,
or a `(function ...)` parameter. Arguments are evaluated left to right (except
for inline functions, 2.6.3). Typing and overload resolution are defined in
2.6.2.

### 2.5.6 Constructors

`(some e)`, `(ok e)`, `(err e)`, `(list e ...)`, and `{ f: e, ... }` construct
values.

| Form                    | Type                                                      |
| ----------------------- | --------------------------------------------------------- |
| `(some e)` with `e : T` | `(optional T)`                                            |
| `(ok e)` with `e : T`   | `(response T never)`                                      |
| `(err e)` with `e : E`  | `(response never E)`                                      |
| `(list e1 ... en)`      | `(list n lub(T1, ..., Tn))`; `(list)` is `(list 0 never)` |
| `{ f1: e1, ... }`       | `{ f1: T1, ... }`; field names MUST be distinct           |

`list`, `and`, and `or` are the only variadic forms. Functions take a variable
number of arguments only through a rest parameter (2.6.5).

### 2.5.7 Tuple access

- `(get f e)` with `e : { f: T, ... }` has type `T`. `f` MUST be a field of the
  tuple type.
- `(merge e1 e2)` with tuple types `R1`, `R2` has the tuple type whose fields
  are the union of both, taking the type from `R2` for fields present in both.
  At runtime, fields of `e2` overwrite fields of `e1`.

### 2.5.8 Cross-contract calls

```
(contract-call? contract function-name arg ...)
```

`contract` is a contract principal literal, a static constant (2.4.1) of
contract principal type, or an expression of a trait type `(trait X)`; in the
trait case `function-name` MUST be a function of `X`. Any expression of trait
type is acceptable, including a tuple field or a `let`-bound name. Arguments are
type-checked against the callee's stored interface (literal case) or the trait
signature (trait case). In the literal case the callee's interface is therefore
an input to compilation, and the compiler records it in the module's provenance
([../03-architecture.md](../03-architecture.md) section 2). The result type is
the callee's declared result type. The callee MUST be a public or read-only
function and MUST NOT be in the current contract.

The call is dispatched by the chain, which enforces the depth limit and the
no-reentrancy rule (2.7.5). The callee may be written in any source language.
The chain validates the arguments against the callee's declared parameter types
and the result against its declared result type, and for a trait target checks
that the principal's interface implements the trait. A Clarity contract can
therefore rely on its parameter types whoever calls it.

### 2.5.9 Context scoping and asset allowances

```
(as-contract? (allowance ...) body-expr ...)
(restrict-assets? owner-expr (allowance ...) body-expr ...)

allowance ::= (with-stx amount)
            | (with-ft contract token-name amount)
            | (with-nft contract asset-name identifier-list)
            | (with-staking amount)
            | (with-pox)
            | (with-all-assets-unsafe)   ;; as-contract? only
```

Both forms evaluate their body in a nested state frame and, on completion,
compare the asset movements of a designated owner against the allowance list.

- `as-contract?` sets the context's `sender` and `caller` fields (3.9) to the
  current contract for the body; the designated owner is the current contract.
- `restrict-assets?` leaves the context unchanged; the designated owner is the
  value of `owner-expr : principal`.

Both have type `(response T uint)` where `T` is the body type. Outcome:

1. If the body completes normally and every movement of the owner's assets is
   covered by an allowance, the frame is committed and the value is
   `(ok body-value)`.
2. If any movement is not covered, the frame is rolled back and the value is
   `(err i)`, where `i` is the zero-based index in the allowance list of the
   violated allowance. The allowance comparison is host code
   ([../03-architecture.md](../03-architecture.md) section 4), so the chain ABI
   defines which index is reported when several allowances are violated or a
   movement matches no allowance at all.
3. If the body is exited by a `return` that crosses the form, the allowance
   check still runs. On violation, the frame is rolled back, the `return` is
   cancelled, and the form's value is `(err i)`. Otherwise the frame is
   committed and the `return` proceeds.
4. A runtime error in the body aborts the transaction as usual.

Allowance sub-forms are valid only in allowance position.
`(with-all-assets-unsafe)` is valid only in `as-contract?`; in
`restrict-assets?` it is a type error, since it would make the form a no-op. The
other allowances' arguments are ordinary expressions evaluated before the body.
The number of allowances is bounded (2.8).

### 2.5.10 Type ascription

```
(as type expr)
```

`type` is a type expression (2.3.1), and may use the type and size variables in
scope. `expr`'s type MUST be a subtype of `type` (2.3.2); the form has type
`type` and evaluates to the value of `expr`. `as` only widens: it never narrows,
converts, or checks anything at runtime. It exists to give an initial value the
type a fold needs (2.6.2), and to give a type error a place to point:
`(as (list 10 uint) (list))`, `(as (optional principal) none)`,
`(as (string-ascii N) "")`.

## 2.6 Functions

### 2.6.1 Visibility

| Kind               | Callable from other contracts | Callable internally | May mutate state | May be generic or overloaded | Evaluation                     |
| ------------------ | ----------------------------- | ------------------- | ---------------- | ---------------------------- | ------------------------------ |
| `define-public`    | yes                           | yes                 | yes              | no                           | by value                       |
| `define-read-only` | yes                           | yes                 | no               | no                           | by value                       |
| `define-private`   | no                            | yes                 | yes              | yes                          | by value                       |
| `define-inline`    | no                            | yes                 | yes              | yes                          | expanded at call site, by name |

A public function called from another contract, or as the entry point of a
transaction, has the rollback semantics of 2.7.3. Public functions called
internally behave like private functions.

### 2.6.2 Instantiation and overload resolution

Let a call be `(f a1 ... an)`, and let the candidate definitions of `f` be those
that accept `n` arguments: exactly `n` parameters, or, for a rest-parameter
definition, fewer than `n` fixed parameters (2.6.5). A call whose last argument
is a spread `e...` is accepted only by rest-parameter definitions with exactly
`n - 1` fixed parameters. For a candidate with parameter types `P1 ... Pn`
(which may contain type variables, size variables, and reference kinds) and free
variables `X`, an **instantiation** is a substitution `σ` over `X` such that:

- for each value parameter, `type(ai) <: Pi[σ]`;
- for each reference-kind parameter, `ai` is a name (or reference parameter) of
  the matching kind whose declared types match `Pi[σ]`; for
  `(function (Q ...) R)`, the named function MUST itself admit an instantiation
  whose parameter types are supertypes of `Q[σ]...` and whose result type is a
  subtype of `R[σ]`. A rest-parameter definition with `k` fixed parameters is
  named at a function type with `k + 1` parameters, and the last one fills its
  rest parameter as a one-element list (2.6.5).

The candidate **admits** the call if an instantiation exists. Among the
instantiations that exist, the **least** one (pointwise under `<:`, and smallest
size values) is chosen; if no least instantiation exists the candidate does not
admit the call. This is the declarative form of the familiar "unify and take the
least upper bound" algorithm.

When a type variable occurs in both a parameter and the result of a
`(function ...)` parameter, as the accumulator `A` does in `fold-left`, the
least instantiation is a least fixpoint rather than a unification: the initial
value's type is a lower bound for `A`, and the named function's result type at
that `A` is another, so `A` is the least type closed under both. The prelude
relies on this: `(fold-left std-prepend-byte 0x bytes)` starts from `(buff 0)`
and settles at `(buff 16)`, and `index-of?` starts from `none` and settles at
`(optional uint)`. Every type in the language has finitely many supertypes below
the size limit, so the iteration terminates, but a step function that grows its
accumulator would take as many steps as the size limit allows before failing.
The iteration is therefore capped: starting from `A0`, the initial value's type,
each step computes `A(i+1) = lub(A(i), R(A(i)))`, where `R` is the named
function's result type, and if `A(i+1) = A(i)` is not reached within the
fixpoint step limit (2.8), the candidate does not admit the call. Every prelude
fold closes in two steps. A fold that needs a wider starting type states it with
`as` (2.5.10): `(fold-left f (as (list 10 uint) (list)) xs)`.

Overload resolution: exactly one candidate MUST admit the call. Zero is a type
error; more than one is an ambiguity error. Overloading is by arity and by
parameter types; there is no ranking. Because `never <: T` for every `T`, an
argument of type `never` is admitted by every candidate, so
`(unwrap! (panic) e)` is an ambiguity error; the call could not complete anyway.

The result type of the call is the candidate's inferred result type under `σ`,
with size arithmetic in primitive signatures evaluated on the concrete sizes. A
resulting size that exceeds the limit for the call's position (2.3.1) is a type
error.

Each distinct `(candidate, σ, reference arguments)` triple is a distinct
**instance**. Instances are what the compiler operates on; the definition graph
(2.4.3) is over names and is checked before any instance exists. Instance bodies
are type-checked with the concrete substitution applied ("template" semantics):
a generic body that is never instantiated is parsed and scope-checked but not
type-checked.

A type error found while checking an instance body is reported at the call site
that created the instance. The report MUST name the called definition and the
instantiation (for example, `max` at `bool`), and MAY include the location
inside the body as secondary information. When the instance was created from
inside another instance body, the report MUST include the chain of call sites
back to the user's code.

Template semantics give functions over "any tuple with these fields" without a
separate construct:

```
(define-private (credit (acct T) (amt uint))
  (merge acct { balance: (+ (get balance acct) amt) }))
```

`credit` admits any tuple with a `uint` field `balance` and returns a tuple of
the same shape. Each tuple shape is its own instance, so no value carries fields
its static type lacks (2.3.2). A call with a tuple that has no `balance` field
is reported as `credit` at that tuple type, at the call site.

### 2.6.3 Inline functions

An inline function is expanded at each call site:

1. The body is type-checked at the call site with parameters bound to the
   argument expressions' types (2.6.2).
2. Evaluation of the call is evaluation of the body with each parameter
   reference replaced by its argument expression, evaluated in the caller's
   context at the point of reference (call by name). An argument whose parameter
   is never referenced on the taken path is not evaluated. Because evaluation
   happens at the point of reference, an argument referenced inside an
   `as-contract?` or `restrict-assets?` form in the body is evaluated inside
   that frame, with the frame's `sender` and `caller`, and the order
   in which arguments are evaluated is the order of their references in the
   body, not their order at the call site. Prelude inline functions reference
   their parameters outside any such frame. Prelude functions whose names read
   as ordinary calls (`default-to`, `map-insert?`) are private, so their
   arguments are evaluated eagerly as in legacy; laziness is confined to
   control-flow forms, and the library documents each place where it changes
   legacy behavior (`unwrap!`, `unwrap-err!`).
3. Names bound inside the body (`let`, `match`) are fresh and cannot capture
   names in argument expressions. Free names in the body resolve in the defining
   contract's top-level scope.
4. `return` inside the body returns from the caller's innermost enclosing
   function body, not from the inline function.

To make call by name safe, each **value** parameter of an inline function MUST
be referenced at most once in the body (syntactically). A body that needs a
parameter twice binds it with `let` first. Reference-kind parameters have no
evaluation and may be referenced any number of times.

Inline functions cannot be passed as `(function ...)` arguments. Inline
expansion is finite because the definition graph is acyclic (2.4.3).

> [!NOTE] **When to use `define-inline`.** An inline function is the only way to
> write a helper that returns from its caller or evaluates an argument only on
> some paths. Use it for exactly those two cases, and use `define-private` for
> everything else. For example, a helper that replaces an error code and exits
> in one step cannot be private:
>
> ```
> (define-inline (try-with! (value (response T E)) (code F))
>   (match value
>     ((ok inner) inner)
>     ((err ignored) (return (err code)))))
>
> (define-public (withdraw (amount uint))
>   (let ((balance (try-with! (get-balance (get sender (get-current-context)))
>                             ERR-NO-ACCOUNT)))
>     ...))
> ```
>
> A private function is the better default because it behaves like every other
> call: each argument is evaluated exactly once, left to right, before the body
> runs. It can be passed to `map`, `filter`, and the folds. It is compiled once
> per instance instead of once per call site. Its body may use a parameter any
> number of times.
>
> An inline function gives those up. At a call site, an argument whose parameter
> is not used on the path taken is never evaluated, so its side effects (a
> `contract-call?`, a `var-set`, an abort) do not happen. Arguments are
> evaluated in the order the body uses them, not the order they are written. An
> argument used inside an `as-contract?` or `restrict-assets?` form in the body
> sees that frame's `sender`. A function whose name reads as an ordinary call
> should not be inline unless its documentation states which arguments may go
> unevaluated.

### 2.6.4 Result type inference

The result type of a function instance is the lub of the type of its last body
expression and the types of the operands of every `return` reachable in its body
(after inline expansion). If the lub is undefined, it is a type error. For
`define-public`, the result type MUST be a `response` type.

The result type is not declared, and may contain `never` (2.3.3). A function
with no `err` path has an error type of `never`; a function with no `ok` path
has a value type of `never`. Either is a valid interface type and is what the
compiler emits in the module's interface (2.4.4).

### 2.6.5 Rest parameters

The last parameter of a `define-private` definition MAY be a **rest parameter**,
written with `...` after its type:

```
(define-private (name (param type) ... (rest T...)) expr ...)
```

A call supplies the fixed parameters in order and **one or more** further
arguments for the rest parameter. Insides the body, the rest parameter is a
list: `rest : (list N T)`, where `N` is the number of rest arguments at that
call site. The call `(name a1 ... ak b1 ... bm)` is the call of the definition
with `a1 ... ak` for the fixed parameters and `(list b1 ... bm)` for the rest,
so arguments are evaluated left to right and the list is typed by 2.5.6. Each
call site is its own instance (2.6.2), with `N` bound to `m`.

A function that takes "two or more" is one definition. Its binary case is simply
the call with one rest argument:

```
(define-private (std-max-pair (left T) (right T))
  (if (> left right) left right))

(define-private (max (left T) (right T...))
  (fold-left std-max-pair left right))

;; (max a b)     is (fold-left std-max-pair a (list b))
;; (max a b c d) is (fold-left std-max-pair a (list b c d))
;; (max a)       is an arity error: a rest parameter needs an argument
```

`fold-left` passes the accumulator first (3.3), so this pattern is the left fold
of the helper whether or not the helper is commutative.

An argument that is already a list is not spread implicitly: in `(max a xs)`
with `xs : (list 5 int)`, `xs` is a single rest argument, so
`right : (list 1 (list 5 int))` and the body fails to type-check. To pass an
existing list as the rest parameter, **spread** it by writing `...` after the
argument:

```
(max a xs...)                              ;; right is xs
(concat "0x" (map std-hex-byte bytes)...)  ;; one string from many
```

A spread argument `e...` with `e : (list N T)` MUST be the only argument in the
rest position: the call supplies the fixed parameters and then `e...`, with no
other rest arguments. The rest parameter is the value of `e`, typed
`(list N T)`, and the instance binds `N` to that bound. `e` is evaluated once,
in its position, like any other argument. Unlike a call without a spread, the
rest list's runtime length may be less than `N`, including zero, so
`(max a (list)...)` is `a`. Only a rest parameter admits a spread argument: a
definition with a fixed parameter in that position does not accept the call.
Spread is not available for special forms (`and`, `or`, `let`, `match`).

Rules:

- **All fixed or all rest.** If any definition of a name has a rest parameter,
  every definition of that name MUST have one, with the same number of fixed
  parameters. Overloads then differ only by type, and overload resolution needs
  no rule about arity.
- **Passing a rest function.** A rest-parameter function may be passed as a
  `(function ...)` argument at the type with one more parameter than its fixed
  parameters; the last argument becomes a one-element rest list (2.6.2). So
  `(fold-left max 0 xs)` and `(fold-left + 0 xs)` work.
- **No self-reference.** A rest-parameter body cannot fold itself, since that is
  a cycle (2.4.3). The binary operation lives in a helper, as `std-max-pair`
  above, or in a primitive.
- **Private only.** Public and read-only functions MUST NOT have rest
  parameters, because their interface has a fixed arity in the chain ABI. Inline
  functions MUST NOT have them either: rest arguments are evaluated as a list
  before the body runs, which would silently make an inline function strict in
  those arguments.
- **Primitives** whose chapter 3 signature ends in `I...` or `S...` follow the
  same rules, including spread. Their result type may be tighter than a user
  definition could state; `concat`'s bound, for example, is the exact sum of its
  arguments' bounds, or `N + K × M` when a `(list K S[M])` is spread after a
  first argument of bound `N`.

A compiler instantiates each call site with its own `N`, so it can compile the
one-argument case of a rest function without building a list. The spec does not
require it.

`is-eq` and the comparisons have no rest parameter: `(is-eq a b c)` has no
single obvious meaning, and "all equal" is `(and (is-eq a b) (is-eq a c))`.

## 2.7 Dynamic semantics

### 2.7.1 Evaluation

Evaluation is strict and left to right, except that inline parameters are
evaluated by name (2.6.3) and `match` evaluates exactly one arm. Every
expression evaluates to a value of its static type or aborts. A runtime value
carries no static type information of its own; its size and shape are determined
entirely by the value, and a value passed to a callee is exactly the value the
caller computed.

### 2.7.2 Runtime errors

A runtime error (arithmetic overflow, division by zero, failed conversion,
`panic`, cost or memory limit exceeded, and the other conditions listed per
primitive) aborts the entire transaction. There is no mechanism to catch a
runtime error. All state changes of the transaction are discarded; the
transaction still pays for the cost it consumed.

### 2.7.3 Public function results and rollback

When a public function is invoked from another contract or as a transaction
entry point, its state changes (variables, maps, token balances, events) are
buffered. If it returns `(ok v)`, they are committed to the caller's frame. If
it returns `(err e)`, they are discarded and `(err e)` is returned to the
caller, which continues executing. A `return` of an `err` value has the same
effect as evaluating to it. The chain performs the commit or discard based on
the returned value, so the rule holds for calls between modules of any source
language.

### 2.7.4 Read-only enforcement

A read-only function MUST NOT, directly or through functions in the same
contract, execute `var-set`, `map-set`, `map-delete`, any `*-mint?`, `*-burn?`,
or `*-transfer?` primitive. A `contract-call?` from read-only code is permitted
only when the callee is statically known to be read-only: a literal or static
constant target whose interface marks the function read-only, or a trait target
whose trait marks the function `read-only`. All of this is checked at compile
time, so a violation is reported before deploy. The chain independently rejects
any write attempted inside a read-only call frame, which is what makes the
guarantee hold when read-only code calls a module from another language.

### 2.7.5 Depth and reentrancy

The chain rejects a `contract-call?` into a contract that already has an active
call frame in the current transaction, and rejects any call that would exceed
the call depth limit. Both are runtime errors.

### 2.7.6 Events

`print` and every asset primitive emit events into the transaction's event
batch. Events of a rolled-back frame are discarded with it.

### 2.7.7 Cost

The language defines no costs (P4). A contract runs as the Wasm module its
source compiles to, and its execution cost is the fuel that module consumes plus
the chain's charges for the host functions it calls. Library functions are
compiled and metered like any other code. Exceeding the transaction or block
budget is a runtime error.

Fuel replaces a per-construct runtime cost table. It does not replace the
chain's storage dimensions: reads and writes are still counted and sized, with
the budget dimensions defined in the chain ABI.

The following rules are about resource safety, not pricing, and bind every
compiler:

- Memory for a decoded value is reserved against the size bound of its result
  type before decoding begins. `from-consensus-buff?` reserves
  `serialized-size(T)`, so a hostile input cannot allocate more than its
  declared type admits.
- A trait-typed value is a principal and is sized as one.
- Compilation happens off chain, so its cost is the deployer's. What the chain
  charges for is the module: its size and its validation at deploy, as defined
  by the chain ABI.

## 2.8 Limits

These are language-level limits. Hosts MAY impose stricter limits on contract
source size and transaction budgets.

| Limit                                                      | Value           | Inherited from                                                  |
| ---------------------------------------------------------- | --------------- | --------------------------------------------------------------- |
| Maximum serialized value size                              | 1,048,576 bytes | `MAX_VALUE_SIZE`                                                |
| Maximum intermediate value size (2.3.1)                    | 8,388,608 bytes | new, provisional; MUST stay below the chain's Wasm memory limit |
| Fixpoint step limit for fold accumulators (2.6.2)          | 8               | new, provisional                                                |
| Maximum type nesting depth                                 | 32              | `MAX_TYPE_DEPTH`                                                |
| Maximum identifier length                                  | 128 bytes       | `MAX_STRING_LEN`; string literals are bounded only by the value size limit, as every other value is |
| Maximum call depth (functions and contract calls)          | 128             | `MAX_CALL_STACK_DEPTH`                                          |
| Maximum allowances per `as-contract?` / `restrict-assets?` | 128             | `MAX_ALLOWANCES`                                                |

There is no limit on the size of a contract after inline expansion and
instantiation, which can grow exponentially (definitions that each call the next
twice, or instantiate it at two types). The only limit is the chain's limit on
module size. A compiler MUST report a contract whose module would exceed it as a
compile error, and SHOULD stop expanding as soon as the limit is passed. A
language-level cap would not make validity compiler-independent, since near the
limit whether a contract fits already depends on code generation (P5).
