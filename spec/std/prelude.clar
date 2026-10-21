;; Clarity vNEXT standard library prelude (working draft)
;;
;; This file is ordinary vNEXT source. It uses only features available to
;; every contract: generics (implicit type variables), macros with
;; call-by-name parameters, overloading, static references, `match`,
;; `return`, and the primitives in ../03-primitives.md.
;;
;; Scope: everything a contract author uses that can be written in the
;; language (layering rule, README.md). Definitions are written for clarity
;; and correctness, not speed. Cost is the Wasm fuel of the compiled code, so
;; a faster Wasm implementation can replace any definition later without
;; changing its results (chapter 4.1).
;;
;; Conventions:
;;   define-macro   for anything needing laziness or early exit
;;   define-private for everything else
;;   fold-left      calls (step accumulator element), so helpers take acc first
;;   (name T...)    a rest parameter: the extra arguments as a list (2.6.5)
;;   std-*          helper definitions; reserved like every prelude name
;;
;; Generic bodies are checked per instance (template semantics, chapter
;; 2.6.2). Where a comment says "`T` is instantiated at ...", any other
;; instantiation is a type error at the call site.
;;
;; Each value parameter of a macro is referenced at most once in
;; its body; bodies that need a value twice bind it with `let` first.

;; ---------------------------------------------------------------------------
;; Branching
;; ---------------------------------------------------------------------------

;; `if` is sugar over `match` on bool. `and` and `or` are core forms, since
;; short-circuiting over any number of arguments cannot be written here
;; (chapter 2.5.3).
(define-macro (if (condition bool) (then T) (else T))
  (match condition
    (true then)
    (false else)))

;; Private so it can be passed to `filter`.
(define-private (not (value bool))
  (if value false true))

;; ---------------------------------------------------------------------------
;; Comparison
;; ---------------------------------------------------------------------------

;; `T` is instantiated at a type `<=` accepts (chapter 3.2). Both arguments
;; are evaluated before the call, so swapping them in the body does not change
;; evaluation order.
(define-private (>= (left T) (right T))
  (<= right left))

(define-private (> (left T) (right T))
  (not (<= left right)))

(define-private (< (left T) (right T))
  (not (<= right left)))

;; ---------------------------------------------------------------------------
;; Early exit
;; ---------------------------------------------------------------------------

(define-macro (asserts! (condition bool) (thrown E))
  (if condition true (return thrown)))

;; `thrown` is evaluated only on failure. For `unwrap!` and `unwrap-err!`
;; this is a change from legacy, which evaluated it before the check;
;; `asserts!` was already lazy.
(define-macro (unwrap! (value (optional T)) (thrown E))
  (match value
    ((some inner) inner)
    (none (return thrown))))

(define-macro (unwrap! (value (response T E)) (thrown F))
  (match value
    ((ok inner) inner)
    ((err ignored) (return thrown))))

(define-macro (unwrap-err! (value (response T E)) (thrown F))
  (match value
    ((ok ignored) (return thrown))
    ((err inner) inner)))

(define-macro (try! (value (optional T)))
  (match value
    ((some inner) inner)
    (none (return none))))

(define-macro (try! (value (response T E)))
  (match value
    ((ok inner) inner)
    ((err inner) (return (err inner)))))

(define-macro (unwrap-panic (value (optional T)))
  (match value
    ((some inner) inner)
    (none (panic))))

(define-macro (unwrap-panic (value (response T E)))
  (match value
    ((ok inner) inner)
    ((err ignored) (panic))))

(define-macro (unwrap-err-panic (value (response T E)))
  (match value
    ((ok ignored) (panic))
    ((err inner) inner)))

;; Private, so both arguments are evaluated before the call, as in legacy.
(define-private (default-to (default T) (value (optional T)))
  (match value
    ((some inner) inner)
    (none default)))

;; ---------------------------------------------------------------------------
;; Predicates (private so they work with `filter`)
;; ---------------------------------------------------------------------------

(define-private (is-some (value (optional T)))
  (match value ((some ignored) true) (none false)))

(define-private (is-none (value (optional T)))
  (match value ((some ignored) false) (none true)))

(define-private (is-ok (value (response T E)))
  (match value ((ok ignored) true) ((err ignored) false)))

