# 2. Core Language

This chapter defines the vNEXT core: lexical structure, types, top-level
forms, expression forms, functions, and dynamic semantics. Primitive
operations are enumerated in [03-primitives.md](03-primitives.md); everything
else a contract author uses is defined in the standard library
([04-standard-library.md](04-standard-library.md)).

The presentation here is semi-formal. Typing rules are given as prose with
signatures. The formal judgment-style rules and the full EBNF are follow-up
work once the design questions at the end of this chapter are settled.

## 2.1 Notation

- `name : (A B) -> R` is a signature: `name` takes an `A` and a `B` and
  produces an `R`.
- `T`, `E`, `K`, `V`, `A`, `U` are type variables. `N`, `M` are size
  variables (natural numbers bounding sequence lengths).
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
  (`u42`); `int` literals are optional `-` followed by decimal digits
  (`42`, `-7`). Values outside the 128-bit range are a parse error.
- **Boolean literals**: `true`, `false`.
- **Buffer literals**: `0x` followed by an even number of hex digits
  (`0x`, `0xdeadbeef`).
- **ASCII string literals**: `"..."` with escapes `\\`, `\"`, `\n`, `\t`,
  `\r`. Only printable ASCII is allowed.
- **UTF-8 string literals**: `u"..."` with the same escapes plus
  `\u{XXXX}` code point escapes.
- **Principal literals**: standard principals `'SP...` / `'ST...` (c32check
  encoded); contract principals `'SP....name` or the deployer-relative
  `.name`; trait identifiers `'SP....contract.trait`, `.contract.trait`, or
  a bare local trait `name` where a trait identifier is expected. A contract
  name is 1 to 40 characters, starts with an ASCII letter, and continues with
  letters, digits, `-`, or `_`. There are no reserved or special-cased
  contract names (legacy admitted `__transient`).
- **Tuple literal syntax**: `{ name: expr, ... }`. This is the only tuple
  constructor syntax.
- **`none`** is the literal of type `(optional never)`.

Parentheses delimit lists; `{`, `}`, `:`, `,` are used only by tuple syntax.

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

size      ::= uint-literal | size-variable | static-constant-name
```

Meaning of each type:

| Type | Values |
|---|---|
| `int` | signed 128-bit integers |
| `uint` | unsigned 128-bit integers |
| `bool` | `true`, `false` |
| `principal` | standard or contract principals |
| `never` | no values. The type of `return`, `panic`, and the "other side" of `ok`/`err`/`none` before it is known |
| `(buff N)` | byte sequences of length at most `N` |
| `(string-ascii N)` | printable-ASCII strings of at most `N` bytes |
| `(string-utf8 N)` | UTF-8 strings of at most `N` code points |
| `(list N T)` | sequences of at most `N` values of type `T` |
| `(optional T)` | `none` or `(some v)` with `v : T` |
| `(response T E)` | `(ok v)` with `v : T` or `(err e)` with `e : E` |
| `{ f: T, ... }` | records with exactly the listed fields |
| `(trait X)` | contract principals whose stored interface implements trait `X` |

`(buff N)`, `(string-ascii N)`, `(string-utf8 N)`, and `(list N T)` are the
four **sequence types**. Their **element types** are `(buff 1)`,
`(string-ascii 1)`, `(string-utf8 1)`, and `T` respectively.

Every type has a statically known maximum serialized size (defined in the
kernel wire-format chapter), and that size MUST NOT exceed the value size
limit (2.8). Type nesting depth MUST NOT exceed the type depth limit.

### 2.3.2 Subtyping

Subtyping formalizes what legacy Clarity calls "admission". It is the
smallest reflexive, transitive relation such that:

- `never <: T` for every `T`.
- `(buff N) <: (buff M)`, `(string-ascii N) <: (string-ascii M)`,
  `(string-utf8 N) <: (string-utf8 M)` when `N <= M`.
- `(list N S) <: (list M T)` when `N <= M` and `S <: T`.
- `(optional S) <: (optional T)` when `S <: T`.
- `(response S1 S2) <: (response T1 T2)` when `S1 <: T1` and `S2 <: T2`.
- `{ f1: S1, ... } <: { f1: T1, ... }` when both have exactly the same field
  names and `Si <: Ti` for every field.
- A contract principal literal type `'SP....c` (the singleton type of one
  contract principal literal) `<: (trait X)` when the stored interface of `c`
  implements `X` (kernel cross-version trait rules).
