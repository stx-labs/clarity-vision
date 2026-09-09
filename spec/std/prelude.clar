;; Clarity vNEXT standard library prelude (working draft)
;;
;; This file is ordinary vNEXT source. It uses only features available to
;; every contract: generics (implicit type variables), inline functions with
;; call-by-name parameters, overloading, static references, `match`,
;; `return`, and the primitives in ../03-primitives.md.
;;
;; Scope: control flow and convenience only. Every definition here expands to
;; roughly what a native implementation would cost. Pure computation with a
;; plain signature is a primitive, not a library function (layering rule,
;; fourth test).
;;
;; Conventions:
;;   define-inline  for anything needing laziness or early exit
;;   define-private for anything users pass to map / filter / fold
;;
;; Each value parameter of an inline function is referenced at most once in
;; its body; bodies that need a value twice bind it with `let` first.

;; ---------------------------------------------------------------------------
;; Branching
;; ---------------------------------------------------------------------------

;; `match` on bool is the only branching primitive; `if` is sugar over it.
(define-inline (if (condition bool) (then T) (else T))
  (match condition
    (true then)
    (false else)))

(define-inline (and (left bool) (right bool))
  (if left right false))

(define-inline (or (left bool) (right bool))
  (if left true right))

;; Private so it can be passed to `filter`.
(define-private (not (value bool))
  (if value false true))

;; ---------------------------------------------------------------------------
;; Early exit
;; ---------------------------------------------------------------------------

(define-inline (asserts! (condition bool) (thrown E))
  (if condition true (return thrown)))

(define-inline (unwrap! (value (optional T)) (thrown E))
  (match value
    ((some inner) inner)
    (none (return thrown))))

(define-inline (unwrap! (value (response T E)) (thrown F))
  (match value
    ((ok inner) inner)
    ((err ignored) (return thrown))))

(define-inline (unwrap-err! (value (response T E)) (thrown F))
  (match value
    ((ok ignored) (return thrown))
    ((err inner) inner)))

(define-inline (try! (value (optional T)))
  (match value
    ((some inner) inner)
    (none (return none))))

(define-inline (try! (value (response T E)))
  (match value
    ((ok inner) inner)
    ((err inner) (return (err inner)))))

(define-inline (unwrap-panic (value (optional T)))
  (match value
    ((some inner) inner)
    (none (panic))))

(define-inline (unwrap-panic (value (response T E)))
  (match value
    ((ok inner) inner)
    ((err ignored) (panic))))

(define-inline (unwrap-err-panic (value (response T E)))
  (match value
    ((ok ignored) (panic))
    ((err inner) inner)))

;; The default is evaluated only when needed (a change from legacy).
(define-inline (default-to (default T) (value (optional T)))
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

;; `T` is instantiated at int or uint; the comparison checks it at the call
;; site (template semantics, chapter 2 open question 5).
(define-private (max (left T) (right T))
  (if (> left right) left right))

(define-private (min (left T) (right T))
  (if (< left right) left right))

;; Aborts on the most negative int, as `(- 0 x)` overflows there.
(define-private (abs (value int))
  (if (< value 0) (- 0 value) value))

;; ---------------------------------------------------------------------------
;; Sequences
;; ---------------------------------------------------------------------------

;; (list N T) -> (list (+ N 1) T)
(define-inline (append (items (list N T)) (item T))
  (concat items (list item)))

;; ---------------------------------------------------------------------------
;; Principals
;; ---------------------------------------------------------------------------

(define-private (is-standard (who principal))
  (is-ok (principal-destruct? who)))

;; Version bytes for single-signature standard principals.
(define-constant mainnet-p2pkh-version 0x16)
(define-constant testnet-p2pkh-version 0x1a)

;; Derive the standard principal for a compressed public key on the current
;; network. Returns (err u1) if the key is not 33 bytes.
(define-private (principal-of? (public-key (buff 33)))
  (if (not (is-eq (len public-key) u33))
    (err u1)
    (match (principal-construct?
             (if is-in-mainnet mainnet-p2pkh-version testnet-p2pkh-version)
             (hash160 public-key)
             none)
      ((ok who) (ok who))
      ((err ignored) (err u1)))))

;; ---------------------------------------------------------------------------
;; Storage
;; ---------------------------------------------------------------------------

;; Insert only if absent. `key` is referenced twice, so it is bound first.
(define-inline (map-insert (target (map K V)) (key K) (value V))
  (let ((k key))
    (match (map-get? target k)
      ((some existing) false)
      (none (map-set target k value)))))

;; ---------------------------------------------------------------------------
;; Assets
;; ---------------------------------------------------------------------------

(define-private (stx-get-balance (owner principal))
  (get unlocked (stx-account owner)))
