;; verify-scheme.ss
;;
;; part of p423-sp12/srwaggon-p423 assign3
;; http://github.iu.edu/p423-sp12/srwaggon-p423
;;
;; Samuel Waggoner
;; srwaggon@indiana.edu
;; 2012/2/11

#!chezscheme
(library (compiler verify-scheme)
  (export verify-scheme)
  (import
   ;; Load Chez Scheme primitives:
   (chezscheme)
   ;; Load compiler framework:
   (framework match)
   (framework helpers)
   (compiler helpers)
   )

 #| verify-scheme : program --> program
  | verify-scheme takes an expression representing a program and verifies
  | that it is an expression consiting solely of the provided language.
  | A descrition of the language is as follows.

  | Defiant to scheme unquote syntax (or whatever it's called),
  | unquotes here signify a member also found within the language.
  | Consecutive unquoted members are not necessarily the same member,
  | so much as the same part of the grammar.

  Program   -->  (letrec ([<label> (lambda () ,Body)]*) ,Body)

  Body      -->  (locate ([<uvar> ,Loc]*) ,Tail)

  Tail      -->  (,Triv)
  |   (if ,Pred ,Tail ,Tail)
  |   (begin ,Effect* ,Tail)

  Pred      -->  (true)
  |   (false)
  |   (,Relop ,Triv ,Triv)
  |   (if ,Pred ,Pred ,Pred)
  |   (begin ,Effect* ,Pred)

  Effect    -->  (nop)
  |   (set! ,Var ,Triv)
  |   (set! ,Var (,Binop ,Triv ,Triv))
  |   (if ,Pred ,Effect ,Effect)
  |   (begin ,Effect* ,Effect)

  Triv      -->  ,Var | <integer> | <label>

  Var       -->  ,<uvar> | ,Loc

  Loc       -->  ,Register | <frame variable>

  Register  -->  rax | rcx | rdx | rbx | rbp | rsi | rdi
  |   r8 | r9 | r10 | r11 | r12 | r13 | r14 | r15

  Binop     -->  + | - | * | logand | logor | sra

  Relop     -->  < | <= | = | >= | >

  | If the program matches the language, the expression is returned.
  |#
  (define-who (verify-scheme program)

   ;; idea stolen from a3 solution and by the transitive property, Kent.
   #| verify-x-list : x* x? what --> void
    | verify-x-list takes a list of symbols, a predicate which truly
    | identifies the symbols' type, and a symbol representing what
    | that type is and throws an error if any of the symbols are
    | invalid or non-unique.
    |#
    (define (verify-x-list x* x? what)
      (let loop ([x* x*] [id* '()])
        (unless (null? x*)
          (let ([x (car x*)])
            (unless (x? x)
              (errorf who "invalid ~s ~s" what x))
            (let ([id (extract-suffix x)])
              (when (member id id*)
                (errorf who "non-unique ~s suffix ~s" what id))
              (loop (cdr x*) (cons id id*)))))))

   #| Var->Loc : Var uvarEnv --> Loc
    | Var->Loc was written by R. Kent Dybvig and/or Andy Keep.
    | Var->Loc takes a Var and a uvar environment and,
    | if the Var occurs within the uvar environment, its
    | associated Loc is returned.
    |#
    (define (Var->Loc v env)
      (if (uvar? v) (cdr (assq v env)) v)
    )

   #| Effect : exp --> void
    | Effect takes an expression and throws an error
    | unless the expression qualifies as an effect.
    |
    | Effect --> (nop)
    |   (set! ,Var ,Triv)
    |   (set! ,Var (,Binop ,Triv ,Triv))
    |   (if ,Pred ,Effect ,Effect)
    |   (begin ,Effect* ,Effect)
    |#
    (define (Effect uvarEnv)
      (lambda (exp)
        (match exp
          [(nop) exp]
          [(set! ,v ,t)
           (guard
            (var? v)
            (triv? t)
            (let ([v (Var->Loc v uvarEnv)][t (Var->Loc t uvarEnv)])
              #| ARCHITECTURE SPECIFIC CONSTRAINTS |#
              ;; v & t cannot both be frame-vars
              (not (and (frame-var? v) (frame-var? t)))
              ;; labels only fit in registers
              (if (label? t) (register? v))
              (if (integer? t)
                  ;; ints must be 32bit or
                  (or (int32? t)
                      ;; int64's only fit into registers
                      (and (register? v) (int64? t))))
              )
            )
           exp]
          [(set! ,v (,b ,t1 ,t2))
           (guard
            (var? v)
            (or (binop? b) (relop? b))
            (triv? t2)
           #| ARCHITECTURE SPECIFIC CONSTRAINTS |#
            ;; (set! v (b t t0)) :: valid iff v equals t
            (eq? v t1)
            ;; t & t0 cannot both be frame-vars
            (not (and (frame-var? t1) (frame-var? t2)))
            ;; no labels as operands to binops
            (not (or (label? t1) (label? t1)))
            ;; Integer operands of binary operations must be
            ;; an exact integer -2^31 ≤ n ≤ 2^31 - 1
            (if (number? t1) (and (int32? t1) (exact? t1)))
            (if (number? t2) (and (int32? t2) (exact? t2)))
            ;; result from * operator must go into a register
            (if (eq? b '*) (or (register? v) (uvar? v)))
            ;; whatever.
            (if (eq? b 'sra) (and (<= 0 t2) (>= 63 t2)))
            )
           exp]
          [(if ,[(Pred uvarEnv) -> p] ,[(Effect uvarEnv) -> e0] ,[(Effect uvarEnv) -> e1]) exp]
          [(begin ,[(Effect uvarEnv) -> e*] ... ,[(Effect uvarEnv) -> e]) exp]
          [,x (errorf who "invalid effect: ~s" x) x]
          )
        )
      )

   #| Pred : exp --> void
    | Pred takes an expression and throws an error
    | unless the expression qualifies as a predicate.
    |
    | Pred --> (true)
    |   (false)
    |   (,Relop ,Triv ,Triv)
    |   (if ,Pred ,Pred ,Pred)
    |   (begin ,Effect* ,Pred)
    |#
    (define (Pred uvarEnv)
      (lambda (exp)
        (match exp
          [(true) (values)]
          [(false) (values)]
          [(,r ,t0 ,t1) (guard (relop? r)
                               (triv? t0)
                               (triv? t1)
                               )
           (values)]
          [(if ,[p0] ,[p1] ,[p2]) (values)]
          [(begin ,[(Effect uvarEnv) -> e*] ... ,[p]) exp]
          [,x (errorf who "invalid pred: ~s" x)]
          )
        )
      )

   #| Tail : env --> procedure : exp --> void
    | Tail is a curried procedure which takes an
    | environment (list of existing labels) and
    | returns a procedure which
    | takes an expression and throws an error
    | unless the expression qualifies as a tail.
    |
    | Tail --> (,Triv)
    |       |  (if ,Pred ,Tail ,Tail)
    |       |  (begin ,Effect* ,Tail)
    |#
    (define (Tail lblEnv uvarEnv)
      (lambda (exp)
        (match exp
          [(,t)
           (guard (triv? t)
                  ;; Labels must be bound
                  (if (label? t) (and (member t lblEnv) #t))
                  ;; architectural nuance.  Jump must be to label, not address.
                  (not (integer? t))
                  )
           (values)]
          [(if ,[(Pred uvarEnv) -> p] ,[(Tail lblEnv uvarEnv) -> t0] ,[(Tail lblEnv uvarEnv) -> t1]) exp]
          [(begin ,[(Effect uvarEnv) -> e*] ... ,[(Tail lblEnv uvarEnv) -> t]) exp]
          [,x (errorf who "invalid tail: ~s" x) x]
          )
        )
      )

    #| Body : exv --> procedure : exp --> void
    | Body is a curried procedure which takes a
    | label environment and returns a procedure
    | which takes an expression and throws an
    | error unless the expression qualifies as
    | a valid body.
    |
    | Body --> (locate ([<uvar> ,Loc]*) ,Tail)
    |#
    (define (Body label*)
      (lambda (exp)
        (match exp
          [(locate ([,uvar* ,loc*]...) ,tail)
           (verify-x-list uvar* uvar? 'uvar)
           ((Tail label* (map cons uvar* loc*)) tail)
           ]
          [,x (errorf who "invalid body: ~s" x)]
          )
        )
      )

    #| Program : exp --> void
    | Program takes an expression and throws
    | an error unless the expression is a
    | valid fully-formed program according to
    | the grammar.
    |
    | Program --> (letrec ([<label> (lambda () ,Body)]*) ,Body)
    |#
    (define (Program exp)
      (match exp
        [(letrec ([,label* (lambda () ,bn)] ...) ,b0)
         (verify-x-list label* label? 'label)
         ((Body label*) b0)
         (for-each (Body label*) bn)
         ]
        [,x (errorf who "invalid syntax for Program: expected (letrec ([<label> (lambda () ,Body)]*) ,Body) but received ~s" x) x]
        )
      exp
      )
    (Program program)
    )

  ) ;; End Library.