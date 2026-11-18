# Type Checker Proposal

This is a proposal for the Clarity type checker: the `clarity-types` part of the
toolchain ([03-architecture.md](03-architecture.md) section 2). It decides
whether a source is a valid contract under spec chapters 2 and 3. It produces
the types that the compiler and the `abi.types` section
([08-value-interpretation.md](08-value-interpretation.md) section 5) need. Like
[07-chain-abi.md](07-chain-abi.md), it takes a position on every question
instead of listing options. Section 13 collects the changes it proposes to the
spec. Section 14 collects the questions the spec leaves open, each with a
proposed answer.

## 1. Scope

The checker is a function from one contract's source, plus explicit inputs, to a
verdict. It covers:

- the static semantics of spec chapter 2, the primitive signatures of chapter 3,
  and the standard library of chapter 4, which it checks as Clarity source;
- the `abi.types` section of the contract (spec 2.4.4);
- a typed intermediate representation (IR) that the compiler consumes instead
  of re-deriving types (section 12).

Parsing is specified by spec chapter 5. Code generation and cost analysis
belong to other crates. Checking is not consensus-critical: the chain validates
and runs modules, never source ([03-architecture.md](03-architecture.md)
section 6). So a checker fix ships in a compiler release. The verdict must still
be deterministic, because a verified triple rebuilds the same module from the
same build inputs.

## 2. Design rules

| Rule                                                                                                                                                                          | Why                                                                                                                                                                                                                                              |
| ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **K1. Types are synthesized bottom-up and checked only where a value is consumed.** Nothing is pushed down from context.                                                      | The spec defines every expression's type from its parts (spec 2.5, 2.6.4). Pushing an expected type down would turn `none` into `(optional int)` and make an expression's type depend on where it appears.                                       |
| **K2. One subtyping relation, one lub over sets, one meet predicate**, each the spec's definition (spec 2.3.2).                                                               | A pairwise lub fold gives `(list x y z)` and `(list x z y)` different types when traits are involved. The spec defines lub over the whole set.                                                                                                   |
| **K3. Primitive signatures are data, checked mechanically against chapter 3, and one instantiation algorithm types every call**, primitive or user-defined.                   | A hand-written checker per primitive drifts from the spec: it accepts argument types the signature excludes, or ignores extra arguments. With a table, arity and types are a property of the data, and a test keeps the data equal to chapter 3. |
| **K4. Generic bodies are checked per instance, and each instance once.**                                                                                                      | Checking a generic body once, with variables in it, would mean solving size arithmetic symbolically, which the spec avoids (spec 2.3.5). Without a memo, the number of instances grows exponentially.                                            |
| **K5. A checker that cannot decide a contract says so.** "Unsupported" is a verdict of its own, never folded into accept.                                                     | A checker built in stages (section 15) cannot decide a contract that uses a feature it does not implement yet. Guessing would accept contracts that were never fully checked.                                                                    |
| **K6. One error gives one diagnostic, and every independent error is reported.**                                                                                              | A checker that stops at the first error makes users fix one error per run. A checker that continues without care cascades: one bad argument yields several errors.                                                                               |
| **K7. The verdict does not depend on the host.** No hash-map order, thread count, stack size or clock reaches it. An implementation limit is never a verdict on the contract. | Two machines building the same source must agree on the verdict (verified triples). A crash on deep input, or a rejection that comes from an implementation limit instead of the spec, breaks that.                                              |
| **K8. Every reading of an ambiguity is written down with its spec line and pinned by a test.**                                                                                | The spec is a draft. An ambiguity that two implementations resolve silently and differently becomes a difference in verdicts. A written reading becomes a question for the spec (section 14).                                                    |

## 3. Interface

```
check(source, inputs) -> Verdict

Inputs  = { deployer, contract name, declared version, deployed contracts }
Verdict = Accept(Program)        ; typed IR and abi.types (section 12)
        | Reject(Diagnostics)    ; at least one static error
        | Unsupported(Features)  ; the checker cannot decide (K5)
        | Exhausted(Report)      ; implementation capacity (section 11.3)
```

Each input is needed by a rule:

- **Deployer.** It gives `.c` literals their contract (spec 2.2).
- **Contract name.** Local traits are named by the contract's principal
  (value interpretation 5.2), and a `contract-call?` to the current contract is
  an error (spec 2.5.8).
- **Declared version.** See spec 2.4.0.
- **Deployed contracts.** The contracts the source can name, as one world: a
  principal resolves, on demand, to the `abi.types` of the contract deployed at
  it, its traits included (spec 2.4.4, 2.5.8). One contract can be deployed at
  several principals, and a dependency's own references resolve in the same
  world. A contract may be given as source, checked first, or as an `abi.types`
  declaration, for one written in another language. A function such a
  contract leaves undeclared has no signature: it can be called only with
  `contract-call-raw?`, and a `contract-call?` to it is an error (spec 2.5.8,
  value interpretation 6.4). A principal at which
  nothing is deployed names a contract that declares nothing (value
  interpretation 5.3): calling it, or naming a trait it would define, is a
  static error, not an Unsupported verdict. Each answer is recorded by hash for
  the provenance section.

**Verdict precedence.** Reject outranks Unsupported, which outranks Accept.
Synthesis does not depend on context (K1), so the operands of an unsupported
form still have their spec types, and an error inside them is still an error.
The unsupported form itself gets the poison type (section 5.2) and causes no
diagnostic.

**The prelude** ([spec/std/prelude.clar](spec/std/prelude.clar)) is part of the
checker and versioned with it. It is checked as a contract when the checker is
built.

