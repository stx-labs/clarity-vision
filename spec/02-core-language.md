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
- `never` is the empty type (2.3.3).

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
  through 0x7E plus tab (0x09), line feed (0x0A), and carriage return (0x0D). A
  literal may contain only these characters, the three control characters only
  through their escapes, and no value of a `string-ascii` type ever holds any
  other byte.
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
  kinds of 2.3.1 and 2.3.7; and the `read-only` marker in trait definitions.
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
            | type-variable                    ;; see 2.3.5
            | contract-literal-type            ;; internal; see below

size      ::= uint-literal | size-variable | static-constant-name
```

Meaning of each type:

| Type               | Values                                                                                                                                                                                                                                                                                                                          |
| ------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `int`              | signed 128-bit integers                                                                                                                                                                                                                                                                                                         |
| `uint`             | unsigned 128-bit integers                                                                                                                                                                                                                                                                                                       |
| `bool`             | `true`, `false`                                                                                                                                                                                                                                                                                                                 |
| `principal`        | standard or contract principals                                                                                                                                                                                                                                                                                                 |
| `never`            | no values. The type of `return` and `panic`, and the side of `ok`, `err`, `none`, and `(list)` that no value reaches (2.3.3)                                                                                                                                                                                                    |
| `(buff N)`         | byte sequences of length at most `N`                                                                                                                                                                                                                                                                                            |
| `(string-ascii N)` | strings of at most `N` bytes from the `string-ascii` character set (2.2)                                                                                                                                                                                                                                                        |
| `(string-utf8 N)`  | UTF-8 strings of at most `N` code points                                                                                                                                                                                                                                                                                        |
| `(list N T)`       | sequences of at most `N` values of type `T`                                                                                                                                                                                                                                                                                     |
| `(optional T)`     | `none` or `(some v)` with `v : T`                                                                                                                                                                                                                                                                                               |
| `(response T E)`   | `(ok v)` with `v : T` or `(err e)` with `e : E`                                                                                                                                                                                                                                                                                 |
| `{ f: T, ... }`    | records with exactly the listed fields                                                                                                                                                                                                                                                                                          |
| `(trait X)`        | contract principals that conform to trait `X` (2.3.2); checked at compile time, not at runtime (2.5.8)                                                                                                                                                                                                                          |
| contract literal   | the one contract principal named by a literal `'SP...123.c` or `.c`, or by a static constant holding one (2.4.1). Internal: it cannot be written in source, is never an interface or storable type, and exists so that a literal can be used wherever a trait type is expected (2.3.2) and as a `contract-call?` target (2.5.8) |

`(buff N)`, `(string-ascii N)`, `(string-utf8 N)`, and `(list N T)` are the four
**sequence types**. Their **element types** are `(buff 1)`, `(string-ascii 1)`,
`(string-utf8 1)`, and `T` respectively.

Every type has a statically known maximum serialized size, `serialized-size` of
the interpretation layer
([../08-value-interpretation.md](../08-value-interpretation.md) section 4.1).
Two limits (2.8) apply to it, depending on where the type occurs:

- The **value size limit** applies to the type of every name (a `let` or `match`
  binding, or a parameter of a function, not of a macro), every function result,
  every type written in source, and every value written to storage, emitted in
  an event, or passed to `contract-call?`.
- The **intermediate size limit** applies to the type of every other expression:
  a primitive's argument, a list or tuple under construction, or a macro's
  argument before it is bound. Macro arguments are checked after expansion, at
  the position where they land.

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
- The contract literal type of `c` (2.3.1) `<: (trait X)` when `c` conforms to
  `X`: its declared signatures in `abi.types` (2.4.4) satisfy the rule of
  `impl-trait` (2.4.1), which is the interpretation layer's conformance rule
  ([../08-value-interpretation.md](../08-value-interpretation.md) section 5.2).
  It is `<: principal` always.
- `(trait X) <: (trait Y)` when every function required by `Y` is present in `X`
  with an identical signature (structural sub-trait).
- `(trait X) <: principal`.

Two distinct traits that require the same functions with the same signatures are
**equivalent**: each is a subtype of the other, but they remain distinct types,
named by different trait identifiers. A contract that declares its own copy of a
standard trait can therefore pass a value of its copy's type where the standard
trait is expected, and the reverse. Subtyping is thus a preorder on trait types
rather than a partial order.

`lub(S, T)` is defined pointwise by the same rules (taking the larger bound, the
lub of components, and so on) and is undefined when `S` and `T` have different
shapes (for example `int` and `uint`, or tuples with different field sets). An
undefined lub where one is required is a type error.

`lub(never, T) = T` for every `T`, since `never <: T`. This is how the empty
side of a constructor is filled in:
`lub((response int never), (response never uint))` is `(response int uint)`, and
`lub((list 0 never), (list 1 int))` is `(list 1 int)`.

Among the principal-like types the join is always defined, and it is the most
specific type the rules above name, falling back to `principal`:

- `lub(S, S) = S`.
- `lub(S, (trait X)) = (trait X)` when `S <: (trait X)` and `S` is not the type
  of a trait equivalent to `X`; symmetrically for the other argument.
- Otherwise `lub(S, T) = principal`, including two different contract literals,
  two trait types neither of which is a sub-trait of the other, two distinct
  equivalent trait types, and anything with `principal`.