- `(trait X) <: (trait Y)` when every function required by `Y` is present in
  `X` with an identical signature (structural sub-trait).
- `(trait X) <: principal`.

`lub(S, T)` is defined pointwise by the same rules (taking the larger bound,
the lub of components, and so on) and is undefined when `S` and `T` have
different shapes (for example `int` and `uint`, or tuples with different
field sets). An undefined lub where one is required is a type error.

Because tuple subtyping requires identical field sets, every runtime tuple
has exactly the fields of its static type. There are no hidden fields, so
no value ever needs to be re-shaped ("sanitized") when it crosses a function
or contract boundary.

### 2.3.3 Storable types and interface types

A type is **storable** if it contains no `never`, no trait type, and no type
or size variable. Only storable types may appear in `define-data-var`,
`define-map`, `define-non-fungible-token`, and in `from-consensus-buff?`.

A type is an **interface type** if it contains no `never` and no type or size
variable. Trait types are allowed. Only interface types may appear in the
parameter and result types of public and read-only functions and in trait
definitions.

### 2.3.4 Type variables and size variables

An identifier in type position that is not a built-in type name, a
`define-type` alias, or a trait identifier denotes a **type variable**. An
identifier in size position that is not a literal denotes a **size
variable**. Both are implicitly universally quantified over the definition in
which they appear, and each MUST occur in at least one parameter type of
that definition.

Type and size variables may appear only in `define-private` and
`define-inline` definitions. Public and read-only functions, traits, storage
definitions, and constants are monomorphic.

> [!NOTE]
> Size arithmetic (`N + M`, `N + 1`) appears only in primitive signatures in
> [03-primitives.md](03-primitives.md). Contract authors never write it,
> because function result types are inferred, not declared.

A **static constant** (2.4.1) of type `uint` may be used as a size, and a
static constant of contract principal type may be used wherever a contract
principal literal is required.

### 2.3.5 Type aliases

`(define-type name type)` introduces a transparent alias. The alias is
interchangeable with its definition everywhere. Aliases may not be recursive
(2.4.3) and may not contain type or size variables.

This form replaces legacy `use-trait`: `(define-type sip010 (trait
'SP....sip-010-trait.sip-010-trait))`.

### 2.3.6 Static reference kinds

Some parameters do not hold runtime values but refer statically to a
definition in the current contract. These **reference kinds** are not types:
they cannot appear in `let` bindings, storage, interfaces, tuples, or
sequences.

```
ref-kind  ::= (var type)
            | (map type type)
            | (fungible-token)
            | (non-fungible-token type)
            | (function (type ...) type)
```

An argument in a reference-kind position MUST be either the name of a
definition of the matching kind in the current contract, or a parameter of
the same kind in the enclosing function. References are resolved at
instantiation time (2.6.2) and have no runtime representation.

Reference kinds may appear only in `define-private` and `define-inline`
parameters. `(function ...)` arguments may name any function defined in the
current contract except inline functions.

## 2.4 Contracts and top-level forms

A contract is a sequence of top-level forms. Definition order is irrelevant
except as stated in 2.4.2 and 2.4.3.

### 2.4.1 Definition forms