- Its bodies are resolved against its own definitions and the primitives. A
  contract's definitions are invisible to it, so a contract that defines `total`
  does not make the prelude's parameter `total` a shadowing error.
- A contract still may not define a prelude name (spec 2.4.5).

## 4. Pipeline

| Pass             | Postcondition                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| ---------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| P0 Parse         | The source is in the grammar of spec chapter 5, including its token and post-parse rules (T1–T4, W1, LX1–LX7). A parse error stops checking. It is reported at the earliest point of failure (section 10.3).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| P1 Resolve       | Every name is bound to exactly one entity. The syntactic rules hold: C1, C2 for a `return` written directly in deploy-time code, C6, C7, C8, C10, C11, C13, C15. C14 holds where the grammar fixes the position, as in the function slot of `map`. Also: no unbound name, no non-value name in value position (primitive argument positions included), no head that cannot be called, a reference name (storage, token, event or function name, or reference parameter) as an argument only where some definition of the callee takes a reference at that position, no parameter name in a size position of its own definition (C12, spec 2.3.5), and the rest-parameter shape of overloads. Generic bodies are scope-checked even if never instantiated (spec 2.6.2). |
| P2 Graph         | The definition graph is acyclic (spec 2.4.3): one cycle is reported per strongly connected component. Static constants are classified. C12 holds. The deploy-order rule holds (spec 2.4.2).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| P3 Headers       | In topological order: aliases, trait signature sets, storage declarations (C4, storage key limit), constant types, and the signature schemes of every function and macro (C5). No function or trait function has more than 256 parameters. Overloads of a name do not overlap (spec 2.6.2).                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| P4 Instances     | Every root and every instance a root reaches is type-checked, with a summary for each (section 6.2). A definition reached first from inside an instance is checked without that context (section 6.9). This pass checks C2 through macros, C3, C9, the rest of C14, every typing rule, and the size and depth limits.                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| P5 Whole program | `impl-trait` conformance holds, inferred public and read-only results are interface types (C5), read-only enforcement holds (spec 2.7.4), and the call depth is at most 128 (spec 2.7.5, section 8.2).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| P6 Elaborate     | Macros are expanded, every coercion is explicit, `abi.types` is emitted, and the IR verifier passes (section 12).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |

P1 and P2 run on every definition, instantiated or not. P4 runs on roots and on
what they reach. P5 and P6 run only if P1–P4 found no error.

Three points about the passes:

- The parser is more than a reader of a parse tree: the post-parse rules of
  chapter 5 are part of it.
- P1 decides rules that 5.4 does not number, such as unbound names and heads
  that cannot be called.
- P2 has a fixed internal order: graph, cycles, static classification, C12,
  deploy order. Classification must tolerate cycles, since a constant on a cycle
  is not static, and the cycle is its only error.

The call depth check belongs in P2: the spec defines it on the definition graph,
so it needs no typing.

## 5. Types

### 5.1 Representation

There are two type languages, kept separate:

- **Ground types**: `int`, `uint`, `bool`, `principal`, `never`, the three
  sized sequences, `list`, `optional`, `response`, tuples with sorted fields,
  `(trait X)`, the internal contract-literal type, and the poison type. Ground
  types have no variables. All instance checking and the IR use them.
- **Schemes**: types with type and size variables. They appear only in parameter
  types of private functions and macros, and in primitive signatures.
  Instances are always ground.

Interning ground types (equal structure means equal identity) makes memo keys
and equality cheap. It also allows these attributes to be cached per type:

| Attribute        | Definition                                         | Spec  |
| ---------------- | -------------------------------------------------- | ----- |
| serialized size  | value interpretation 4.1; none on overflow         | 2.3.1 |
| depth            | section 5.3                                        | 2.8   |
| storable         | no trait type, no contract-literal type            | 2.3.4 |
| interface        | no contract-literal type                           | 2.3.4 |
| mentions `never` | contains `never`                                   | 2.3.2 |
| principal-like   | `principal`, a trait type, a contract-literal type | 2.3.2 |

Plain trees also work. Interning is a recommendation, not a requirement.

### 5.2 `never` and poison are different types

`(ok e)` is `(response T never)`, `none` is `(optional never)`, and `(list)` is
`(list 0 never)` (spec 2.3.3). `never` is an ordinary type whose one property is
`never <: T`. It is never used for error recovery, because it changes overload
resolution: an argument of type `never` can make a call ambiguous (spec 2.6.2).

The **poison** type is the type of a subterm whose error was already reported.
Everything built from that subterm is poisoned too, so the checker reports the
error once and stays silent about its consequences. The poison type:

- is related both ways to every type;
- absorbs lub;
- passes every shape test;
- meets nothing, so a poisoned overload adds no overlap error;
- is never itself reported.

It has exactly three sources: an emitted diagnostic, a name P1 could not resolve
(already reported), and a feature the checker cannot decide (recorded as
unsupported).

### 5.3 Depth

An atom (`int`, `uint`, `bool`, `principal`, `never`, a sized sequence, a trait
type) has depth 1. `list`, `optional`, `response` and a tuple add 1 to their
deepest component, and an empty tuple has depth 1. Every type the checker
computes or reads is held to 32 (spec 2.8). Enforcing this when a type is built
bounds every recursive function over types by a constant. Section 13 proposes
stating this count in the spec.

### 5.4 Sizes

Sizes are exact unsigned 128-bit integers. Size arithmetic in primitive
signatures (`N + M...`, `serialized-size`) is checked, and an overflow is the
size error of that position. Saturating arithmetic would be unsound: it could
make `(list 2^128 never) <: (list 2^128-1 never)` true. Section 14 asks whether
to cap sizes at `2^32 − 1`, which would allow 64-bit arithmetic.