Two distinct equivalent traits join to `principal`, as unrelated traits do,
because no single trait identifier is the answer. Either would be a least upper
bound, and choosing one would put an arbitrary trait identifier into the
contract interface (2.4.4). The author can state the intended trait with `as`
(2.5.10): with `x : (trait X)` and `y : (trait Y)`, `(list x (as (trait X) y))`
has type `(list 2 (trait X))`.

`lub(T1, ..., Tn)` is taken over the whole set, not as a pairwise fold. Among
principal-like types it is the member of the set that every other member is a
subtype of, and it is `principal` if no member qualifies or if two distinct
equivalent traits both qualify. Other types combine pointwise as above. A
pairwise fold would depend on the order of the arguments, because the fallback
to `principal` loses information: if trait `p` requires `f` and `g`, trait `q`
requires `f` and `h`, and trait `r` requires only `f`, then with
`x : (trait p)`, `y : (trait q)`, and `z : (trait r)`, folding `(list x y z)`
would give `lub(principal, (trait r)) = principal`, while folding `(list x z y)`
would give `(trait r)`. Over the whole set both have type `(list 3 (trait r))`.
Likewise, if traits `a` and `b` are equivalent and trait `c` requires a subset
of their functions, then with `x : (trait a)`, `y : (trait b)`, and
`z : (trait c)`, `(list x y)` has type `(list 2 principal)`, while
`(list x y z)` and `(list x z y)` both have type `(list 3 (trait c))`. As these
examples show, adding an element can make the inferred type more specific: the
common supertype of `p` and `q` that requires only `f` has no name unless some
member names it.

The join of two unrelated trait types is `principal` rather than an anonymous
trait of their common functions, because such a trait has no name, could not be
written in an interface, and would give a value a type no one declared. A list
of contract literals meant as trait values therefore states the trait once:
`(list (as (trait X) .a) .b .c)` has type `(list 3 (trait X))` when all three
implement `X`.

Two types **meet** when some type that does not mention `never` is a subtype of
both. Outside the principal-like types this is exactly the condition under which
`lub` is defined: types of the same shape meet, and types of different shapes do
not. Among the principal-like types, `principal` meets every one of them, a
contract literal meets itself and every trait it conforms to, two different
contract literals do not meet, and two trait types meet when no function is
required by both with different signatures, since a contract could then
implement both. Overloads of a name are required not to meet (2.6.2).

Because tuple subtyping requires identical field sets, every runtime tuple has
exactly the fields of its static type. There are no hidden fields, so no value
ever needs to be re-shaped ("sanitized") when it crosses a function or contract
boundary.

### 2.3.3 The `never` type

`never` is the type with no values, the bottom of the subtype order (2.3.2). It
arises in two ways:

- As the type of an expression that does not produce a value: `(return e)`
  (2.5.4), `(panic)` (3.10), and the forms built on them.
- As the side of a type that no value reaches: `(ok e)` has type
  `(response T never)`, `(err e)` has type `(response never E)`, `none` has type
  `(optional never)`, and `(list)` has type `(list 0 never)` (2.5.6). The lub
  fills in the other side when an `ok` meets an `err` (2.6.4) or a fold widens
  its accumulator (2.6.2), and `never` remains only where nothing ever flows. A
  function with no `err` path therefore has the result type
  `(response T never)`, which its interface declares (2.3.4, 2.6.4).

`never` may be written in source wherever a type may, and may appear in storable
and interface types (2.3.4). A position of type `never` holds nothing, which is
harmless, and argument and result validation (2.5.8) admits no value for it.

`never` has no typing rules of its own. It is a type like any other, with
`never <: T` for every `T` as its only distinction, and every rule of this
chapter applies to it unchanged:

- An expression of type `never` is admitted wherever a value of some type `T` is
  expected, by subtyping, and the enclosing form has the type its rule gives it:
  `(+ 1 (return u0))` has type `int`, `(some (panic))` has type
  `(optional never)`, and `(+ "a" (panic))` is a type error. A name bound at
  type `never` by `let`, `match`, or a parameter is an ordinary name of that
  type.
- A form that selects something by the type of an operand requires that operand
  to have a type of the shape it selects on, and `never` has no shape. A `match`
  scrutinee (2.5.3), an operand of `get` or `merge` (2.5.7), and a trait-typed
  `contract-call?` target (2.5.8) of type `never` are type errors.
- An argument of type `never` fits every candidate of an overloaded name, so a
  call that more than one candidate admits is an ambiguity error (2.6.2):
  `(unwrap! (panic) e)` is one. A candidate whose instantiation it leaves
  undetermined does not admit the call: `(len (panic))` fixes no sequence kind.
  The author states the intended type with `as` (2.5.10).
- A type variable may be instantiated at `never`, or at a type that mentions it,
  and the instance body is type-checked under that substitution like any other
  (2.6.2). An error in such a body is reported at the call site, as any instance
  error is, and `as` on the argument that fixed the variable resolves it. If
  `show` matches on a parameter of type `(optional T)` and calls the overloaded
  `int-to-ascii` on the payload, `(show none)` is an ambiguity error in the
  instance at `T = never`, and `(show (as (optional int) none))` is not.