| Form | Introduces | Rules |
|---|---|---|
| `(define-constant name expr)` | A named value | `expr` is evaluated once at deploy time; it MUST have a storable type, MAY read chain data and context, and MUST NOT mutate state. If `expr` is a literal, or is built only from literals and other static constants using primitives that read neither state nor context (arithmetic, sequence, conversion, and hash primitives), the constant is **static**: its value is known at analysis time and it may be used wherever a literal is required (size terms, `contract-call?` targets, `as-max-len?` bounds) |
| `(define-type name type)` | A type alias | 2.3.5 |
| `(define-data-var name type expr)` | A persistent variable | `type` storable; `expr : T <: type`, evaluated at deploy |
| `(define-map name key-type value-type)` | A persistent map | both types storable |
| `(define-fungible-token name)` and `(define-fungible-token name expr)` | A fungible token, optionally with a total supply cap `expr : uint` | |
| `(define-non-fungible-token name type)` | A non-fungible token with identifier type `type` | `type` storable |
| `(define-trait name ((fn-name (type ...) type) ...))` and `(define-trait name ((fn-name (type ...) type read-only) ...))` | A trait: a set of function names with interface-typed signatures whose result types are `response` types. A function marked `read-only` may only be implemented by a read-only function, and may be called through the trait from read-only code (2.7.4) | |
| `(impl-trait trait-identifier)` | A conformance claim, checked statically: every function in the trait MUST be defined as a public or read-only function with a compatible signature (parameters contravariant, result covariant), and a function the trait marks `read-only` MUST be defined with `define-read-only` | |
| `(define-public (name (param type) ...) expr ...)` | An externally callable function | parameter types are interface types; result type MUST be a `response`; monomorphic |
| `(define-read-only (name (param type) ...) expr ...)` | An externally callable function that MUST NOT mutate state (2.7.4) | parameter types are interface types; monomorphic |
| `(define-private (name (param type-or-ref-kind) ...) expr ...)` | An internal function called by value | may be generic and may be overloaded (2.6) |
| `(define-inline (name (param type-or-ref-kind) ...) expr ...)` | An internal function expanded at each call site, with call-by-name parameters (2.6.3) | may be generic and may be overloaded |

Parameter names within one definition MUST be distinct (a duplicate is a
static error, not a runtime one). A function body is a non-empty sequence of
expressions evaluated in order; the value of the last is the value of the
body. Result types are inferred (2.6.4).

### 2.4.2 Top-level expressions

A top-level form that is not a definition is evaluated at deploy time in
source order, interleaved with `define-constant` and `define-data-var`
initializers in source order. The contract's own definitions, including its
traits, are fully usable in top-level expressions: a trait defined in the
contract is resolved against the contract's own analysis, not against a
deployed copy of the contract, so `(f .other-contract)` with `f` taking a
locally defined trait type is valid at the top level. `return` MUST NOT appear in a top-level
expression. A runtime error in any top-level expression aborts the deploy.

### 2.4.3 The definition graph is acyclic

Definition `a` depends on `b` if the body, type, or initializer of `a`
mentions `b` by name, or passes `b` as a reference argument. The dependency
graph over all definitions in a contract, computed after reference
resolution and instantiation (2.6.2), MUST be acyclic. This single rule
excludes recursion (direct, mutual, and through function references),
recursive types, and recursive constants.

### 2.4.4 Contract interface

The contract's stored interface (kernel format) lists its public and
read-only functions with their signatures, its implemented traits, its
defined traits, and its token and map definitions. Other contracts, of any
language version, type-check calls against this interface only.

### 2.4.5 Standard library names

The standard library prelude ([std/prelude.clar](std/prelude.clar)) is in
scope in every contract as if it were part of the contract's own top-level
forms. A contract MUST NOT define a top-level name that the prelude defines.

## 2.5 Expression forms

Beyond literals, names, and function application, the core has the following
special forms. Anything not listed here is either a primitive
([03-primitives.md](03-primitives.md)) or a library definition.

### 2.5.1 Names

