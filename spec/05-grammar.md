# 5. Grammar

The syntax of vNEXT source text is defined by the grammar in
[grammar/clarity.ebnf](grammar/clarity.ebnf), written in ISO/IEC 14977 EBNF.
Chapters 2 and 3 introduce each form with the grammar rules that define it,
shown in a reading notation (5.1); this chapter explains how to read the grammar
and states the conditions that sit beside its rules. Every rule in the file
cites the section of chapter 2 or 3 it formalises. Rule names are snake_case.

## 5.1 Reading the grammar

The grammar file uses the meta-symbols of ISO 14977. Chapters 2 and 3 show the
same rules in a reading notation, the one most language references use in their
prose (the W3C XML recommendation, the Python and Rust references; Go's EBNF
also drops the commas): a sequence is written by juxtaposition and repetition
with postfix `?`, `*` and `+`. The two notations differ only in their symbols
and line layout; the grammar file governs.

| Chapters 2 and 3        | Grammar file (ISO 14977) | Meaning                                                                                                                                              |
| ----------------------- | ------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| `a ::= b`               | `a = b ;`                | rule `a` is defined as `b`                                                                                                                           |
| `a b`                   | `a, b`                   | `a` followed by `b`                                                                                                                                  |
| <code>a &#124; b</code> | <code>a &#124; b</code>  | `a` or `b`                                                                                                                                           |
| `a?`                    | `[a]`                    | zero or one `a`                                                                                                                                      |
| `a*`                    | `{a}`                    | zero or more `a`                                                                                                                                     |
| `a+`                    | `a, {a}`                 | one or more `a`                                                                                                                                      |
| `a{0,n}`                | `n * [a]`                | at most `n` repetitions of `a`                                                                                                                       |
| `a - b`                 | `a - b`                  | an `a` that is not a `b`                                                                                                                             |
| `(a)`                   | `(a)`                    | grouping                                                                                                                                             |
| `<text>`                | `? text ?`               | a special sequence: a character that has no visible terminal (TAB, LF) or the end of input, defined in prose; special sequences occur only in Part L |
| `"x"`, `'x'`            | `"x"`, `'x'`             | a terminal string; it has no escapes, so `"\"` is one backslash                                                                                      |

In the reading notation the postfix operators bind tightest, then `-`, then
juxtaposition, then `|`.

There are no character ranges: every character class is spelled out. Rule names
use `_` between words, which strict ISO 14977 does not allow in a
meta-identifier; read `string_ascii_literal` as one name. Likewise the `§` in
the rule comments is outside the ISO 646 character set the standard assumes;
comments are not part of the grammar.

The grammar has two levels:

- **Part L, lexical**, turns the characters of the source into tokens and
  separators (whitespace and comments).
- **Part S, syntactic**, works on the tokens that remain once the separators are
  removed. In Part S a quoted word such as `"define-public"` stands for an
  identifier token with exactly that text, the punctuation `( ) { } : , ...`
  stands for the punctuation tokens, and a token name stands for any token of
  that kind. The token names are `identifier`, `natural_literal`,
  `negative_int_literal`, `uint_literal`, `buffer_literal`,
  `string_ascii_literal`, `string_utf8_literal`, `standard_principal_literal`,
  `contract_principal_literal` and `trait_identifier_literal`; no Part S rule
  names any other Part L rule.

The start symbol is `contract`: a version declaration followed by the top-level
forms (2.4.0). The lexical start symbol is `source_text`.

## 5.2 Tokens and layout

Four normative rules govern tokenization. T1 and T2 are not context-free, so
they are stated here rather than as grammar rules; T3 restates which characters
Part L admits, and T4 defines the parse error:

- **T1, longest match.** At each position after separators, the token is the
  longest prefix that matches some alternative of `token`. `-7` is one negative
  integer literal, `0xab` one buffer literal, `.c.t` one trait identifier and
  `u"x"` one UTF-8 string literal. A position where no token matches, such as an
  unterminated `"abc` or the escape `"\q"`, is an error.
- **T2, atom delimiter.** A token other than punctuation must be followed by an
  `atom_delimiter`: a separator, one of `( ) { } : ,`, the first dot of `...`,
  or the end of the source. Otherwise the source does not lex: `u2f`, `-7a`,
  `0xabc`, `a.b` and `a"x"` are errors, not two tokens.