- Every arm, binding, and body expression is type-checked, whether or not it can
  be reached. `(if (panic) 1 "hello")` is a type error because its arms have no
  lub, as it would be with any other condition. An arm whose binding has type
  `never` contributes its type to the `match` like any other arm (2.5.3), and a
  `return` whose operand has type `never` contributes `never` to the result type
  (2.6.4), which the lub absorbs.

**Unreachable code.** When an expression of type `never` is the initializer of a
`let` binding, an argument to a function that is not a macro, or a body
expression other than the last, the code that follows it cannot be reached. A
checker SHOULD warn at such an expression. An argument to a macro is exempt,
because it is evaluated only where the body references it (2.6.3):
`(asserts! ok (panic))` aborts only when `ok` is false. A checker SHOULD NOT
warn about an expression whose type is `never` only in some instance, such as
the payload of a generic function's `(some v)` arm when it is called with
`none`.

### 2.3.4 Storable types and interface types

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
types of public and read-only functions and in trait definitions. They are the
types the compiler declares in `abi.types` (2.4.4), and each is a type of the
interpretation layer's grammar
([../08-value-interpretation.md](../08-value-interpretation.md) section 2).

An interface type may contain `never`. A public function whose body is
`(ok true)` has the result type `(response bool never)`, which states that the
function cannot return `err`. The interpretation layer's grammar includes
`never`, and argument and result validation (2.5.8) admits no value for it. An
author who wants a wider type in the interface states it with `as` (2.5.10):
`(as (response bool uint) (ok true))`.

### 2.3.5 Type variables and size variables

An identifier in type position that is not a built-in type name, a `define-type`
alias, or a trait identifier denotes a **type variable**. An identifier in size
position that is not a literal denotes a **size variable**. Both are implicitly
universally quantified over the definition in which they appear, and each MUST
occur in at least one parameter type of that definition.

Type and size variables may appear only in `define-private` and `define-macro`
definitions. Public and read-only functions, traits, storage definitions, and
constants are monomorphic.

> [!NOTE] Size arithmetic (`N + M`, `N + 1`, `K × M`) appears only in primitive
> signatures in [03-primitives.md](03-primitives.md). Contract authors never
> write it, because function result types are inferred, not declared.

A **static constant** (2.4.1) of type `uint` may be used as a size, and a static
constant of contract principal type may be used wherever a contract principal
literal is required.

### 2.3.6 Type aliases

`(define-type name type)` introduces a transparent alias. The alias is
interchangeable with its definition everywhere. Aliases may not be recursive
(2.4.3) and may not contain type or size variables.

This form replaces legacy `use-trait`:
`(define-type sip010 (trait 'SP....sip-010-trait.sip-010-trait))`.

### 2.3.7 Static reference kinds

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
`define-private` and `define-macro` parameters. `(function ...)` arguments may
name any function defined in the current contract or the prelude, but not a
macro, or any primitive that is not a special form.

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
| `(define-type name type)`                                                                                                 | A type alias                                                                                                                                                                                                                                                                        | 2.3.6                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| `(define-data-var name type expr)`                                                                                        | A persistent variable                                                                                                                                                                                                                                                               | `type` storable; `expr : T <: type` is deploy-time code (2.4.2)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| `(define-map name key-type value-type)`                                                                                   | A persistent map                                                                                                                                                                                                                                                                    | both types storable; the key prefix plus `serialized-size(key-type)` MUST fit the storage key limit (2.8, 3.7)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| `(define-fungible-token name)` and `(define-fungible-token name expr)`                                                    | A fungible token, optionally with a total supply cap `expr : uint`                                                                                                                                                                                                                  |                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| `(define-non-fungible-token name type)`                                                                                   | A non-fungible token with identifier type `type`                                                                                                                                                                                                                                    | `type` storable                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| `(define-trait name ((fn-name (type ...) type) ...))` and `(define-trait name ((fn-name (type ...) type read-only) ...))` | A trait: a set of function names with interface-typed signatures whose result types are `response` types. A function marked `read-only` may only be implemented by a read-only function, and may be called through the trait from read-only code (2.7.4)                            |                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| `(impl-trait trait-identifier)`                                                                                           | A conformance claim, checked statically: every function in the trait MUST be defined as a public or read-only function with a compatible signature (parameters contravariant, result covariant), and a function the trait marks `read-only` MUST be defined with `define-read-only` |                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| `(define-public (name (param type) ...) expr ...)`                                                                        | An externally callable function                                                                                                                                                                                                                                                     | parameter types are interface types; result type MUST be a `response`; monomorphic                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| `(define-read-only (name (param type) ...) expr ...)`                                                                     | An externally callable function that MUST NOT mutate state (2.7.4)                                                                                                                                                                                                                  | parameter types are interface types; monomorphic                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| `(define-private (name (param type-or-ref-kind) ...) expr ...)`                                                           | An internal function called by value                                                                                                                                                                                                                                                | may be generic and overloaded, and may end with a rest parameter (2.6)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| `(define-macro (name (param type-or-ref-kind) ...) expr ...)`                                                             | A macro: an internal definition expanded at each call site, with call-by-name parameters (2.6.3)                                                                                                                                                                                    | may be generic and overloaded                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |

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
begins, every chain of instantiations and macro expansions is finite (P1), and
the deploy-order check of 2.4.2 can be made on the source.

### 2.4.4 Contract interface

The compiler emits two sections describing the contract into its module
([../07-chain-abi.md](../07-chain-abi.md) section 3.4):