### 5.5 Subtyping

`sub(a, b)` is one structural walk over spec 2.3.2:

- reflexive;
- `never` is below everything, and poison is related both ways;
- sequence bounds are covariant, and so are `list`, `optional` and `response`;
- tuples need the same field names, with no width subtyping;
- a contract literal is below `principal`, and below a trait it conforms to
  (value interpretation 5.2);
- a trait type is below `principal`, and below another trait by the sub-trait
  rule (section 14, item 7).

### 5.6 Lub over a set

`lub` is taken over the whole set, never as a pairwise fold (spec 2.3.2). This
applies to list elements, `match` arms, a function's result (its last
expression together with every `return` operand, after macro expansion), the
lower bounds of a type variable, and rest arguments. A macro instance therefore
keeps the **set** of its return-operand types, not their lub.

For principal-like members, the spec takes the member that every other member is
a subtype of, or else `principal`. It also gives `principal` when two distinct
equivalent traits qualify. Comparing all pairs is quadratic. A running-candidate
scan is wrong, because subtyping between traits is a preorder: two distinct
traits can be equivalent. The exact linear method:

```
lub_principal(D):                       ; distinct principal-like types, |D| >= 2
  if principal in D: return principal
  T := trait members; L := contract-literal members
  if T is empty: return principal       ; two or more distinct literals
  I := intersection over X in T of F(X) ; F(X) = X's functions with signatures
  Q := { X in T | F(X) = I }            ; X is above every trait member iff F(X) = I
  if |Q| != 1: return principal         ; none, or several equivalent traits
  if every literal in L conforms to the member of Q: return it
  return principal
```

A literal is never above a trait or another literal, so only a trait can be the
answer. Returning `principal` whenever a literal is present is a tempting
shortcut, but it is wrong: the spec's own example
`(list (as (trait X) .a) .b .c)` has type `(list 3 (trait X))`.

### 5.7 Meet

No rule needs a greatest lower bound. Two predicates are enough:

- **`meets(a, b)`** on ground types: some type that does not mention `never` is
  below both (spec 2.3.2). Sizes never block a meet. A type that mentions
  `never` meets nothing. `principal` meets every principal-like type. Two
  literals meet only if they are equal. A literal meets a trait it conforms to.
- **Two traits meet** when no function required by both has different
  signatures. This is the rule the spec states, and it differs from the
  definition (section 14, item 8).

## 6. Calls

### 6.1 Candidates

Take a call with `n` arguments, where a final spread `e...` counts as one
argument. The arguments are synthesized left to right. The candidates are the
callee's definitions whose arity fits:

- a definition with exactly `n` parameters;
- a rest definition with fewer than `n` fixed parameters, so that at least one
  argument goes to the rest parameter;
- for a call ending in a spread, a rest definition with exactly `n − 1` fixed
  parameters.

If no definition fits, the error is `T-ARITY`. A primitive's arity comes from
the signature table and is checked even when an argument is poison, so a call
can never pass extra, untyped arguments.

### 6.2 Least instantiation

For each candidate (spec 2.6.2), the steps are:

1. **Exact bindings from reference kinds.** A `(var T)`, `(map K V)` or
   `(non-fungible-token T)` argument must name a definition of that kind, or a
   reference parameter of the enclosing instance. Its declared types bind the
   scheme's variables exactly, sizes included.
2. **Lower bounds.** Walk each parameter scheme together with its argument type.
   - A type variable records the argument type as a lower bound, with its origin.
   - A size variable records the bound.
   - A `never` part records nothing.
   - A mismatched part records nothing; verification reports it.
3. **Solve.** For each type variable:

   - if it has an exact binding, take it, and require every lower bound to be
     below it;
   - otherwise take the lub of its lower bounds, or `never` if it has none.

   Each size variable takes its exact binding, or else the largest bound, or
   else 0. A sequence-kind variable not fixed by any argument has no
   instantiation: `(len (panic))` is `T-NOFIT`.

4. **Function references.** See section 6.6.
5. **Verify.** Check every value argument against its parameter, with `sub`,
   under σ (the instantiation). Check the `where` constraints of a primitive.
   Verification is redundant for variables solved by lub. It is also the one
   place where concrete parts (literal sizes, named traits) are checked, and the
   one that explains a failure.

Every value position is covariant, so this gives the least instantiation
whenever one exists.

The instance key is (definition, σ, the definitions named by reference
arguments, rest length). Two data variables of the same type give two instances
(spec 2.3.7: "each distinct reference is its own instance"). A summary records
these facts for each instance:

- its result type;
- the set of its return operands (macros only);
- whether it can return (macros only, for C2);
- its first state write;
- its first `contract-call?` that is not statically read-only.

Because the definition graph is acyclic, an instance is never re-entered while
it is being checked.

**Roots** are checked whether or not anything calls them:

- public and read-only functions;
- deploy-time code, in source order;
- monomorphic private functions and macros.

A definition with a type variable, a size variable, a reference-kind parameter
or a rest parameter is a template. It is checked only per instance (spec 2.6.2,
2.6.5).

### 6.3 Reference kinds

- **Instances.** A function with reference parameters is checked per instance,
  like a generic one, even when it has no type variable: an instance is a
  combination of candidate, σ and reference arguments (spec 2.6.2).
- **Storage kinds** bind exactly, with no subtyping in either direction.
- **`(event T)`**: a variable that occurs only in event references takes the
  event's declared type, and two event references that disagree on it have no
  instantiation. A variable that also occurs elsewhere is solved there, and the
  declared type must be a supertype of the parameter's type under σ (spec 2.3.7,
  2.6.2). Inside the body, `emit` through the parameter is held to the
  parameter's own type, which may be narrower than the declared one.