- **T3, characters.** Outside string literals and comments, a character that
  cannot start a token or a separator is an error, such as a lone `;`. A
  carriage return, any non-ASCII character, any other control character except
  TAB and LF, and DEL are errors anywhere, string literals and comments
  included. Non-ASCII text in a `u"..."` literal is written with `\u{H}`.
- **T4.** An error of tokenization is a parse error. A **parse error** is any
  violation of the grammar, of T1-T3, of W1 or of the lexical checks (5.3): the
  source is rejected before any type checking.

**Layout rule W1.** For two consecutive tokens `A B`:

| Case                                               | Separator between `A` and `B` |
| -------------------------------------------------- | ----------------------------- |
| `B` is `...`                                       | forbidden                     |
| `A` is one of `( { : ,` or `B` is one of `) } : ,` | optional                      |
| otherwise                                          | required                      |

The first row is checked first. So `(let ((x u1)) x)`, `{a:u1,b :u2}` and
`(+ a xs...)` are fine, while `(a)(b)`, `x(f)`, `(f)x`, `(f(g))`, `xs ...` and
`{a:1}{b:2}` are parse errors, at top level and inside a form. The rule makes
token boundaries visible: two atoms, or an atom and a form, never touch, so
`x(f)` cannot be misread as a call of `x`. A ported legacy source may need to be
reformatted for this rule and for the rejection of carriage returns (T3), and
rewritten where it uses non-ASCII text, escapes with leading zeros such as
`\u{00e9}`, numerals with leading zeros or keywords as names (2.2).

## 5.3 Lexical checks

These conditions are parse errors, like a violation of W1. LX1 to LX5 are
checked on the token; LX6 and LX7 depend on where the token occurs and are
checked on the derivation.