- **`abi.interface`** ([../07-chain-abi.md](../07-chain-abi.md) section 4.1)
  names the public and read-only functions with their kinds, and the fungible
  and non-fungible tokens. The chain validates it against the module at deploy
  and acts on nothing else.
- **`abi.types`**
  ([../08-value-interpretation.md](../08-value-interpretation.md) section 5)
  declares the parameter and result types of every public and read-only
  function, the identifier type of every non-fungible token, the traits the
  contract defines, the traits it claims with `impl-trait`, and the layout of
  its data variables and maps (3.7). A Clarity contract declares all of them, so
  none of its functions, tokens, or storage is undeclared.

The chain does not read `abi.types`. Other contracts, whatever their source
language, compile typed calls against it (2.5.8), and wallets and explorers
display values with it. Nothing at runtime checks that a module honors its
declarations, which is why a Clarity contract validates every value it receives
from another contract (2.5.8).

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

The scrutinee MUST have a type in this table. A scrutinee of type `never` is a
type error (2.3.3), including in an instance of a generic function whose type
variable is instantiated at `never` (2.6.2).

The type of the `match` is the lub of the arm types, and exactly one arm is
evaluated.

An arm whose pattern binds a name of type `never` (`(some x)` on
`(optional never)`, `(ok x)` on `(response never E)`, `(err e)` on
`(response T never)`) cannot be reached, but it still MUST appear, and its body
is type-checked and contributes to the lub like any other arm. On
`r : (response int never)`, `(match r ((ok v) v) ((err e) e))` has type `int`,
since `lub(int, never) = int`, and so does
`(match r ((ok v) v) ((err e) (panic)))`. The convention is `(panic)` in such an
arm.

`if` is a library function defined over `match` on `bool`. A macro body is
type-checked with each parameter at its declared type (2.6.3), so the scrutinee
of that `match` is a `bool` whatever the argument's type: `(if (panic) a b)` and
`(if (not (panic)) a b)` both have type `lub(A, B)`.

```
(and expr expr ...)
(or expr expr ...)
```

`and` and `or` take two or more `bool` expressions and evaluate them left to
right, stopping at the first `false` (`and`) or the first `true` (`or`). They
are core forms, not library functions, because short-circuiting over any number
of arguments cannot be written in the language: a macro has a fixed number of
by-name parameters, and a rest parameter (2.6.5) is a list value whose elements
are all evaluated before the body runs. `(and a b c)` means exactly
`(match a (true (match b (true c) (false false))) (false false))`.

### 2.5.4 `return`

```
(return expr)
```

Evaluates `expr`, then terminates the innermost enclosing function body (after
macro expansion, 2.6.3) with that value. `return` has type `never`. The type of
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
for macros, 2.6.3). Typing and overload resolution are defined in 2.6.2.

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
- The operand of `get` and both operands of `merge` MUST have tuple types. An
  operand of type `never` is a type error (2.3.3), so `(get balance (panic))` is
  rejected, as `(get balance (len (panic)))` is for the type of its operand.

### 2.5.8 Cross-contract calls

```
(contract-call? contract function-name arg ...)
```

`contract` is a contract principal literal, a static constant (2.4.1) of
contract principal type, or an expression of a trait type `(trait X)`; in the
trait case `function-name` MUST be a function of `X`. Any expression of trait
type is acceptable, including a tuple field or a `let`-bound name. A `contract`
of type `never` is a type error, since it names no trait (2.3.3). Arguments are
type-checked against the callee's declared signature in its `abi.types` (2.4.4)
in the literal case, or against the trait's signature in the trait case, read
from the `abi.types` of the contract that defines the trait. Either way the
section read is an input to compilation, and the compiler records its hash in
the module's provenance ([../03-architecture.md](../03-architecture.md) section
2). In the literal case the callee's function MUST be declared; a function with
no declared signature can only be called with `contract-call-raw?`. The result
type is the declared result type. The callee MUST be a public or read-only
function and MUST NOT be in the current contract.

The call is dispatched by the chain, which enforces the depth limit and the
no-reentrancy rule (2.7.5). The callee may be written in any source language.
The arguments are passed in canonical encoding against the declared parameter
types ([../08-value-interpretation.md](../08-value-interpretation.md) section
6.1). When the caller relies on the callee being read-only, the compiler sets
the call's `read_only` flag ([../07-chain-abi.md](../07-chain-abi.md) section
5.3) and the chain rejects a callee that is not: the call is from read-only code
(2.7.4), the trait marks the function `read-only`, or the literal callee
declares it read-only.

**Values are validated by the module.** The chain does not check values against
declared types ([../07-chain-abi.md](../07-chain-abi.md) section 5.4), so the
compiled module does:

- Every public and read-only function decodes its arguments, by canonical
  decoding against its declared parameter types
  ([../08-value-interpretation.md](../08-value-interpretation.md) section 3),
  before its body runs.
- Every `contract-call?` decodes the result against the declared result type, in
  the trait case the trait's: the `ok` arm's type or the `err` arm's, whichever
  the result flag selects.

A value that fails to decode is a runtime error (2.7.2). A Clarity contract can
therefore rely on its parameter types whoever calls it, and on the result type
of every call it makes, whatever language the other side is written in.

