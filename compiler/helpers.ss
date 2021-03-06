;; helpers.ss
;;
;; part of p423-sp12/srwaggon-p423 assign3
;; http://github.iu.edu/p423-sp12/srwaggon-p423
;; introduced in a4
;;
;; Samuel Waggoner
;; srwaggon@indiana.edu
;; 2012/2/11

#!chezscheme
(library (compiler helpers)
  (export
   prim?
   effect-prims
   effect-prim?
   pred-prims
   pred-prim?
   value-prims
   value-prim?
   simple?
   immediate?
   binop?
   loc?
   relop?
   triv?
   var?
   error-unless
   error-when
   invalid
   int64!32?
   uncover-conflicts
  )
  (import
    ;; Load Chez Scheme primitives:
    (chezscheme)
    ;; Load compiler framework:
    (framework match)
    (framework helpers)
  )


#| The list of Value primitives.
|#
(define value-prims
  '(+ - * car cdr cons make-vector vector-length vector-ref void procedure-ref procedure-code make-procedure))

#| value-prim? : expression --> boolean
|| Determines if the given expression is an Value primitive.
|#
(define (value-prim? expr)
  (and #t (memq expr value-prims)))

#| The list of predicate primitives.
|#
(define pred-prims
  '(< <= = >= > boolean? eq? fixnum? null? pair? vector? procedure?))

#| pred-prim? : expression --> boolean
|| Determines if the given expression is a Predicate primitive.
|#
(define (pred-prim? expr)
  (and #t (memq expr pred-prims)))

#| The list of Effect primitives.
|#
(define effect-prims
  '(set-car! set-cdr! vector-set! procedure-set!))

#| effect-prim? : expr --> boolean
|| Determines if the given expression is an Effect primitive.
|#
(define (effect-prim? expr)
  (and #t (memq expr effect-prims)))

#| prim? : expr --> boolean
|| Determines if the given expression is a primitive.
|#
(define (prim? expr)
  (or (value-prim? expr) (effect-prim? expr) (pred-prim? expr)))


(define (immediate? im)
  (or (fixnum? im) (eq? im '()) (eq? im '#f) (eq? im '#t)))


;; simple?
(define (simple? context lhs*)
  (lambda (program)
    (match program
      [(letrec ((,uvar* ,expr*) ...) ,[body])
       (let ([e* (map (simple? context (union lhs* uvar*)) expr*)])
         (and (not (memq #f e*)) body #t))]
      [(if ,[test] ,[conseq] ,[altern])
       (and test conseq altern #t)]
      [(begin ,[expr*] ... ,[expr])
       (and (not (memq #f expr*)) expr #t)]
      [(let ((,uvar* ,[expr*]) ...) (assigned ,assign* ,[body]))
       (and (not (memq #f expr*)) body #t)]
      [(,prim ,[expr*] ...) (guard (prim? prim))
       (and (not (memq #f expr*)) #t)]
      [(lambda ,uvar* (assigned ,assign* ,[(simple? #t lhs*) -> body]))
       (and body #t)]
      [(set! ,uvar ,[expr])
       (and expr #t)]
      [(quote ,immediate) #t]
      [(,[rator] ,[rand*] ...)
       (if context #f #t)]
      [,uvar (guard (uvar? uvar))
       (and (not (memq uvar lhs*)) #t)]
      [,else (errorf 'simple? "Invalid expression: ~s" else)]
      )))

#| uncover-conflicts : tail uvar* who qualifier --> conflict-graph call-live-set
||
|# 
(define (uncover-conflicts tail uvar* who qual)
  
  (define call-live '())

  ;; graph-add! : symbol symbol conflict-graph --> conflict-graph
  ;; graph-add! side-effects the given conflict-graph by set-cdr!'ing
  ;; the given symbol's association's cdr as the set-cons of its current
  ;; cdr and the given conflicting (second) symbol.
  (define (graph-add! s conflict graph)
    (when (uvar? s)
      (let ([assoc (assq s graph)])
        (if assoc
            (set-cdr! assoc (set-cons conflict (cdr assoc)))
            (cons (list s conflict) graph)
            )))
    graph)

  ;; update-graph : symbol live-set conflict-graph --> conflict-graph
  ;; update-graph takes a symbol, a live set, and a conflict graph
  ;; and adds the live-set as a conflict of the symbol in the graph.
  (define (update-graph s conflicts graph)
    (if (or (qual s) (uvar? s))
        (let loop ([conflicts conflicts]
                   [graph graph])
          (cond 
            [(null? conflicts) graph]
            [else
             (loop (cdr conflicts)
                   (graph-add! (car conflicts) s
                               (graph-add! s (car conflicts) graph)))]
            ))
        graph))
  
  ;; handle : symbol pred live-set --> live-set
  ;; iff the var qualifies by the pred or is a register it is added
  ;; to the live-set before the live-set is returned.
  (define (handle var ls)
    (if (or (uvar? var) (qual var)) (set-cons var ls) ls))

  ;; graph-union! : conflict-graph conflict-graph --> conflict-graph
  ;; graph-union! takes two conflict  graphs and combines their entries
  ;; (key-value pairs where the value is a list of conflicts)
  ;; into a single conflict-graph (through side-effecting the secondly
  ;; provided conflict graph
  (define (graph-union! g0 g1)
    (for-each (lambda (assoc)
           (let ([s (car assoc)]
                 [flicts (cdr assoc)])
             (update-graph s flicts g1))) g0)
    g1 #|Pacman blocker|# 
  )
  
  ;; Effect : Effect* Effect conflict-graph live-set --> conflict-graph live-set
  (define (Effect effect* effect graph live)
    (match effect
      [(begin ,e* ...) (Effect* (append effect* e*) graph live)]
      [(if ,pred ,conseq ,altern)
       (let*-values ([(ga lsa) (Effect '() altern graph live)]
                     [(gc lsc) (Effect '() conseq graph live)]
                     [(gp lsp) (Pred pred gc ga lsc lsa)])
         (Effect* effect* gp lsp))]
      [(mset! ,base ,offset ,val)
         (Effect* effect* graph (handle base (handle offset (handle val live))))]
      [(nop) (Effect* effect* graph live)]
      [(return-point ,label ,tail)
       (let-values ([(gt lst) (Tail tail graph '())])
           (set! call-live (union call-live live))
           (Effect* effect* gt (union lst (filter (lambda (x) (or (uvar? x) (frame-var? x))) live))))]
      [(set! ,lhs (mref ,base ,offset))
       (let ([ls (remove lhs live)])
         (Effect* effect* (update-graph lhs ls graph) (handle base (handle offset ls))))]
      [(set! ,lhs (,binop ,rhs0 ,rhs1)) (guard (binop? binop))
       (let ([ls (remove lhs live)])
         (Effect* effect* (update-graph lhs ls graph) (handle rhs0 (handle rhs1 ls))))]
      [(set! ,lhs ,rhs)
       (let ([ls (remove lhs live)])
         (Effect* effect* (update-graph lhs ls graph) (handle rhs ls)))]
      [,else (invalid who 'Effect else)]))

  ;; Effect* : Effect* conflict-graph live-set --> conflict-graph live-set
  (define (Effect* effect* graph live)
    (match effect*
      [() (values graph live)]
      [(,effect* ... ,effect) (Effect effect* effect graph live)]
      [,else (invalid who 'Effect* else)]))

  ;; Pred : Pred conflict-graph live-set --> conflict-graph live-set
  (define (Pred pred Cgraph Agraph Clive Alive)
    (match pred
      [(true) (values Cgraph Clive)]
      [(false) (values Agraph Alive)]
      [(begin ,effect* ... ,pred)
       (let*-values ([(gp lsp) (Pred pred Cgraph Agraph Clive Alive)]
                     [(ge* lse*) (Effect* effect* gp lsp)])
         (values ge* lse*))]
      [(if ,pred ,conseq ,altern)
       (let*-values ([(ga lsa) (Pred altern Cgraph Agraph Clive Alive)]
                     [(gc lsc) (Pred conseq Cgraph Agraph Clive Alive)]
                     [(gp lsp) (Pred pred gc ga lsc lsa)])
         ;;(values (graph-union! Cgraph Agraph) (union lsp lsc lsa))
         (values gp lsp)
         )]
      [(,relop ,triv0 ,triv1)
       (values (graph-union! Cgraph Agraph) (handle triv0 (handle triv1 (union Clive Alive))))]
      [,else (invalid who 'Pred else)]))

  ;; Tail : Tail conflict-graph live-set --> conflict-graph live-set
  (define (Tail tail graph live)
    (match tail
      [(begin ,effect* ... ,tail)
       (let*-values ([(gt lst) (Tail tail graph live)]
                     [(ge* lse*) (Effect* effect* gt lst)])
         (values graph lse*))]
      [(if ,pred ,conseq ,altern)
       (let*-values ([(ga lsa) (Tail altern graph live)]
                     [(gc lsc) (Tail conseq graph live)]
                     [(gp lsp) (Pred pred gc ga lsc lsa)])
         ;;(values graph (union lsp lsc lsa)))
         (values graph lsp))
       ]
      [(,triv ,loc* ...)
       (values graph (handle triv
                             (union (filter (lambda (x) (or (uvar? x) (qual x))) loc*) live)))]
      [,else (invalid who 'Tail else)]))

  (let*-values ([(empty-graph) (map (lambda (s) (cons s '())) uvar*)]
                [(live-set) '()]
                [(graph lives) (Tail tail empty-graph live-set)])   
    (values graph call-live))
)

#|
|| int64!32? : sym
|| returns #t if the given symbol is strictly an 64-bit integer
|| and not a 32-bit integer.
|#
(define (int64!32? x)
  (and (not (int32? x)) (int64? x)))

#| relop? : sym --> boolean
 | relop? takes a symbol and returns #t
 | iff the symbol is a relational operator
 |
 | Relop --> < | <= | = | >= | >
 |#
(define (relop? exp)
  (define relops '(< <= = >= >))
  (and (memq exp relops) #t)
)

#| binop? : sym --> boolean
 | binop? takes a symbol and returns #t 
 | iff the symbol is a binary operator.
 | 
 | Binop --> + | - | * | logand | logor | sra
 |#
(define (binop? exp)
  (define binops '(+ - * logand logor sra))
  (and (memq exp binops) #t)
)

(define-syntax error-unless
  (syntax-rules ()
    [(_ bool who string exp ...)
     (unless bool
       (errorf who string exp ...))]
    [(_ bool string exp ...)
     (unless bool
       (errorf string exp ...))]
  )
)
(define-syntax error-when
  (syntax-rules ()
    [(_ bool who string exp ...)
     (when bool
       (errorf who string exp ...))]
    [(_ bool string exp ...)
     (when bool
       (errorf string exp ...))]
  )
)


#;(define-syntax invalid
  (syntax-rules ()
    [(_ what exp)
     (errorf "invalid ~s ~s" what exp)
    ]
  ))

(define (invalid who what exp)
  (errorf who "invalid ~s: ~s" what exp))

#| loc? : exp --> boolean
 | loc? takes an expression and returns #t
 | iff the expression is a location.
 |
 | Loc --> ,Register | <frame variable>
 |#
(define (loc? exp)
  (or (register? exp) (frame-var? exp))
)

#| var? : exp --> boolean
 | var? takes an expression and returns #t
 | iff the expression is a variable.
 |
 | Var --> ,<uvar> | ,Loc
 |#
(define (var? exp)
  (or
    (uvar? exp)
    (loc? exp)
  )
)

#| triv? : exp --> boolean
 | triv? takes an expression and returns #t
 | iff the expression is trivial.
 |
 | Triv --> ,Var | <integer> | <label>
 |#
(define (triv? exp)
  (or
    (var? exp)
    (int64? exp)
    (label? exp)
  )
)


) ;; End Library