(define-private (is-err (value (response T E)))
  (match value ((ok ignored) false) ((err ignored) true)))

;; ---------------------------------------------------------------------------
;; Arithmetic
;; ---------------------------------------------------------------------------

;; `T` is any type `<=` accepts: int, uint, or a buffer or string type, which
;; compare lexicographically (chapter 3.2: bytes for buffers and ASCII
;; strings, code points for UTF-8 strings). (max a b c) folds the binary helper
;; over (list b c) starting from a.
(define-private (std-max-pair (left T) (right T))
  (if (> left right) left right))

(define-private (max (left T) (right T...))
  (fold-left std-max-pair left right))

(define-private (std-min-pair (left T) (right T))
  (if (< left right) left right))

(define-private (min (left T) (right T...))
  (fold-left std-min-pair left right))

;; Aborts on the most negative int, as `(- 0 x)` overflows there.
(define-private (abs (value int))
  (if (< value 0) (- 0 value) value))

;; `T` is instantiated at int or uint. Division truncates toward zero, so the
;; remainder takes the sign of the dividend. A zero divisor aborts in `/`, as
;; does the most negative int with divisor -1, although its remainder is 0.
(define-private (mod (dividend T) (divisor T))
  (- dividend (* (/ dividend divisor) divisor)))

;; `T` is instantiated at int or uint. Each bit of `a xor b` is set where
;; exactly one input has it, and `a and b` where both do; the two never overlap,
;; so their xor is the or.
(define-private (std-bit-or-pair (left T) (right T))
  (bit-xor (bit-xor left right) (bit-and left right)))

(define-private (bit-or (left T) (right T...))
  (fold-left std-bit-or-pair left right))

(define-private (bit-not (value int))
  (bit-xor value -1))

(define-private (bit-not (value uint))
  (bit-xor value u340282366920938463463374607431768211455))

;; Exponent bit positions, most significant first.
(define-constant std-exponent-bits
  (list u31 u30 u29 u28 u27 u26 u25 u24 u23 u22 u21 u20 u19 u18 u17 u16
        u15 u14 u13 u12 u11 u10 u9 u8 u7 u6 u5 u4 u3 u2 u1 u0))

;; Square-and-multiply, most significant bit first. Every intermediate value
;; is `base` raised to a prefix of the exponent's bits, so no step overflows
;; unless the final result does. `T` is int or uint.
(define-private (std-pow-step (acc { base: T, exponent: uint, result: T })
                              (shift uint))
  (let ((squared (* (get result acc) (get result acc))))
    (merge acc
      { result: (if (is-eq (bit-and (bit-shift-right (get exponent acc) shift) u1) u1)
                  (* squared (get base acc))
                  squared) })))

;; Aborts if the exponent is negative or does not fit in 32 bits, or on
;; overflow.
(define-private (pow (base int) (exponent int))
  (if (or (< exponent 0) (> exponent 4294967295))
    (panic)
    (get result (fold-left std-pow-step
                  { base: base, exponent: (to-uint exponent), result: 1 }
                  std-exponent-bits))))

(define-private (pow (base uint) (exponent uint))
  (if (> exponent u4294967295)
    (panic)
    (get result (fold-left std-pow-step
                  { base: base, exponent: exponent, result: u1 }
                  std-exponent-bits))))

;; Even bit positions from 126 down to 0: the powers of four tried by the
;; bitwise square root.
(define-constant std-sqrti-shifts
  (list u126 u124 u122 u120 u118 u116 u114 u112 u110 u108 u106 u104 u102
        u100 u98 u96 u94 u92 u90 u88 u86 u84 u82 u80 u78 u76 u74 u72 u70
        u68 u66 u64 u62 u60 u58 u56 u54 u52 u50 u48 u46 u44 u42 u40 u38
        u36 u34 u32 u30 u28 u26 u24 u22 u20 u18 u16 u14 u12 u10 u8 u6 u4
        u2 u0))

(define-private (std-sqrti-step (acc { remainder: uint, root: uint })
                                (shift uint))
  (let ((bit (bit-shift-left u1 shift))
        (candidate (+ (get root acc) bit)))
    (if (>= (get remainder acc) candidate)
      { remainder: (- (get remainder acc) candidate),
        root: (+ (bit-shift-right (get root acc) u1) bit) }
      { remainder: (get remainder acc),
        root: (bit-shift-right (get root acc) u1) })))