**Traits are checked at compile time.** Conformance (2.3.2, `impl-trait` in
2.4.1) is checked when a contract is compiled, against declared signatures. A
principal passed in a trait-typed parameter is not checked against the trait at
runtime, because a module cannot read another contract's declarations. A call
through it is still safe: it aborts if the function does not exist or, for a
function the trait marks `read-only`, is not read-only, and its result is
validated like any other, so a principal that does not conform can make the call
fail but cannot make it return a value of the wrong type.

```
(contract-call-raw? contract function-name args size)
```

Calls a function without a declared signature, such as a function of a contract
written in a language that does not declare its types
([../08-value-interpretation.md](../08-value-interpretation.md) section 6.4).
`contract` and `function-name` are as for `contract-call?`, except that
`function-name` is not checked against any declaration. `args : (buff N)` is
passed to the callee as the raw argument bytes. `size` is a size term `M`
(2.3.1), and the form has type `(response (buff M) (buff M))`: the result bytes,
in the `ok` or `err` arm as the result flag selects. A result longer than `M`
bytes is a runtime error. From read-only code the call sets the `read_only`
flag, so the callee MUST be read-only; otherwise the callee may be public or
read-only. The rollback rules of 2.7.3 apply to the callee as to any call.

### 2.5.9 Context scoping and asset allowances

```
(as-contract? (allowance ...) body-expr ...)
(as-contract? ((with-all-assets-unsafe)) body-expr ...)
(restrict-assets? owner-expr (allowance ...) body-expr ...)

allowance ::= (with-stx amount)
            | (with-ft contract token-name amount)
            | (with-nft contract token-name identifiers)
            | (with-staking amount)
            | (with-pox)
```

`(with-all-assets-unsafe)` waives the check for the current contract's assets.
Only `as-contract?` accepts it, because in `restrict-assets?` it would make the
form a no-op. It MUST be the only allowance in the list, because any other
allowance beside it would have no effect. The grammar above encodes both rules,
so writing it in `restrict-assets?` or alongside another allowance is a syntax
error.

Every allowance argument is an ordinary expression, so a contract or token can
come from a parameter, a variable, or a map entry, not only from a literal:

| Argument      | Type               | Meaning                                                                                                                                                          |
| ------------- | ------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `amount`      | `uint`             | the most uSTX (`with-stx`), token units (`with-ft`), or uSTX locked for staking (`with-staking`) the body may move from the owner                                |
| `contract`    | `principal`        | the contract that defines the token; a non-contract principal, or one that defines no token of that name, matches no movement                                    |
| `token-name`  | `(string-ascii N)` | the name the token was defined with (`define-fungible-token` or `define-non-fungible-token`); `N` is at most the identifier limit (2.8)                          |
| `identifiers` | `(list N T)`       | the non-fungible token identifiers the body may move; `T` is any storable type, and an identifier matches a movement when their serialized forms (3.4) are equal |

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