### 6.4 Rest parameters and spread

The rest arguments, or the element type of the spread list, are lower bounds of
the rest parameter's variables together with their other occurrences, so
`(all 1 u1)` with `(xs T...)` has no lub. A spread of `never` is the empty rest
list. The rest length is part of the instance: `(f 1)` and `(f 1 2)` are two
instances, and two `(f 1)` calls share one. Another reading of "the list is
typed by 2.5.6" types the rest list on its own first. The two readings differ
only for trait-typed arguments (section 14, item 3).

### 6.5 Overload resolution

Every candidate is tried, in definition order:

- a template by its least instantiation, with its diagnostics captured, not
  reported;
- a plain definition by its parameter types.

Exactly one candidate must admit the call:

- **None admits:** `T-NOFIT`, with each candidate's reason as a note.
- **More than one:** `T-AMBIG`, naming the arguments whose types mention
  `never` and suggesting `as`. For candidates that do not overlap, such an
  argument is the only cause of ambiguity (spec 2.6.2).
- **A candidate's admission stops without a diagnostic** (an unsupported
  feature, or a written type whose error was already reported): the call is
  poison. Guessing could produce a false `T-AMBIG`.

Admission depends only on parameter types, plus the result types of named
functions (section 6.6). An error in the chosen candidate's body is that
instance's error. It never removes the candidate, so a typo in a body cannot
change which overload is chosen.

An overload group is all `define-private` or all `define-macro`. A name with
both kinds of definition is C1, since a call would then pass arguments either
by value or by name depending on which candidate resolution picks.

### 6.6 Function references and the fold fixpoint

For a `(function (Q...) R)` parameter, once `Q[σ]` is ground, each definition
the argument names is tried as if called with arguments of types `Q[σ]`.
Exactly one must admit, and the argument is pinned to it. Its instance is
checked to obtain its result, which becomes a lower bound of the variables of
`R`. A macro cannot be named. A primitive can, at the arity of the function
type: `(map sha256 xs)` names `sha256` at one argument, and `+` given to a fold
names it at two. A primitive family counts as one definition.

Inside a template, a function parameter passed on to another call stands for
its declared signature under σ. Instances are keyed by the function the
argument names, never by the parameter.

When a variable of `R` also occurs in `Q`, as in a fold accumulator, the
fixpoint of spec 2.6.2 runs:

```
A(i+1) = lub(A(i), R(A(i)))   for at most 8 steps
```

The definition pinned at the first step is used at every step. Every prelude
fold closes in two steps. With several interdependent function parameters, each
round evaluates every reference once in parameter order, and the cap is 8
rounds (section 14, item 12). An error inside a tentative instance, whether a
named candidate or a non-final step, is a hard error reported with its chain.

### 6.7 Macros

A macro call is resolved like a private call. Its instance body is checked once
per instance, with each value parameter at its declared type under σ, not at the
argument's own type (spec 2.6.3). So `(if (panic) a b)` checks a `match` on
`bool`. Expanded code is never checked again.

Binders in the body are fresh, and free names resolve in the defining scope.
Each instance summary records its return operands, including those of macro
instances it calls. This gives two results:

- a function's result is `lub({last} ∪ every return operand reached)`, as one
  set;
- a macro that can return, called from deploy-time code, is C2 at the call. This
  is how `unwrap!` at top level is rejected.

A macro instance's parameter types under σ are held to the intermediate size
limit, not the value limit: the value size limit applies to the parameters of
functions, not of macros (spec 2.3.1).

### 6.8 Results

- `(return e)` has type `never`, and `e` joins the enclosing function's return
  set.
- A public function's result must be a `response`, and `never` is not one
  (`T-RESULT`).
- Public and read-only results must be interface types (C5). An inferred result
  that mentions a contract-literal type is C5, with the hint
  `(as principal .tok)` (section 14, item 2).
- An undefined lub over the result set is `T-NOLUB`, with every contributing
  site as a secondary span.

### 6.9 Checking a definition on demand

A definition reached first from inside an instance, an overload trial or a
macro expansion is checked as if from the top level: with no instance frame, no
captured overload reasons, no enclosing `return` set and no enclosing effects.
Its errors are its own, reported once at their place, and never attributed to
the instance or trial that first needed it. Its result is then memoized like
any other. Without this rule, a callee's error would be reported inside
whichever instance happened to need it first, and a macro's `return` in a
constant initializer would leak into a function's result.

## 7. Expression forms

The table summarizes how the special forms are checked. The spec sections are
normative.

| Form                               | Checked as                                                                                                                                        | Spec       |
| ---------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- | ---------- |
| literal                            | exact sizes; a standard principal is `principal`; `.c` and `'SP….c` have the literal type of the resolved principal; `none` is `(optional never)` | 2.2, 2.3.1 |
| `let`, `begin`                     | bindings left to right; C3 on every non-last element; the type of the last                                                                        | 2.5.2      |
| `match`                            | the scrutinee selects the arm pair; a scrutinee of type `never`, or of a type with no row, is C9; type is the lub of the arms                     | 2.5.3      |
| `and`, `or`                        | every operand `<: bool`                                                                                                                           | 2.5.3      |
| constructors                       | `(optional T)`, `(response T never)`, `(response never E)`, `(list n lub(...))`                                                                   | 2.5.6      |
| `get`, `merge`                     | the operand is a tuple (a `never` operand is an error); the field exists                                                                          | 2.5.7      |
| `contract-call?`                   | static target: the callee's declared signature (section 3); trait target: the trait's signature; the current contract is not a target       | 2.5.8      |
| `contract-call-raw?`               | target as for `contract-call?`; the name is not checked; `args <: (buff N)`; type `(response (buff M) (buff M))`, `M` a size term           | 2.5.8      |
| `as-contract?`, `restrict-assets?` | allowances typed in the enclosing context; at most 128 allowances (C8); the body is a sequence                                                    | 2.5.9      |
| `as`                               | requires `sub(type(e), T)`; on failure the form is poison, so one error gives one diagnostic                                                      | 2.5.10     |