(define-private (std-sqrti-uint (value uint))
  (get root (fold-left std-sqrti-step { remainder: value, root: u0 }
              std-sqrti-shifts)))

(define-private (sqrti (value uint))
  (std-sqrti-uint value))

;; Aborts on a negative argument.
(define-private (sqrti (value int))
  (if (< value 0)
    (panic)
    (to-int (std-sqrti-uint (to-uint value)))))

;; Binary search for the highest set bit.
(define-private (std-log2-step (acc { rest: uint, result: uint }) (shift uint))
  (let ((shifted (bit-shift-right (get rest acc) shift)))
    (if (is-eq shifted u0)
      acc
      { rest: shifted, result: (+ (get result acc) shift) })))

;; Aborts on zero.
(define-private (std-log2-uint (value uint))
  (if (is-eq value u0)
    (panic)
    (get result (fold-left std-log2-step { rest: value, result: u0 }
                  (list u64 u32 u16 u8 u4 u2 u1)))))

(define-private (log2 (value uint))
  (std-log2-uint value))

;; Aborts on an argument that is not positive.
(define-private (log2 (value int))
  (if (<= value 0)
    (panic)
    (to-int (std-log2-uint (to-uint value)))))

;; ---------------------------------------------------------------------------
;; Sequences
;; ---------------------------------------------------------------------------

;; (list N T) -> (list (+ N 1) T)
(define-private (append (items (list N T)) (item T))
  (concat items (list item)))

(define-private (std-index-of-step (acc { found: (optional uint), index: uint, target: T })
                                   (element T))
  (match (get found acc)
    ((some ignored) acc)
    (none (if (is-eq element (get target acc))
            (merge acc { found: (some (get index acc)) })
            (merge acc { index: (+ (get index acc) u1) })))))

;; `S` is instantiated at a sequence type and `E` at its element type.
(define-private (index-of? (items S) (item E))
  (get found (fold-left std-index-of-step
               { found: none, index: u0, target: item }
               items)))

;; Appends one element, per sequence kind: a list takes `(list item)` where the
;; other kinds take the one-element sequence itself.
(define-private (std-push (items (list N T)) (item T))
  (concat items (list item)))

(define-private (std-push (items (buff N)) (item (buff 1)))
  (concat items item))

(define-private (std-push (items (string-ascii N)) (item (string-ascii 1)))
  (concat items item))

(define-private (std-push (items (string-utf8 N)) (item (string-utf8 1)))
  (concat items item))

;; `flags` holds the predicate's result for every element, computed by `map`
;; before the fold, because the fold's step function cannot call the predicate
;; (chapter 2.3.6). `as-max-len?` holds `kept` at the input's bound `N`, so the
;; fold's fixpoint closes in one step.
(define-private (std-filter-step (acc { index: uint, flags: (list N bool), kept: K })
                                 (item E))
  { index: (+ (get index acc) u1),
    flags: (get flags acc),
    kept: (if (unwrap-panic (element-at? (get flags acc) (get index acc)))
            (unwrap-panic (as-max-len? (std-push (get kept acc) item) N))
            (get kept acc)) })

;; One definition per sequence kind, differing only in the empty start value.
;; The predicate is called once per element, left to right, by `map`.
(define-private (filter (keep (function (T) bool)) (items (list N T)))
  (get kept (fold-left std-filter-step
              { index: u0, flags: (map keep items), kept: (as (list N T) (list)) }
              items)))

(define-private (filter (keep (function ((buff 1)) bool)) (items (buff N)))
  (get kept (fold-left std-filter-step
              { index: u0, flags: (map keep items), kept: (as (buff N) 0x) }
              items)))

(define-private (filter (keep (function ((string-ascii 1)) bool)) (items (string-ascii N)))
  (get kept (fold-left std-filter-step
              { index: u0, flags: (map keep items), kept: (as (string-ascii N) "") }
              items)))

(define-private (filter (keep (function ((string-utf8 1)) bool)) (items (string-utf8 N)))
  (get kept (fold-left std-filter-step
              { index: u0, flags: (map keep items), kept: (as (string-utf8 N) u"") }
              items)))