Allowance sub-forms are valid only in allowance position. Allowance arguments
are evaluated left to right, allowance by allowance, before the body, in the
enclosing context (for `as-contract?`, with the caller's `sender`, not the
contract's). The number of allowances is bounded (2.8).

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
| `define-macro`     | no                            | yes                 | yes              | yes                          | expanded at call site, by name |

Every invocation of a public function has the rollback semantics of 2.7.3,
whether it is called from another contract, as the entry point of a transaction,
or internally from the same contract. A public function's behavior on `err`
therefore does not depend on who called it.

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

Equivalent traits (2.3.2) are each a subtype of the other, so "least" is read
the way `lub` is, not as any minimal type in the preorder. A type variable whose
lower bounds are the argument types `S1 ... Sk` is instantiated to
`lub(S1, ..., Sk)`. One argument of type `(trait X)` instantiates it to
`(trait X)`, never to some other trait equivalent to `X`. Arguments of two
distinct equivalent trait types instantiate it to `principal`, so `(if c x y)`
with `x : (trait a)` and `y : (trait b)`, where `a` and `b` are equivalent
traits, has type `principal`, just as the corresponding `match` does.

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
argument of type `never` is admitted by every candidate, so with an overloaded
name it is an ambiguity error: `(unwrap! (panic) e)` is one. It also fixes no
variable, so a candidate whose instantiation depends on it alone has no least
instantiation and does not admit the call: `(len (panic))` is a type error,
since the sequence kind is undetermined. Otherwise the call is typed as any
other, so `(+ 1 (return u0))` has type `int` (2.3.3). An author who means a
particular candidate states the type with `as` (2.5.10).

Every other ambiguity is an error where the definitions are written rather than
at the call: the definitions of a name MUST NOT **overlap**. Two definitions
overlap when, under some instantiation of each, their parameters meet (2.3.2) at
every position. Reference-kind parameters meet when they are of the same kind
with the same declared types, except that two `(function ...)` kinds meet when
their parameter and result types meet pointwise. The check is on the
definitions, whether or not the name is called:

```
(define-private (pad (b (buff 4))) (concat b 0x00))
(define-private (pad (b (buff 8))) (concat b 0x0000))    ;; error: (buff 4) is below both

(define-private (first (xs (list 5 (buff 4)))) ...)
(define-private (first (xs (list 3 (buff 8)))) ...)      ;; error: (list 3 (buff 4)) is below both

(define-private (show (x T)) ...)
(define-private (show (x uint)) ...)                     ;; error: T at uint
```

Neither parameter type of `first` is a subtype of the other, but the two still
meet. Definitions whose parameters differ in shape at some position, such as
`int` and `uint`, `optional` and `response`, or a list and a `buff`, never
overlap; the prelude's overloads are all of this kind. Definitions that do not
overlap can still both admit an argument whose type mentions `never`: one on
`(list 5 (buff 4))` and one on `(list 3 uint)` both admit `(list)`, and such a
call is an ambiguity error as above.

The same rule applies to a name passed as a `(function (Q1 ... Qk) R)` argument.
Its candidates are the definitions of that name that can be named at `k`
parameters: those with exactly `k` parameters, and rest-parameter definitions
with `k - 1` fixed parameters. An instantiation of the enclosing candidate fixes
one of them, and exactly one MUST appear in some instantiation; zero is a type
error and more than one is an ambiguity error. Usually only one fits:
`(map int-to-ascii xs)` with `xs : (list 5 int)` uses the `int` definition.
Because definitions do not overlap, more than one fits only when some `Qi`
mentions `never`, where a direct call would be ambiguous too:

```
(map int-to-ascii (list)) ;; ambiguity error: (list) is (list 0 never)
```

In a fold, the referenced definition is fixed for the whole fixpoint, since a
single function is called on every element: each definition is tried with its
own fixpoint, it appears in an instantiation if that fixpoint closes, and
exactly one MUST. With the definition fixed, admitting the final accumulator
type implies admitting every earlier one, since each step's type is a subtype of
the next.

The result type of the call is the candidate's inferred result type under `σ`,
with size arithmetic in primitive signatures evaluated on the concrete sizes. A
resulting size that exceeds the limit for the call's position (2.3.1) is a type
error.

Each distinct combination of candidate, `σ`, and reference arguments is a
distinct **instance**. Instances are what the compiler operates on; the
definition graph (2.4.3) is over names and is checked before any instance
exists. Instance bodies are type-checked with the concrete substitution applied
("template" semantics): a generic body that is never instantiated is parsed and
scope-checked but not type-checked. An instance in which a type variable is
instantiated at `never`, as `f` is in `(map f (list))`, is type-checked like any
other (2.3.3).

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

### 2.6.3 Macros

A macro (`define-macro`) is a typed, hygienic definition that is expanded at
each call site.

Expansion is defined as follows:

1. The call is resolved and the body is type-checked exactly as for a private
   function (2.6.2): the arguments select the candidate and fix the
   instantiation, and the body is checked with each parameter at its declared
   type under that instantiation, not at the argument expression's own type. An
   argument whose type is a strict subtype of the parameter's, such as `(panic)`
   at a `bool` parameter, is seen by the body at the parameter's type, so
   `(if (panic) a b)` and `(if (not (panic)) a b)` are typed alike (2.5.3).
2. Evaluation of the call is evaluation of the body with each parameter
   reference replaced by its argument expression, evaluated in the caller's
   context at the point of reference (call by name). An argument whose parameter
   is never referenced on the taken path is not evaluated. Because evaluation
   happens at the point of reference, an argument referenced inside an
   `as-contract?` or `restrict-assets?` form in the body is evaluated inside
   that frame, with the frame's `sender` and `caller`, and the order in which
   arguments are evaluated is the order of their references in the body, not
   their order at the call site. Prelude macros reference their parameters
   outside any such frame. Prelude functions whose names read as ordinary calls
   (`default-to`, `map-insert?`) are private, so their arguments are evaluated
   eagerly as in legacy; laziness is confined to control-flow forms, and the
   library documents each place where it changes legacy behavior (`unwrap!`,
   `unwrap-err!`).
3. Names bound inside the body (`let`, `match`) are fresh and cannot capture
   names in argument expressions. Free names in the body resolve in the defining
   contract's top-level scope.
4. `return` inside the body returns from the caller's innermost enclosing
   function body, not from the macro.

To make call by name safe, each **value** parameter of a macro MUST be
referenced at most once in the body (syntactically). A body that needs a
parameter twice binds it with `let` first. Reference-kind parameters have no
evaluation and may be referenced any number of times.

Macros cannot be passed as `(function ...)` arguments. Macro expansion is finite
because the definition graph is acyclic (2.4.3).

> [!NOTE] **When to use `define-macro`.** A macro is the only way to write a
> helper that returns from its caller or evaluates an argument only on some
> paths. Use it for exactly those two cases, and use `define-private` for
> everything else. For example, a helper that replaces an error code and exits
> in one step cannot be private:
>
> ```
> (define-macro (try-with! (value (response T E)) (code F))
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
> A macro gives those up. At a call site, an argument whose parameter is not
> used on the path taken is never evaluated, so its side effects (a
> `contract-call?`, a `var-set`, an abort) do not happen. Arguments are
> evaluated in the order the body uses them, not the order they are written. An
> argument used inside an `as-contract?` or `restrict-assets?` form in the body
> sees that frame's `sender`. A function whose name reads as an ordinary call
> should not be a macro unless its documentation states which arguments may go
> unevaluated.

### 2.6.4 Result type inference

The result type of a function instance is the lub of the type of its last body
expression and the types of the operands of every `return` in its body (after
macro expansion), whether or not that `return` can be reached. A `return` whose
operand has type `never` contributes `never`, which the lub absorbs (2.3.3). If
the lub is undefined, it is a type error. For `define-public`, the result type
MUST be a `response` type; `never` is not one, so a public function whose every
path aborts is a type error. Such a function states its interface with `as`
(2.5.10): `(as (response bool uint) (panic))`. This is a rule about the declared
interface, not about `never`; a read-only function, whose result need not be a
`response`, may have the result type `never`.

The result type is not written in source, and may contain `never` (2.3.4). A
function with no `err` path has an error type of `never`; a function with no
`ok` path has a value type of `never`. Either is a valid interface type and is
what the compiler declares in `abi.types` (2.4.4).

### 2.6.5 Rest parameters

The last parameter of a `define-private` definition MAY be a **rest parameter**,
written with `...` after its type:

```
(define-private (name (first A) (second B) (rest T...)) body)
```

A call supplies the fixed parameters in order and **one or more** further
arguments for the rest parameter. Inside the body, the rest parameter is a list:
`rest : (list N T)`, where `N` is the number of rest arguments at that call
site. The call `(name a b t1 t2 t3 t4)` is the call of the definition with `a`
and `b` for the fixed parameters and `(list t1 t2 t3 t4)` for the rest, so
arguments are evaluated left to right and the list is typed by 2.5.6. Each call
site is its own instance (2.6.2), with `N` bound to the number of rest
arguments.

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
  parameters. Overloads then differ only by type, MUST NOT overlap (2.6.2), and
  overload resolution needs no rule about arity.
- **Passing a rest function.** A rest-parameter function may be passed as a
  `(function ...)` argument at the type with one more parameter than its fixed
  parameters; the last argument becomes a one-element rest list (2.6.2). So
  `(fold-left max 0 xs)` and `(fold-left + 0 xs)` work.
- **No self-reference.** A rest-parameter body cannot fold itself, since that is
  a cycle (2.4.3). The binary operation lives in a helper, as `std-max-pair`
  above, or in a primitive.
- **Private only.** Public and read-only functions MUST NOT have rest
  parameters, because their declared signatures have a fixed arity (2.4.4).
  Macros MUST NOT have them either: rest arguments are evaluated as a list
  before the body runs, which would silently make a macro strict in those
  arguments.
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

Evaluation is strict and left to right, except that macro parameters are
evaluated by name (2.6.3), `match` evaluates exactly one arm, and `and` and `or`
stop at the first argument that decides the result (2.5.3). Every expression
evaluates to a value of its static type or aborts. A runtime value carries no
static type information of its own; its size and shape are determined entirely
by the value, and a value passed to a callee is exactly the value the caller
computed.

### 2.7.2 Runtime errors

A runtime error (arithmetic overflow, division by zero, failed conversion,
`panic`, cost or memory limit exceeded, a value that fails validation at a call
boundary (2.5.8), and the other conditions listed per primitive) aborts the
entire transaction. There is no mechanism to catch a runtime error. All state
changes of the transaction are discarded; the transaction still pays for the
cost it consumed. A runtime error the module detects is reported through the
chain ABI's `abort` with a code for its class
([../07-chain-abi.md](../07-chain-abi.md) section 10.2); the codes are defined
with compilation to Wasm.

### 2.7.3 Public function results and rollback

Every invocation of a public function runs in its own state frame: its state
changes (variables, maps, token balances, events) are buffered. If it returns
`(ok v)`, they are committed to the caller's frame. If it returns `(err e)`,
they are discarded and `(err e)` is returned to the caller, which continues
executing. A `return` of an `err` value has the same effect as evaluating to it.

For a call from another contract or a transaction entry point, the chain opens
the frame and commits or discards it by the result flag the callee sets
([../07-chain-abi.md](../07-chain-abi.md) section 5.2), so the rule holds for
calls between modules of any source language. A Clarity public function sets the
flag from the arm of its response and passes the arm's value as the result
([../08-value-interpretation.md](../08-value-interpretation.md) section 6.2). A
read-only function also runs in a frame the chain opens, which carries its
context (3.9) but always commits, since it holds no writes
([../07-chain-abi.md](../07-chain-abi.md) section 7.1). The flag decides nothing
there, so a read-only function always sets it to ok and passes its whole result.
For an internal call to a public function, the compiled module opens and closes
the frame itself through the chain ABI's frame facility, the one `as-contract?`
and `restrict-assets?` use (2.5.9).

An internal call to a public function therefore costs a frame, which a call to a
private function does not. Where that matters, the convention is to put the body
in a private function and have the public function call it: internal callers use
the private function and pay nothing, and external callers get the rollback
through the public wrapper.

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
call frame in the current transaction, and rejects any `contract-call?` that
would exceed the chain ABI's contract-call depth limit. Both are runtime errors.
The function call depth limit (2.8) is the language's own and bounds calls
within one contract's module; the compiler enforces it statically, since without
recursion every call chain is visible in the definition graph.

### 2.7.6 Events

`print` and every asset primitive emit events into the transaction's event
batch. A `print` event is the text rendering of its value (3.10). Events of a
rolled-back frame are discarded with it.

### 2.7.7 Cost

The language defines no costs (P4). A contract runs as the Wasm module its
source compiles to, and its execution cost is the fuel that module consumes plus
the chain's charges for the host functions it calls. Library functions are
compiled and metered like any other code. Exceeding the transaction or block
budget is a runtime error.

Fuel replaces a per-construct runtime cost table, and it is the only cost
dimension: storage reads and writes are charged in fuel like everything else, at
prices the chain ABI defines. Compilation happens off chain, so its cost is the
deployer's. What the chain charges for is the module: its size and its
validation at deploy, as defined by the chain ABI.

The following rules are about resource safety, not pricing:

- Memory for a decoded value is reserved against the size bound of its type
  before decoding begins, so a hostile input cannot allocate more than its
  declared type admits. This covers every decode of bytes the module did not
  produce: `from-consensus-buff?`, which reserves `serialized-size(T)`; the
  arguments a public or read-only function decodes on entry, which reserve the
  sum of `serialized-size` over its parameter types; and the result of every
  `contract-call?`, which reserves `serialized-size` of the declared result type
  (2.5.8). Input longer than that bound cannot be a valid encoding and is
  rejected before any decoding: as a validation failure (2.7.2) for arguments
  and call results, and as `none` for `from-consensus-buff?`.
- A trait-typed value is a principal and is sized as one.

## 2.8 Limits

These are language-level limits. Hosts MAY impose stricter limits on contract
source size and transaction budgets.

| Limit                                                                                | Value           | Inherited from                                                                                      |
| ------------------------------------------------------------------------------------ | --------------- | --------------------------------------------------------------------------------------------------- |
| Maximum serialized value size                                                        | 1,048,576 bytes | `MAX_VALUE_SIZE`                                                                                    |
| Maximum intermediate value size (2.3.1)                                              | 8,388,608 bytes | new, provisional; MUST stay below the chain's Wasm memory limit                                     |
| Fixpoint step limit for fold accumulators (2.6.2)                                    | 8               | new, provisional                                                                                    |
| Maximum type nesting depth                                                           | 32              | `MAX_TYPE_DEPTH`                                                                                    |
| Maximum identifier length                                                            | 128 bytes       | `MAX_STRING_LEN`; string literals are bounded only by the value size limit, as every other value is |
| Maximum function call depth within a contract (2.7.5)                                | 128             | `MAX_CALL_STACK_DEPTH`; contract-call depth is the chain ABI's                                      |
| Maximum allowances per `as-contract?` / `restrict-assets?`                           | 128             | `MAX_ALLOWANCES`                                                                                    |
| Maximum storage key: a map's key prefix plus `serialized-size` of its key type (3.7) | 1,024 bytes     | new; the chain ABI's storage key limit                                                              |
| Maximum `print` message: the rendered length bound of the argument's type (3.10)     | 1,048,576 bytes | new; the chain ABI's print message limit                                                            |

There is no limit on the size of a contract after macro expansion and
instantiation, which can grow exponentially (definitions that each call the next
twice, or instantiate it at two types). The only limit is the chain's limit on
module size. A compiler MUST report a contract whose module would exceed it as a
compile error, and SHOULD stop expanding as soon as the limit is passed. A
language-level cap would not make validity compiler-independent, since near the
limit whether a contract fits already depends on code generation (P5).

## 2.9 Open questions

An item tagged **RFC** needs its own design RFC, with a decidability analysis,
before this chapter can be frozen. The others are decisions this draft can take
once the dependency named in each is settled.

1. **Version numbering** (2.4.0). Whether `clarity-version` takes a single
   integer or a major and minor pair depends on how language releases are cut:
   any change to the prelude or to a rule is a new version for compatibility
   purposes, which argues for one number.
2. **RFC: explicit size parameters.** A reference kind such as `(width size)`
   that accepts a size term at the call site, with the rule that a size variable
   is usable as a `uint` value in the body. It would make `uint-to-buff-be` a
   single `(uint) -> (buff 16)` primitive and move the four fixed-width
   `*-to-buff-*` functions (3.4) into the prelude.
3. **RFC: static closures.** Function templates that capture only reference-kind
   parameters, never runtime values, whose instances are ordinary named
   functions resolved at instantiation. They would make a generic `fold-right`,
   a multi-sequence `map`, and `flip`-style adapters writable in the prelude
   without function values at runtime or in the ABI.
4. **RFC: bounded iteration.** The prelude drives several loops with constant
   lists used as counters (`std-decimal-iterations`, `std-exponent-bits`). A
   form that iterates a statically bounded number of times without a list, and
   that preserves P1, would remove the pattern. This is the "richer bounded
   iteration" item of the specification plan.
5. **RFC: host bindings in the prelude.** A `define-host` declaration form would
   let the prelude declare every host-calling primitive (storage, assets,
   context, chain data, signature schemes, `print`) by name and signature, with
   semantics cited from the chain ABI rather than restated in chapter 3. The
   same form could cover compiled primitives with ordinary signatures, leaving
   chapter 3 with only the primitives whose typing cannot be written as a
   signature. Parked; it requires an admission rule on the ABI side.
6. **Static memory bound.** The intermediate size limit only has to stay below
   the chain's instance memory limit, so whether a well-typed contract's live
   values fit in memory depends on code generation, and exceeding it is a
   runtime error. The compiler could instead compute each function's peak memory
   and reject a contract that cannot fit, as it already does for module size
   (2.8). The chain's transaction memory cap, which depends on the callers'
   memory, would remain a runtime error.
7. **Formal presentation.** The judgment-style typing rules and the full EBNF
   are pending the questions above.