Every synthesized type is held to the intermediate size limit and depth 32.
These are held to the value size limit (spec 2.3.1, 2.8):

- names and parameters;
- function results;
- written types, every component included;
- stored values;
- event payloads;
- `contract-call?` arguments.

## 8. Static rules

### 8.1 Who checks what

"Checked in" names the pipeline pass of section 4. "Error code" is the code of
the diagnostic the rule produces (section 10.1).

| Rule                                                                                                                                                 | Checked in | Error code                      |
| ---------------------------------------------------------------------------------------------------------------------------------------------------- | ---------- | ------------------------------- |
| C1 duplicates and shadowing; overload groups of one kind; prelude names reserved                                                                     | P1         | `C1`                            |
| C2 `return` in deploy-time code: written directly (P1), through a macro (P4)                                                                         | P1, P4     | `C2`                            |
| C3 a `response` dropped in a sequence (not at top level, section 13 item 6)                                                                          | P4         | `C3`                            |
| C4 storable types: storage declarations, consensus-buffer operands                                                                                   | P3, P4     | `C4`                            |
| C5 interface types: written signatures (P3), inferred results (P5)                                                                                   | P3, P5     | `C5`                            |
| C6–C8, C10, C11, C13, C15                                                                                                                            | P1         | `Cn`                            |
| C9 `match` arm pair                                                                                                                                  | P4         | `C9`                            |
| C12 names in size positions, including a parameter's name in its own definition's size positions                                                     | P1, P2     | `C12`                           |
| C14 reference arguments: only where some definition of the callee takes a reference at that position, in every body (P1); the resolved overload (P4) | P1, P4     | `C14`                           |
| unbound name, non-value in value position, head that cannot be called, wrong variable kind, duplicate parameter or field                             | P1         | `R-*`                           |
| cycle; deploy order                                                                                                                                  | P2         | `G-CYCLE`, `G-DEPLOY-ORDER`     |
| call depth > 128                                                                                                                                     | P5         | `T-CALL-DEPTH`                  |
| storage key > 1,024 bytes; > 256 parameters                                                                                                          | P3         | `T-LIMIT`, `T-PARAMS`           |
| overlap of overloads                                                                                                                                 | P3         | `T-OVERLAP`                     |
| arity, no fit, ambiguity, no lub, mismatch, shape, field, `where`, limits, depth, fixpoint                                                           | P4         | `T-*`                           |
| `contract-call?` target not a literal or static constant, or the current contract; call of a function the callee does not declare                    | P4         | `T-CALL-TARGET`, `T-UNDECLARED` |
| `impl-trait` conformance; read-only enforcement                                                                                                      | P5         | `T-IMPL-TRAIT`, `T-READ-ONLY`   |
| unsupported version                                                                                                                                  | P1         | `V-VERSION`                     |

The "unreachable code" paragraph of spec 2.3.3 states a fact, not a rule. It is
a lint.

### 8.2 Static call depth

Spec 2.7.5 says the compiler enforces the call depth limit statically on the
definition graph. These rules make that a number:

- a call of a private, public or read-only function is a frame;
- a macro adds no frame, since it expands in place;
- a callback of `map`, `filter` or a fold is one frame;
- prelude functions count like the contract's own;
- a public or read-only function counts itself, and deploy-time code counts the
  frames of the functions it calls;
- a call counts the definition it resolves to, in the instance it reaches.

Which overload a call reaches, and which function a `(function ...)` parameter
stands for, are known only after typing. So the depth is computed from the
instance summaries, not from the definition graph: each summary carries its
deepest chain, and the instance graph is acyclic, so depths are computed
bottom-up in linear time. Exceeding 128 is an error at the entry point, with
the deepest chain as notes.

### 8.3 Read-only enforcement

A read-only function must not reach any of the following, directly or through
any code it runs: private functions and their instances, prelude functions,
macros, and the functions it passes to `map`, `filter`, the folds or
`(function ...)` parameters (spec 2.7.4):

- `var-set`, `map-set` or `map-delete`;
- a `*-mint?`, `*-burn?` or `*-transfer?` primitive;
- a `contract-call?` or `contract-call-raw?` whose callee is not statically
  read-only, meaning neither declared read-only in the callee's `abi.types` nor
  marked `read-only` in the trait it is called through.

Every function has a summary, monomorphic ones included, carrying its first
write and its first non-read-only call. The check is one pass over the instance
graph. Each call site or direct write in the read-only function's body that
reaches a write is one error, reported once, naming the path.
`emit` is not in the spec's list (section 14, item 11).

## 9. Primitive signatures as data

Every primitive's type is one entry in a table, written in chapter 3's own
signature notation. A few entries, each read as a sentence:

```
(prim + (for I (int uint)) (I I...) -> I :pure)
```

`+` has two overloads, one for `I = int` and one for `I = uint`. It takes one
`I`, then one or more further `I`s (`I...` is a rest parameter), and returns an
`I`. `:pure` means it reads no state, so a static constant may use it.

```
(prim concat (S[N] S[M]...) -> S[N + M...] :pure)
```