A bare identifier denotes, in order of lookup: a `let`- or `match`-bound
variable, a function parameter, a `define-constant`, or a nullary primitive
(the context values `tx-sender`, `stacks-block-height`, and so on). Function,
map, variable, and token names are not values and may appear only in
application or reference-argument position.

### 2.5.2 `let`

```
(let ((name expr) ...) body-expr ...)
```

Bindings are evaluated left to right; each binding is in scope for the
following bindings and the body. The type is the type of the last body
expression.

**No shadowing.** A `let` binding, a `match` binding, or a function
parameter MUST NOT reuse a name that is already in scope, including the
names of top-level definitions, prelude definitions, and nullary
primitives. Every name therefore has exactly one meaning at each point in
the program, and the type checker and the evaluator cannot disagree about
which one applies.

`(begin expr ...)` is sugar for `(let () expr ...)`.

### 2.5.3 `match`

```
(match expr arm arm)
arm     ::= (pattern body-expr ...)
pattern ::= (some name) | none | (ok name) | (err name) | true | false
```

`match` is the only branching construct in the core. The scrutinee type
determines the required patterns, each of which MUST appear exactly once:

| Scrutinee type | Required patterns | Bindings |
|---|---|---|
| `(optional T)` | `(some x)`, `none` | `x : T` |
| `(response T E)` | `(ok x)`, `(err e)` | `x : T`, `e : E` |
| `bool` | `true`, `false` | none |

The type of the `match` is the lub of the arm types. Exactly one arm is
evaluated.

`if` is a library function defined over `match` on `bool`.

### 2.5.4 `return`

```
(return expr)
```

Evaluates `expr`, then terminates the innermost enclosing function body
(after inline expansion, 2.6.3) with that value. `return` has type `never`.
The type of `expr` contributes to the enclosing function's inferred result
type (2.6.4). `return` MUST NOT appear in a top-level expression.

When a `return` crosses an `as-contract?` or `restrict-assets?` boundary,
the rules in 2.5.8 apply.

`unwrap!`, `try!`, `asserts!`, and the rest of the early-exit family are
library functions defined over `match` and `return`.

### 2.5.5 Application

```
(f arg ...)
```

`f` is a primitive, a function defined in the current contract or the
prelude, or a `(function ...)` parameter. Arguments are evaluated left to
right (except for inline functions, 2.6.3). Typing and overload resolution
are defined in 2.6.2.

### 2.5.6 Constructors

`(some e)`, `(ok e)`, `(err e)`, `(list e ...)`, and `{ f: e, ... }`
construct values.

| Form | Type |
|---|---|
| `(some e)` with `e : T` | `(optional T)` |
| `(ok e)` with `e : T` | `(response T never)` |
| `(err e)` with `e : E` | `(response never E)` |
| `(list e1 ... en)` | `(list n lub(T1, ..., Tn))`; `(list)` is `(list 0 never)` |
| `{ f1: e1, ... }` | `{ f1: T1, ... }`; field names MUST be distinct |

`list` is the only variadic form in the language.

### 2.5.7 Tuple access

- `(get f e)` with `e : { f: T, ... }` has type `T`. `f` MUST be a field of
  the tuple type.
- `(merge e1 e2)` with tuple types `R1`, `R2` has the tuple type whose fields
  are the union of both, taking the type from `R2` for fields present in
  both. At runtime, fields of `e2` overwrite fields of `e1`.

### 2.5.8 Cross-contract calls

```
(contract-call? contract function-name arg ...)
```

`contract` is a contract principal literal, a static constant (2.4.1) of
contract principal type, or an expression of a trait type `(trait X)`; in
the trait case `function-name` MUST be a function of `X`. Any expression of
trait type is acceptable, including a tuple field or a `let`-bound name. Arguments are type-checked against the callee's stored
interface (literal case) or the trait signature (trait case). The result type
is the callee's declared result type. The callee MUST be a public or
read-only function and MUST NOT be in the current contract.