;; One definition per sequence kind: a list takes `(list item)` where the
;; other kinds take the one-element sequence itself.
(define-private (replace-at? (items (list N T)) (index uint) (item T))
  (if (>= index (len items))
    none
    (as-max-len? (concat (concat (unwrap-panic (slice? items u0 index)) (list item))
                         (unwrap-panic (slice? items (+ index u1) (len items))))
                 N)))

(define-private (replace-at? (items (buff N)) (index uint) (item (buff 1)))
  (if (>= index (len items))
    none
    (as-max-len? (concat (concat (unwrap-panic (slice? items u0 index)) item)
                         (unwrap-panic (slice? items (+ index u1) (len items))))
                 N)))

(define-private (replace-at? (items (string-ascii N)) (index uint) (item (string-ascii 1)))
  (if (>= index (len items))
    none
    (as-max-len? (concat (concat (unwrap-panic (slice? items u0 index)) item)
                         (unwrap-panic (slice? items (+ index u1) (len items))))
                 N)))

(define-private (replace-at? (items (string-utf8 N)) (index uint) (item (string-utf8 1)))
  (if (>= index (len items))
    none
    (as-max-len? (concat (concat (unwrap-panic (slice? items u0 index)) item)
                         (unwrap-panic (slice? items (+ index u1) (len items))))
                 N)))

;; ---------------------------------------------------------------------------
;; Conversions
;; ---------------------------------------------------------------------------

;; The core has one conversion per pair of representations (`to-int`,
;; `to-uint`, `buff-to-uint-be`, `uint-to-buff-be`). Everything here is
;; derived from those.

(define-private (std-prepend-byte (acc (buff 16)) (byte (buff 1)))
  (unwrap-panic (as-max-len? (concat byte acc) u16)))

(define-private (std-reverse-16 (bytes (buff 16)))
  (fold-left std-prepend-byte 0x bytes))

(define-private (buff-to-uint-le (bytes (buff 16)))
  (buff-to-uint-be (std-reverse-16 bytes)))

;; Two's complement, sign-extended from the buffer's actual length, so 0xff
;; is -1 (legacy zero-padded a short buffer and gave 255; chapter 3.4). The
;; negative branch adds -2^(8L-1), computed without overflowing when L is 16.
(define-private (buff-to-int-be (bytes (buff 16)))
  (let ((magnitude (buff-to-uint-be bytes))
        (width (len bytes)))
    (if (is-eq width u0)
      0
      (let ((half (bit-shift-left u1 (- (* width u8) u1))))
        (if (< magnitude half)
          (to-int magnitude)
          (+ (to-int (- magnitude half))
             (- (- 0 (to-int (- half u1))) 1)))))))

(define-private (buff-to-int-le (bytes (buff 16)))
  (buff-to-int-be (std-reverse-16 bytes)))

;; |value| as a uint, including for the most negative int.
(define-private (std-magnitude (value int))
  (if (< value 0)
    (+ (to-uint (- -1 value)) u1)
    (to-uint value)))

;; Per-kind digit tables, selected by the text type.
(define-private (std-prepend-digit (digit uint) (text (string-ascii 40)))
  (unwrap-panic (as-max-len? (concat (unwrap-panic (element-at? "0123456789" digit)) text) u40)))

(define-private (std-prepend-digit (digit uint) (text (string-utf8 40)))
  (unwrap-panic (as-max-len? (concat (unwrap-panic (element-at? u"0123456789" digit)) text) u40)))

;; u340282366920938463463374607431768211455 has 39 digits.
(define-constant std-decimal-iterations
  (list true true true true true true true true true true true true true
        true true true true true true true true true true true true true
        true true true true true true true true true true true true true))

;; Emits one digit per step until the rest is zero; the first step always
;; emits, so zero renders as "0".
(define-private (std-decimal-step (acc { rest: uint, text: X }) (ignored bool))
  (if (and (is-eq (get rest acc) u0) (> (len (get text acc)) u0))
    acc
    { rest: (/ (get rest acc) u10),
      text: (std-prepend-digit (mod (get rest acc) u10) (get text acc)) }))

;; `X` is instantiated at the type of the empty string of the result kind,
;; `(string-ascii 0)` or `(string-utf8 0)`, and the fold widens it to 40.
(define-private (std-render-decimal (value uint) (empty X))
  (get text (fold-left std-decimal-step { rest: value, text: empty }
              std-decimal-iterations)))