| Check | Condition                                                                                                                                                                                                                                                                                                                                |
| ----- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| LX1   | A negative integer literal is at least -2^127 (the sign is applied first, so `-170141183460469231731687303715884105728` is valid).                                                                                                                                                                                                       |
| LX2   | An unsigned numeral is at most 2^128-1 in every position; the value of a numeral ignores its `_` separators (2.2). A size in a type has no other bound here: a size above a limit of 2.8 is a static error. A numeral used as an `int` has the tighter bound of LX6.                                                                     |
| LX3   | A `u` literal is at most 2^128-1.                                                                                                                                                                                                                                                                                                        |
| LX4   | A standard principal, also inside a contract principal or trait identifier, is a valid c32check encoding of a version and a 20-byte hash, whose version character may be any character of the alphabet, a version from 0 to 31 (2.2). The alphabet and the checksum are those of [c32check](https://github.com/stacks-network/c32check). |
| LX5   | A `\u{H}` escape names a Unicode scalar value that is not TAB, LF, CR or printable ASCII: printable ASCII is written as itself, except `"` and `\`, written `\"` and `\\`, and TAB, LF, CR only as `\t`, `\n`, `\r`.                                                                                                                     |
| LX6   | A numeral used as an `int` (any expression position, including the value of `define-constant`, the arguments of an application and a bare numeral where a size term is expected) is at most 2^127-1: `(f 170141183460469231731687303715884105728)` is a parse error, while the same digits as a size in a type are not.                  |
| LX7   | The version number is at least 1.                                                                                                                                                                                                                                                                                                        |

Length bounds are not checks but part of the token rules: an identifier has 1 to
128 characters, a contract name 1 to 40, a trait name 1 to 128.

## 5.4 What the grammar leaves to the type checker

The grammar accepts the following and the type checker rejects them, as static
errors. The list names the rules a reader of the grammar is most likely to look
for; it is not exhaustive, and chapters 2 and 3 state every static rule.

| Rule | Static error                                                                                                                                                                                                                                    |
| ---- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| C1   | Shadowing, or rebinding a reserved name (primitive or prelude definition) or a top-level definition, including a second top-level definition of the same name other than an overload of `define-private` or `define-macro` (2.2, 2.5.2, 2.6.2). |
| C2   | `return` in a top-level expression or in a `define-constant`, `define-data-var` or `define-fungible-token` initializer (2.4.2, 2.5.4).                                                                                                          |
| C3   | An unhandled intermediate response in a body (2.4.1).                                                                                                                                                                                           |
| C4   | A non-storable type where a storable type is required (2.3.4).                                                                                                                                                                                  |
| C5   | A non-interface type where an interface type is required (2.3.4).                                                                                                                                                                               |
| C6   | A type or size variable outside `define-private` and `define-macro`, or one that occurs in no parameter type (2.3.5).                                                                                                                           |
| C7   | A macro value parameter referenced more than once (2.6.3).                                                                                                                                                                                      |
| C8   | More than 128 allowances in one `as-contract?` or `restrict-assets?` (2.8).                                                                                                                                                                     |
| C9   | A `match` arm pair that is not the pair the scrutinee type requires, or a scrutinee of type `never` (2.5.3).                                                                                                                                    |
| C10  | A bare trait name in type position; the type is written `(trait X)` (2.3.1, 2.3.5).                                                                                                                                                             |
| C11  | A bare `int` literal where a size term is expected: `(as-max-len? s 4)` is a type error, `(as-max-len? s u4)` is not (2.3.1).                                                                                                                   |
| C12  | A name in a size position (`type_size` or `size_term`) that is not a size variable or a static `uint` constant, such as a `let`-bound variable (2.3.1, 2.3.5).                                                                                  |
| C13  | Two parameters with the same name in one definition (2.4.1).                                                                                                                                                                                    |
| C14  | An argument in a reference-kind position that is not a definition of the matching kind (2.3.7).                                                                                                                                                 |
| C15  | Two fields with the same name in one tuple constructor or tuple type (2.5.6, 2.3.1).                                                                                                                                                            |

Typing, the arity of applications, overload resolution, reference-kind matching
and which calls accept a spread argument (2.6.5) are also left to the type
checker; the grammar already fixes the arity of every special form and of the
seven dedicated primitive forms, and makes a spread the last argument.

## 5.5 The standard library

[std/prelude.clar](std/prelude.clar) is ordinary vNEXT source. It is parsed as a
`contract` with a version declaration prepended, since it has none of its own:
the version of the contract that includes it (chapter 4).

## 5.6 Limitation

A foreign function, field or trait whose name is not a vNEXT identifier (2.2)
cannot be named in source: one that starts like a number (`u1`, `u1x`, `-7`), or
has other characters or more than 128 of them. `.c.u1` is a parse error.

## 5.7 Examples

Each line shows how the rules decide a case, with a valid and an invalid
example; the sections in the first column explain the rule.

| Case                                       | Valid                                                               | Parse error                                            |
| ------------------------------------------ | ------------------------------------------------------------------- | ------------------------------------------------------ |
| Separator before `(` (W1)                  | `(list x (- 0 x))`                                                  | `(list x(- 0 x))`                                      |
| Line ends (T3)                             | LF                                                                  | CR LF, or a lone CR                                    |
| Comments (T3)                              | `;; total in uSTX`                                                  | a comment holding any non-ASCII character, such as `é` |
| Identifiers that start like a number (2.2) | `u-1`, `u+1`, `-x`, `+u`                                            | `u1x`, `+5`, `-u1`, `+u1`                              |
| Leading zeros (2.2)                        | `0`, `7`, `u0`                                                      | `007`, `u00`, `-0`                                     |
| Digit separators (2.2)                     | `1_000_000`, `u2_500`, `-1_000`                                     | `1_`, `1__000`, `0_1`                                  |
| `\u{H}` escapes (2.2, LX5)                 | `u"caf\u{e9}"`                                                      | `u"\u{41}"`, `u"\u{0e9}"`                              |
| Size spelling in a type (2.3.1)            | `(buff 32)`                                                         | `(buff u32)`                                           |
| Size spelling in an argument (2.3.1)       | `(as-max-len? s u32)`                                               | `(as-max-len? s (+ u1 u1))`                            |
| Trailing comma in a tuple (2.3.1, 2.5.6)   | `{ a: u1, }`                                                        | `{ a: u1,, }`, `{,}`                                   |
| Version number (2.4.0)                     | `(clarity-version 1)`                                               | `(clarity-version 0)`, `(clarity-version 01)`          |
| Keywords as names (2.2, 2.5.1, 2.5.2)      | `{ list: u1 }`, `(define-trait t ((list () (response bool uint))))` | `(let ((list u1)) list)`                               |
| `match` arms (2.5.3)                       | `(match o ((some v) v) (none u0))`                                  | `(match o (none u0) (none u1))`                        |
| `map` (3.3)                                | `(map f xs)`                                                        | `(map f xs ys)`, `(map f xs...)`                       |

## 5.8 Open questions

1. **Version numbering.** The grammar's `version_number` is one number, as 2.4.0
   says today; it follows the decision on 2.9 question 1 (a single integer or a
   major and minor pair).