The call is dispatched by the kernel, which enforces the depth limit and the
no-reentrancy rule (2.7.5) and routes to the callee's engine, which may be a
different language version.

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

- `as-contract?` sets `tx-sender` and `contract-caller` to
  `current-contract` for the body; the designated owner is the current
  contract.
- `restrict-assets?` leaves the context unchanged; the designated owner is
  the value of `owner-expr : principal`.

Both have type `(response T uint)` where `T` is the body type. Outcome:

1. If the body completes normally and every movement of the owner's assets
   is covered by an allowance, the frame is committed and the value is
   `(ok body-value)`.
2. If any movement is not covered, the frame is rolled back and the value is
   `(err i)`, where `i` is the index of the first violated allowance
   (defined precisely in the cost and semantics chapters).
3. If the body is exited by a `return` that crosses the form, the allowance
   check still runs. On violation, the frame is rolled back, the `return`
   is cancelled, and the form's value is `(err i)`. Otherwise the frame is
   committed and the `return` proceeds.
4. A runtime error in the body aborts the transaction as usual.

Allowance sub-forms are valid only in allowance position.
`(with-all-assets-unsafe)` is valid only in `as-contract?`; in
`restrict-assets?` it is a type error, since it would make the form a no-op.
The other allowances' arguments are ordinary expressions evaluated before
the body. The number of allowances
is bounded (2.8).

## 2.6 Functions

### 2.6.1 Visibility

| Kind | Callable from other contracts | Callable internally | May mutate state | May be generic or overloaded | Evaluation |
|---|---|---|---|---|---|
| `define-public` | yes | yes | yes | no | by value |
| `define-read-only` | yes | yes | no | no | by value |
| `define-private` | no | yes | yes | yes | by value |
| `define-inline` | no | yes | yes | yes | expanded at call site, by name |

A public function called from another contract, or as the entry point of a
transaction, has the rollback semantics of 2.7.3. Public functions called
internally behave like private functions.

### 2.6.2 Instantiation and overload resolution

Let a call be `(f a1 ... an)`, and let the candidate definitions of `f` be
those with `n` parameters. For a candidate with parameter types
`P1 ... Pn` (which may contain type variables, size variables, and reference
kinds) and free variables `X`, an **instantiation** is a substitution `σ`
over `X` such that:

- for each value parameter, `type(ai) <: Pi[σ]`;
- for each reference-kind parameter, `ai` is a name (or reference parameter)
  of the matching kind whose declared types match `Pi[σ]`; for
  `(function (Q ...) R)`, the named function MUST itself admit an
  instantiation whose parameter types are supertypes of `Q[σ]...` and whose
  result type is a subtype of `R[σ]`.

The candidate **admits** the call if an instantiation exists. Among the
instantiations that exist, the **least** one (pointwise under `<:`, and
smallest size values) is chosen; if no least instantiation exists the
candidate does not admit the call. This is the declarative form of the
familiar "unify and take the least upper bound" algorithm.

Overload resolution: exactly one candidate MUST admit the call. Zero is a
type error; more than one is an ambiguity error. Overloading is by arity and
by parameter types; there is no ranking.

The result type of the call is the candidate's inferred result type under
`σ`, with size arithmetic in primitive signatures evaluated on the concrete
sizes. A resulting size that exceeds the value size limit is a type error.

Each distinct `(candidate, σ, reference arguments)` triple is a distinct
**instance**. Instances are what the cost model and the definition graph
(2.4.3) operate on. Instance bodies are type-checked with the concrete
substitution applied ("template" semantics): a generic body that is never
instantiated is parsed and scope-checked but not type-checked.

### 2.6.3 Inline functions

An inline function is expanded at each call site:

1. The body is type-checked at the call site with parameters bound to the
   argument expressions' types (2.6.2).