(define-private (std-render-signed (value int) (empty X) (minus Y))
  (if (< value 0)
    (unwrap-panic (as-max-len? (concat minus (std-render-decimal (std-magnitude value) empty)) u40))
    (std-render-decimal (to-uint value) empty)))

(define-private (int-to-ascii (value uint))
  (std-render-decimal value ""))

(define-private (int-to-ascii (value int))
  (std-render-signed value "" "-"))

(define-private (int-to-utf8 (value uint))
  (std-render-decimal value u""))

(define-private (int-to-utf8 (value int))
  (std-render-signed value u"" u"-"))

(define-private (std-digit-value (char (string-ascii 1)))
  (index-of? "0123456789" char))

(define-private (std-digit-value (char (string-utf8 1)))
  (index-of? u"0123456789" char))

(define-private (std-is-minus (char (string-ascii 1)))
  (is-eq char "-"))

(define-private (std-is-minus (char (string-utf8 1)))
  (is-eq char u"-"))

;; total * 10 + digit, or none if that exceeds the largest uint.
(define-private (std-push-digit (total uint) (digit uint))
  (if (or (> total u34028236692093846346337460743176821145)
          (and (is-eq total u34028236692093846346337460743176821145) (> digit u5)))
    none
    (some (+ (* total u10) digit))))

(define-private (std-parse-digit (acc (optional uint)) (char C))
  (match acc
    ((some total)
      (match (std-digit-value char)
        ((some digit) (std-push-digit total digit))
        (none none)))
    (none none)))

;; `S` is instantiated at string-ascii or string-utf8.
(define-private (string-to-uint? (text S))
  (if (is-eq (len text) u0)
    none
    (fold-left std-parse-digit (some u0) text)))

;; -magnitude, or none below the most negative int.
(define-private (std-negate-magnitude (magnitude uint))
  (if (is-eq magnitude u0)
    (some 0)
    (if (> magnitude u170141183460469231731687303715884105728)
      none
      (some (- (- 0 (to-int (- magnitude u1))) 1)))))

;; `S` is instantiated at string-ascii or string-utf8.
(define-private (string-to-int? (text S))
  (match (element-at? text u0)
    ((some first)
      (if (std-is-minus first)
        (match (string-to-uint? (unwrap-panic (slice? text u1 (len text))))
          ((some magnitude) (std-negate-magnitude magnitude))
          (none none))
        (match (string-to-uint? text)
          ((some magnitude)
            (if (> magnitude u170141183460469231731687303715884105727)
              none
              (some (to-int magnitude))))
          (none none))))
    (none none)))

;; `to-ascii?` renders the six kinds legacy accepts, with legacy's text and
;; result bounds, except that a principal's bound is 82, not 170, because
;; contract names are at most 40 characters. Only the string-utf8 overload
;; can fail. Principals go through the `principal-to-ascii` primitive,
;; because c32check is a chain encoding (chapter 3.5).

(define-private (to-ascii? (value int))
  (ok (int-to-ascii value)))

;; "u" and at most 39 digits.
(define-private (to-ascii? (value uint))
  (ok (unwrap-panic (as-max-len? (concat "u" (int-to-ascii value)) u40))))

(define-private (to-ascii? (value bool))
  (ok (if value "true" "false")))

(define-private (to-ascii? (value principal))
  (ok (principal-to-ascii value)))

;; Two lowercase hex digits.
(define-private (std-hex-byte (byte (buff 1)))
  (let ((number (buff-to-uint-be byte)))
    (concat (unwrap-panic (element-at? "0123456789abcdef" (/ number u16)))
            (unwrap-panic (element-at? "0123456789abcdef" (mod number u16))))))

;; "0x" and two digits per byte: the spread gives the bound 2 + N * 2.
(define-private (to-ascii? (value (buff N)))
  (ok (concat "0x" (map std-hex-byte value)...)))

;; The string-ascii character set (chapter 2.2), in the same order in both
;; kinds: 0x20 through 0x7E, then tab, line feed, carriage return.
(define-constant std-ascii-chars
  " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~\t\n\r")
(define-constant std-ascii-chars-utf8
  u" !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~\t\n\r")