`S` is a sequence kind (`buff`, `string-ascii`, `string-utf8` or `list`), and
`S[N]` is a sequence of that kind with bound `N`. `concat` takes one sequence,
then one or more of the same kind, and the result's bound is the sum of all the
bounds.

```
(prim fold-left ((function (A elem(S)) A) A S[N]) -> A :fixpoint A :pure)
```

The first argument names a function from an accumulator `A` and an element of
`S` to a new `A`. `:fixpoint A` says `A` is solved by the capped fixpoint of
section 6.6, not by a single lub.

```
(prim to-consensus-buff (T) -> (buff (serialized-size T)) :where (storable T) :pure)
```

The result bound is computed from the argument's type, and `:where` adds a
constraint checked after instantiation: `T` must be storable.

```
(prim map-set ((map K V) K V) -> bool :effect write)
```

The first argument must name a map (a reference kind, which binds `K` and `V`
exactly to the map's declared types). `:effect write` is what read-only
enforcement looks for.

```
(prim uint-to-buff-be (uint (size W)) -> (buff W) :where (<= W 16) :pure :form dedicated)
```

The second argument is a size written in the source, not a value. `:form
dedicated` says the primitive has its own grammar rule, because ordinary call
syntax cannot pass a size.

How the table is used:

- **A gate test** extracts every signature from the chapter 3 tables and
  requires it to equal the table entry, so the spec and the checker cannot
  drift.
- **The generic instantiation of section 6.2 handles every entry.** Families
  written "for `I` in {...}" are overloads, so `(+ (panic) (panic))` is
  `T-AMBIG`. A sequence-kind variable is one candidate whose kind an argument
  must fix. No primitive has its own typing code. Only the special forms of
  section 7 do, and they are grammar forms, not primitives.
- **Attributes feed other rules.** `:pure` marks the primitives usable in static
  constants, `:effect` feeds read-only enforcement and the IR's facts, and
  `:fixpoint` marks the accumulator.

Section 13 asks chapter 3 to keep its signature cells in this regular form.

## 10. Diagnostics

### 10.1 Shape and codes

```
Diagnostic = { code, primary span, message, labels: [(span, text)],
               chain: [instantiation frames], hint }
```

Codes are stable identifiers: `P-*` for parse errors, `Cn` for the rules of
spec 5.4, `R-*` for resolution, `G-*` for the graph, `T-*` for typing, `V-*` for
the version, `X-*` for exhaustion. Only the verdict is normative. Conformance
vectors assert `CODE@line`, never message text.

### 10.2 One error, one diagnostic

An error is independent of another when fixing the other would leave it. Every
independent error is reported once, and nothing else is. Poison (section 5.2)
marks what follows from an error already reported:

- **Arguments.** A failed or poison argument makes the call poison only when its
  parameter mentions a type or size variable, since the argument is then a bound
  of that variable. Otherwise the call's other arguments are still checked, and
  the call keeps the callee's result type: a declared or inferred monomorphic
  result, a primitive's fixed result, or a variable fixed by the other
  arguments. A kept result never creates a failing instance: if the instance at
  the kept substitution would fail, the call is poison. A failed spread argument
  is poison, since it sets the rest count; a poison rest argument is not.
- **Instances.** A failed instance is poison to every caller, and a reused
  instance adds nothing.
- **Function bodies.** A function whose body failed still exports its declared
  parameters: its callers are checked against them, and `impl-trait`
  conformance is checked against them (the result part is skipped when the
  result is inferred).
- **Read-only.** No read-only error is derived from a body or an instance that
  failed to type-check.
- **Coercions.** An `as` that fails is poison.
- **Overloads.** An overload group that failed the overlap check is poison to
  its callers.
- **Sizes.** Each use of a constant that cannot be a size is reported at that
  use.

**Where an error is reported.** The primary span is the part at fault: an
argument that fails against the type fixed by the signature or by the other
arguments; the scrutinee of a `match` whose type has no arm shape; the first arm
of a pair that does not fit the scrutinee; a call only when no single part is at
fault (arity, no candidate, ambiguity, no lub among several arguments).

**Instance errors** (spec 2.6.2) are reported at the call that created the
instance, naming the definition and σ, with the chain back to the user's code.
The primary span is the nearest creating call in the contract. The place inside
the body is a label (or `prelude.clar:L:C` for prelude instances). An instance
is checked once, so its error is reported once. Every other call that reaches
the same failing instance is listed in that one diagnostic as an extra
"also instantiated here" line pointing at the call, not as a second error.

**Where a failed list lub is reported.** Having a lub is monotone in the set,
so bisection finds the first element whose prefix has none, and the diagnostic
points at it, not at the list.

### 10.3 Where a parse error is reported

A parse error is reported at the first byte at which the source stops being a
prefix of any valid source: the earliest point of failure, not where error
recovery resumes. When the source ends early there is no such byte, and the
error is on the line of the last byte (a final line feed belongs to the line it
ends). An empty source reports line 1. The position can be computed exactly at
the token level by a general recognizer, such as Earley's, run over the grammar
file of spec chapter 5, so the grammar stays the single source. The error nodes
of an error-recovering parser start wherever its recovery chose, so they cannot
be used for this.

## 11. Determinism, checking time and capacity

### 11.1 Determinism

- Anything iterated to produce output is an ordered map.
- Candidates are tried in definition order, and all of them are tried.
- Instances are created in a fixed traversal: roots in source order, bodies left
  to right.
- Size arithmetic is exact.
- Diagnostics are sorted by (span, code).
- A test shuffles definition order and hash seeds and requires an identical
  verdict, `abi.types` and diagnostic set.

### 11.2 Checking time

Checking can take time exponential in the source: definitions that each call
the next at two types double the instances at every level. The language sets no
bound on this work. A contract whose instances grow exponentially also has an
exponential module, which the chain's module size limit rejects, and a compiler
stops expanding once that limit is passed (spec 2.8).

This is not runtime cost. Runtime cost is the chain's fuel, charged per Wasm
instruction and host call while a module runs (chain ABI section 9), which the
checker does not compute.

### 11.3 Capacity

The language has no limit on nesting depth or source size. The grammar draft's
limits (128 levels, 2 MiB) were kept out of the spec, so a contract nested 500
levels deep is valid.

A real implementation still has a capacity. A recursive-descent parser or
checker uses one stack frame per nesting level, and a thread's stack is finite,
typically 8 MiB for the main thread and less for others. Past that, the process
crashes with a stack overflow and gives no verdict at all. There are two ways to
avoid the crash:

- **Explicit stacks.** Write the deep traversals as loops over a heap-allocated
  stack. This needs no limit, but costs effort in every recursive pass.
- **A large reserved stack plus a stated capacity.** Run parsing and checking on
  a thread with a large stack (hundreds of MiB is cheap, since it is reserved,
  not committed). Then check the nesting depth right after parsing, against a
  constant well inside that stack, such as 1,000 levels. Below the constant,
  everything is checked; above it, the checker stops before recursing.

The rule this proposal sets: **beyond its capacity, a checker answers
`Exhausted`, never `Reject` and never a crash.** Rejecting would claim the
contract is invalid, which the spec does not say. A crash gives no answer. Since
capacities differ between implementations and machines, an `Exhausted` verdict
says "this checker cannot decide", like `Unsupported`, and never contradicts a
checker with a larger capacity.

## 12. Outputs

### 12.1 `abi.types`

The `abi.types` section (value interpretation section 5) is emitted from the
checked program:

- functions, with parameter names and inferred results;
- NFTs, events and traits;
- `implements`;
- storage, with key prefixes.

It is golden-tested. Its byte layout is open (value interpretation section 9).

### 12.2 The typed IR

The IR has two levels. The names are this proposal's own, in the style of
rustc's HIR and MIR:

- **TIR** (typed IR) is one body per instance, with macro calls still in place.
  It is what P4 produces and what a language server can use for hover and
  go-to-definition.
- **XIR** (expanded IR) is the compiler's input:
  - macros are expanded with fresh binders;
  - every `return` is coerced to its function's result;
  - every place where a value is consumed at a wider type than it was produced
    at has an explicit `Coerce` node;
  - every call names its instance or its primitive overload, with the concrete
    instantiation.

The IR also carries per-instance facts: storage footprint, effects, static call
depth, fold bounds and callees. Binders are per instance: a binder in a template
body has one type per instance.

### 12.3 What the compiler gains from the IR

- **Nothing is inferred twice.** The compiler reads every type, instance and
  overload choice from the IR. It never re-runs lub or least instantiation, so
  it cannot disagree with the checker about a type. That was a source of
  miscompilation risk when code generators recomputed bounds on their own.
- **Representation follows the type.** Each value's Wasm representation is a
  function of its type alone. A `Coerce` node says exactly where a value changes
  type (a wider bound, an empty `never` side filled in), and one generic
  conversion per pair of types lowers it.
- **Sizes are concrete.** `concat`'s result bound, a fold's final accumulator
  and every list length are in the IR, so buffer sizes and loop bounds come from
  it directly.
- **One verified boundary.** A linear verifier re-checks XIR on every compile:
  every type ground and within limits, every consumption at exactly its own type
  or through a `Coerce`. A failure is a compiler bug caught before code
  generation, never a user error.
- **Analyses get facts for free.** Storage footprints, effects, call depths and
  fold bounds feed static cost bounds and asset-flow analyses (`clarity-analyzer`
  in [03-architecture.md](03-architecture.md) section 2) without another pass
  over the source.

## 13. Changes to the spec

These are positions this proposal asks the spec to take. None changes the
language's design.

1. **Implementation capacity** (2.8). State that an implementation may have a
   capacity limit (nesting, source size), and that exceeding it is not a
   verdict on the contract (section 11.3).
2. **Call depth counting** (2.7.5). State the rules of section 8.2: macros add
   no frame, callbacks add one, a call counts the overload it resolves to, the
   depth is measured on instances rather than on the definition graph (which
   does not say which overload or function argument a call reaches), and the
   error is at the entry point.
3. **256 parameters** (2.4.1). Value interpretation 5.1 bounds functions and
   trait functions at 256 parameters, and chapter 2 should say so for public and
   read-only functions and trait signatures, since a contract declares all of
   them.
4. **Type depth** (2.8). State how depth is counted (section 5.3). Value
   interpretation 4.1 says only "counted the same way everywhere".
5. **Overload groups** (2.4.1, 5.4 C1). One name may not have both
   `define-private` and `define-macro` definitions.
6. **Top-level responses** (2.4.1, C3). State that top-level forms are not an
   expression sequence, so a top-level `(ok u1)` is not C3.
7. **Trait function results.** Chapter 2 requires every trait function's result
   to be a `response`. Value interpretation 5.1 lets a read-only one have any
   type, as a read-only function may. Align chapter 2 with value interpretation.
8. **Primitive notation** (chapter 3). Keep every signature cell in the regular
   notation of section 9, so it stays mechanically comparable with a checker's
   table.
9. **The answers to section 14**, once decided, each with a conformance vector.

## 14. Open questions

Each question is a place where the spec text can be read more than one way. The
proposed answer is what this design implements until the spec decides.

| #   | Question                                                                                                                                                                                                               | Readings                                                                             | Proposed answer                                                                                                                                                                                                                                                                                                                                                                                                                          |
| --- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | An instance error: one diagnostic, or one at every call that uses the failing instance?                                                                                                                                | once; at every call                                                                  | One diagnostic, at the first creating call, with one "also instantiated here" line per other call (section 10.2). The verdict is the same either way.                                                                                                                                                                                                                                                                                    |
| 2   | A contract-literal type in an inferred public or read-only result (`(define-read-only (tok) .tok)`)?                                                                                                                   | C5 error; widen to `principal`                                                       | Error, with the hint `(as principal .tok)`. Types stay complete (chain ABI R3), and widening is one `as` away.                                                                                                                                                                                                                                                                                                                           |
| 3   | Rest arguments: individual lower bounds, or a list typed on its own first (2.6.5, "typed by 2.5.6")?                                                                                                                   | individual; list first                                                               | Individual bounds: one set lub (K2). The readings differ only for trait-typed arguments.                                                                                                                                                                                                                                                                                                                                                 |
| 4   | A name in type position that names a constant, function or primitive (2.3.5)?                                                                                                                                          | a type variable; an error                                                            | Error. A misspelt or shadowed name should not silently become a type variable.                                                                                                                                                                                                                                                                                                                                                           |
| 5   | One name used as both a type variable and a size variable in one definition?                                                                                                                                           | allowed; an error                                                                    | Error.                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| 6   | Static constants (2.4.1): which forms make a constant static?                                                                                                                                                          | primitives only; primitives plus constructors, `get`, `merge`, `as`; arithmetic only | Open: needs a design discussion. The choice decides which constants can be sizes and `contract-call?` targets. Until it is decided, the checker reads the text narrowly: literals and static constants combined only by primitives (`as-max-len?`, the `*-to-buff-*` and `from-consensus-buff?` forms included: chapter 3 primitives with their own syntax, spec 2.5). Constructors (`some`, `ok`, `err`, `list`, tuples), `get`, `merge` and `as` do not make a constant static. |
| 7   | Sub-trait "identical signature": must the `read-only` marks match exactly?                                                                                                                                             | exactly; the super-trait's marks required, more allowed                              | Exactly, as written: a trait function's signature includes its kind (value interpretation 5.2). So `(trait ro)` and `(trait rw)`, which differ only in a `read-only` mark, are not subtypes of each other, although they meet: one read-only implementation satisfies both. Allowing more marks in the sub-trait would be a spec change.                                                                                                 |
| 8   | Trait meet: the stated rule ("no shared function with different signatures") or the definition ("a never-free common subtype")? Under conformance, one contract can implement both `f ((buff 10))` and `f ((buff 5))`. | stated rule; definition                                                              | Keep the stated rule and drop "since a contract could then implement both". A call that both overloads admit is still rejected as ambiguous.                                                                                                                                                                                                                                                                                             |
| 9   | Event-kind variables that also occur elsewhere (2.6.2)?                                                                                                                                                                | solved elsewhere, event bounds; matched exactly                                      | As the spec says: solved by their other occurrences, with the event's declared type as an upper bound.                                                                                                                                                                                                                                                                                                                                   |
| 10  | Top-level responses (C3)?                                                                                                                                                                                              | not an error; an error                                                               | Not an error (section 13, item 7).                                                                                                                                                                                                                                                                                                                                                                                                       |
| 11  | May a read-only function `emit` (2.7.4 does not list it)?                                                                                                                                                              | yes; no                                                                              | Yes, by the text. Ask whether events from read-only calls are intended.                                                                                                                                                                                                                                                                                                                                                                  |
| 12  | Several interdependent `(function ...)` parameters?                                                                                                                                                                    | rounds; unspecified                                                                  | Rounds in parameter order, capped at 8.                                                                                                                                                                                                                                                                                                                                                                                                  |
| 13  | Sizes: cap at `2^32 − 1` (the encoding's length field)?                                                                                                                                                                | exact u128; capped                                                                   | Cap them, so implementations can use 64-bit arithmetic.                                                                                                                                                                                                                                                                                                                                                                                  |
| 14  | A literal of the current contract used at a trait type needs the contract's own inferred interface.                                                                                                                    | error; graph edge to every public function                                           | Error.                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| 15  | A non-static expression of contract-literal type as a `contract-call?` target?                                                                                                                                         | static target; rejected                                                              | Static target: the type pins the callee.                                                                                                                                                                                                                                                                                                                                                                                                 |
| 16  | Is a function whose only parameters of unknown type are references generic?                                                                                                                                            | an instance per reference argument; checked once                                     | An instance per reference argument (section 6.3).                                                                                                                                                                                                                                                                                                                                                                                        |
| 17  | A reference name used as a value (`(+ v u1)` with `v` a `(var uint)`): a scope error or a type error?                                                                                                                  | scope; type                                                                          | A scope error (section 4, P1), so a body that is never instantiated still reports it.                                                                                                                                                                                                                                                                                                                                                    |

## 15. Implementation order

A checker can be built in stages. Each stage fully checks the contracts that
use only its features, and answers `Unsupported` for the rest (K5). A
reasonable order:

1. the type algebra: representation, subtyping, lub, meet, traits;
2. resolution and the definition graph (P1, P2);
3. expressions and the primitive table;
4. definitions, monomorphic functions and `abi.types`;
5. generics, reference kinds, rest parameters and spread;
6. overloads and the overlap check;
7. macros;
8. function references and the fold fixpoint, after which the whole prelude
   checks;
9. cross-contract calls, traits across contracts and `impl-trait`, after which
   the whole language checks;
10. read-only enforcement and the inferred-interface rules;
11. the typed IR and its verifier;
12. hardening (fuzzing, determinism suite).