2. Evaluation of the call is evaluation of the body with each parameter
   reference replaced by its argument expression, evaluated in the caller's
   context at the point of reference (call by name). An argument whose
   parameter is never referenced on the taken path is not evaluated.
3. Names bound inside the body (`let`, `match`) are fresh and cannot capture
   names in argument expressions. Free names in the body resolve in the
   defining contract's top-level scope.
4. `return` inside the body returns from the caller's innermost enclosing
   function body, not from the inline function.

To make call by name safe, each **value** parameter of an inline function
MUST be referenced at most once in the body (syntactically). A body that
needs a parameter twice binds it with `let` first. Reference-kind parameters
have no evaluation and may be referenced any number of times.

Inline functions cannot be passed as `(function ...)` arguments. Inline
expansion is finite because the definition graph is acyclic (2.4.3).

### 2.6.4 Result type inference

The result type of a function instance is the lub of the type of its last
body expression and the types of the operands of every `return` reachable
in its body (after inline expansion). If the lub is undefined, it is a type
error. For `define-public`, the result type MUST be a `response` type.

## 2.7 Dynamic semantics

### 2.7.1 Evaluation

Evaluation is strict and left to right, except that inline parameters are
evaluated by name (2.6.3) and `match` evaluates exactly one arm. Every
expression evaluates to a value of its static type or aborts. A runtime
value carries no static type information of its own; its size and shape are
determined entirely by the value, and a value passed to a callee is exactly
the value the caller computed.

### 2.7.2 Runtime errors

A runtime error (arithmetic overflow, division by zero, failed conversion,
`panic`, cost or memory limit exceeded, and the other conditions listed per
primitive) aborts the entire transaction. There is no mechanism to catch a
runtime error. All state changes of the transaction are discarded; the
transaction still pays for the cost it consumed.

### 2.7.3 Public function results and rollback

When a public function is invoked from another contract or as a transaction
entry point, its state changes (variables, maps, token balances, events) are
buffered. If it returns `(ok v)`, they are committed to the caller's frame.
If it returns `(err e)`, they are discarded and `(err e)` is returned to the
caller, which continues executing. A `return` of an `err` value has the same
effect as evaluating to it.

### 2.7.4 Read-only enforcement

A read-only function MUST NOT, directly or through functions in the same
contract, execute `var-set`, `map-set`, `map-delete`, any `*-mint?`,
`*-burn?`, or `*-transfer?` primitive, or `as-contract?` /
`restrict-assets?`. A `contract-call?` from read-only code is permitted only
when the callee is statically known to be read-only: a literal or static
constant target whose stored interface marks the function read-only, or a
trait target whose trait marks the function `read-only`. All of this is
checked at analysis time; there is no runtime read-only check. The kernel
additionally rejects any write attempted inside a read-only call frame as a
defense in depth.

### 2.7.5 Depth and reentrancy

The kernel rejects a `contract-call?` into a contract that already has an
active call frame in the current transaction, and rejects any call that
would exceed the call depth limit. Both are runtime errors.

### 2.7.6 Events

`print` and every asset primitive emit events into the transaction's event
batch. Events of a rolled-back frame are discarded with it.

### 2.7.7 Cost

Every core form and primitive has an execution cost and a memory cost
defined in the cost chapter (not yet drafted). Library functions have none of
their own. Exceeding the transaction or block budget is a runtime error.

The cost chapter MUST respect these principles, each of which closes a
known legacy pricing bug:

- A primitive that copies or decodes data is charged on the size bound of
  its **output**, derived from its result type, not on the size of its
  input. `slice?` is priced by the slice, `from-consensus-buff?` by
  `serialized-size(T)` and the depth of `T`, and the memory for a decoded
  value is reserved against that bound before decoding begins.
- A trait-typed value is a principal and is sized as one.
- Analysis of a contract is metered on the **expanded, instantiated**
  program (after inline expansion and generic instantiation, 2.6), and the
  meter covers every step through persistence of the stored interface.
  Exceeding the analysis budget rejects the deploy.