(define-private (std-char-to-ascii (char (string-utf8 1)))
  (match (index-of? std-ascii-chars-utf8 char)
    ((some index) (element-at? std-ascii-chars index))
    (none none)))

(define-private (std-char-or-empty (char (optional (string-ascii 1))))
  (default-to "" char))

;; (err u1) if any character has no string-ascii form. The spread gives the
;; bound N * 1.
(define-private (to-ascii? (value (string-utf8 N)))
  (let ((chars (map std-char-to-ascii value)))
    (if (is-eq (len (filter is-some chars)) (len chars))
      (ok (concat "" (map std-char-or-empty chars)...))
      (err u1))))

;; ---------------------------------------------------------------------------
;; Principals
;; ---------------------------------------------------------------------------

;; True if the principal's version byte is for the current network, whether it
;; is a standard or a contract principal. This is what legacy `is-standard`
;; tested, under a name that said otherwise.
(define-private (is-current-network (who principal))
  (is-ok (principal-destruct? who)))

;; True if the principal is a standard principal, not a contract principal,
;; on any network.
(define-private (is-standard (who principal))
  (match (principal-destruct? who)
    ((ok parts) (is-none (get name parts)))
    ((err parts) (is-none (get name parts)))))

;; Version bytes for single-signature standard principals.
(define-constant std-mainnet-p2pkh-version 0x16)
(define-constant std-testnet-p2pkh-version 0x1a)

;; Derive the standard principal for a compressed public key on the current
;; network. Returns (err u1) if the key is not 33 bytes.
(define-private (principal-of? (public-key (buff 33)))
  (if (not (is-eq (len public-key) u33))
    (err u1)
    (match (principal-construct?
             (if (get is-mainnet (get-current-context))
               std-mainnet-p2pkh-version
               std-testnet-p2pkh-version)
             (hash160 public-key)
             none)
      ((ok who) (ok who))
      ((err ignored) (err u1)))))

;; ---------------------------------------------------------------------------
;; Cryptography
;; ---------------------------------------------------------------------------

(define-private (std-double-sha256 (bytes (buff 64)))
  (sha256 (sha256 bytes)))

;; Depth of a Bitcoin Merkle tree over `count` leaves (count >= 1).
(define-private (std-merkle-depth (count uint))
  (if (<= count u1)
    u0
    (+ (log2 (- count u1)) u1)))

;; One level up the tree. `width` is the number of nodes in the current row.
;; A left node that is last in its row is paired with itself, so its sibling
;; must equal it.
(define-private (std-merkle-step (acc { hash: (buff 32), index: uint, valid: bool, width: uint })
                                 (sibling (buff 32)))
  (let ((current (get hash acc))
        (position (get index acc))
        (right-child (is-eq (mod position u2) u1)))
    { hash: (if right-child
              (std-double-sha256 (concat sibling current))
              (std-double-sha256 (concat current sibling))),
      index: (/ position u2),
      valid: (and (get valid acc)
                  (or right-child
                      (not (is-eq (+ position u1) (get width acc)))
                      (is-eq sibling current))),
      width: (+ (/ (get width acc) u2) (mod (get width acc) u2)) }))

;; Bitcoin-style inclusion proof; see chapter 4.2 for the full contract. `false` for
;; an index not below the count, a path length other than the tree depth, a
;; failed duplication check, or a root mismatch.
(define-private (verify-merkle-proof (leaf (buff 32)) (root (buff 32))
                                     (index uint) (count uint)
                                     (proof (list 24 (buff 32))))
  (if (or (>= index count) (not (is-eq (len proof) (std-merkle-depth count))))
    false
    (let ((final (fold-left std-merkle-step
                   { hash: leaf, index: index, valid: true, width: count }
                   proof)))
      (and (get valid final) (is-eq (get hash final) root)))))

;; ---------------------------------------------------------------------------
;; Storage
;; ---------------------------------------------------------------------------

;; Insert only if absent. Returns the existing value, and writes nothing, if
;; the key already has one; `none` if the value was inserted. Private, so
;; `key` and `value` are both evaluated before the call.
(define-private (map-insert? (target (map K V)) (key K) (value V))
  (match (map-get? target key)
    ((some existing) (some existing))
    (none (begin (map-set target key value) none))))