## 2.8 Limits

These are language-level limits. Hosts MAY impose stricter limits on
contract source size and transaction budgets.

| Limit | Value | Inherited from |
|---|---|---|
| Maximum serialized value size | 1,048,576 bytes | `MAX_VALUE_SIZE` |
| Maximum type nesting depth | 32 | `MAX_TYPE_DEPTH` |
| Maximum identifier and string literal length | 128 bytes | `MAX_STRING_LEN` |
| Maximum call depth (functions and contract calls) | 128 | `MAX_CALL_STACK_DEPTH` |
| Maximum allowances per `as-contract?` / `restrict-assets?` | 128 | `MAX_ALLOWANCES` |

## 2.9 Open questions

Each item needs a decision (or an RFC where tagged) before this chapter is
frozen.

1. **Associative operators.** Fixed arity means `(+ a b c)` is gone. A
   syntactic rule "calls of `+`, `*`, `and`, `or`, `bit-and`, `bit-or`,
   `bit-xor`, `concat` with more than two arguments left-fold" is cheap but
   special-cases a list of names. Draft position: fixed arity; revisit after
   writing real contracts in vNEXT.
2. **Multi-sequence `map`.** Legacy `(map f l1 l2)` is dropped. A library
   version over `fold` and `element-at?` would carry tuple state per element
   and fail the layering rule's fourth test, so if it is wanted it returns as
   a primitive family (`map2`, `map3`). Draft position: dropped until there
   is demand.
3. **`bool` as unit.** `var-set`, `map-set`, and `ft-mint?`'s `(ok true)`
   return a `bool` that carries no information. A unit type would be cleaner
   but touches every public-function convention in the ecosystem. Draft
   position: keep `bool`.
4. **Inline functions as function references.** `(filter not xs)` requires
   `not` to be a real function today, so predicates in the prelude are
   `define-private`, which costs a call. Alternatives: allow references to
   inline functions whose parameters are each used exactly once (they are
   trivially eta-expandable), or let the cost model treat small private
   functions as inlined. Draft position: undecided.
5. **Template checking of generic bodies.** Bodies are checked per instance,
   so a type error in a generic body surfaces at its call sites. Bounded
   polymorphism (type classes) would move errors to the definition but is a
   large addition. Draft position: template semantics. The prelude's generic
   functions are now few and small, which lowers the stakes.
6. **Static reference kinds.** `(map K V)`, `(var T)`, and token references
   as parameters exist in this draft on their own merits (helpers over maps
   are a recurring pain point), and the prelude uses them only for
   `map-insert`. Decide whether they stay as a user feature; if they are
   dropped, `map-insert` becomes a primitive.
7. **Overloading.** Exists so `unwrap!`, `try!`, and `unwrap-panic` accept
   both `optional` and `response`. The alternative is distinct names. Draft
   position: keep overloading; it is one rule and the forms are the most
   used in the language.
8. **Shadowing.** No name may be shadowed (2.5.2). Confirm this is not too
   strict in practice, in particular for prelude names such as `max`.
9. **`to-ascii?`** is retained as a primitive because it cannot be written
   generically. Decide whether it earns its place.
10. **Trait-typed values in storage** remain forbidden (as legacy). Confirm.
11. **Expansion amplification.** Inline expansion and per-instance checking
    can produce an expanded program larger than the source. Metering
    analysis on the expanded program (2.7.7) makes this a cost rather than a
    resource exhaustion, and with the recalibrated library the prelude's own
    expansions are shallow, but a hard cap on expanded size or on inline
    nesting depth may still be wanted so that the failure is a clear
    diagnostic instead of a budget error. Decide the cap and where it lives.
12. **Candidate additions from the issue tracker** are collected in
    [05-issue-tracker.md](05-issue-tracker.md): Schnorr verification, `tx-fee`,
    wide-integer arithmetic, and per-definition contract introspection.
