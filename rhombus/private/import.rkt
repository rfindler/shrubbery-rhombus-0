#lang racket/base
(require (for-syntax racket/base
                     syntax/parse
                     enforest
                     enforest/operator
                     enforest/transformer
                     enforest/property
                     enforest/syntax-local
                     enforest/ref-parse
                     enforest/proc-name
                     enforest/name-root
                     "srcloc.rkt"
                     "name-path-op.rkt")
         (submod "module-path.rkt" for-import-export)
         "declaration.rkt"
         "dot.rkt"
         (submod "dot.rkt" for-dot-provider)
         (only-in "assign.rkt"
                  [= rhombus=])
         (only-in "implicit.rkt"
                  #%literal)
         (only-in "arithmetic.rkt"
                  [/ rhombus/]))

(provide import

         (for-space rhombus/import
                    #%juxtapose
                    #%literal
                    (rename-out [rhombus/ /]
                                [rhombus-file file]
                                [rhombus-lib lib])
                    rename
                    only
                    except
                    expose))

(module+ for-export
  (provide (for-syntax import-name-root-ref
                       import-name-root-module-path)))

(begin-for-syntax
  (property import-prefix-operator prefix-operator)
  (property import-infix-operator infix-operator)

  (property import-modifier transformer)

  (property import-name-root name-root (module-path))

  (define in-import-space (make-interned-syntax-introducer 'rhombus/import))

  (define (check-import-result form proc)
    (unless (syntax? form) (raise-result-error (proc-name proc) "syntax?" form))
    form)

  (define (make-identifier-import id)
    (unless (module-path? (syntax-e id))
      (raise-syntax-error 'import
                          "not a valid module path element"
                          id))
    id)

  (define-enforest
    #:syntax-class :import
    #:desc "import"
    #:operator-desc "import operator"
    #:in-space in-import-space
    #:name-path-op name-path-op
    #:prefix-operator-ref import-prefix-operator-ref
    #:infix-operator-ref import-infix-operator-ref
    #:check-result check-import-result
    #:make-identifier-form make-identifier-import)

  (define (make-import-modifier-ref transform-in req)
    ;; "accessor" closes over `req`:
    (lambda (v)
      (define mod (import-modifier-ref v))
      (and mod
           (transformer (lambda (stx)
                          ((transformer-proc mod) (transform-in req) stx))))))

  (define-transform
    #:syntax-class (:import-modifier req)
    #:desc "import modifier"
    #:in-space in-import-space
    #:name-path-op name-path-op
    #:transformer-ref (make-import-modifier-ref transform-in req))

  (define (extract-module-path r)
    (syntax-parse r
      [_:string r]
      [_:identifier r]
      [((~literal file) _) r]
      [((~literal lib) _) r]
      [((~literal rename-in) mp . _) (extract-module-path #'mp)]
      [((~literal only-in) mp . _) (extract-module-path #'mp)]
      [((~literal except-in) mp . _) (extract-module-path #'mp)]
      [((~literal expose-in) mp . _) (extract-module-path #'mp)]
      [((~literal module-path-in) _ mp) (extract-module-path #'mp)]
      [_ (raise-syntax-error 'import
                             "don't know how to extract module path"
                             r)]))

  (define (introduce-but-skip-exposed intro r)
    (syntax-parse r
      [_:string (intro r)]
      [_:identifier (intro r)]
      [((~literal file) _) (intro r)]
      [((~literal lib) _) (intro r)]
      [((~literal expose-in) mp name ...)
       #`(rename-in #,(introduce-but-skip-exposed intro #'mp)
                    #,@(for/list ([name (in-list (syntax->list #'(name ...)))])
                         #`[#,(intro name) #,name]))]
      [(form-id mp . more)
       (quasisyntax/loc r (form-id #,(introduce-but-skip-exposed intro #'mp)
                                   . #,(intro #'more)))]
      [_ (raise-syntax-error 'import
                             "don't know how to expose"
                             r)]))

  (define (extract-prefix r)
    (define mp (extract-module-path r))
    (syntax-parse mp
      [_:string (datum->syntax
                 mp
                 (string->symbol
                  (regexp-replace #rx"[.].*$"
                                  (regexp-replace #rx"^.*/" (syntax-e mp) "")
                                  ""))
                 mp)]
      [_:identifier (datum->syntax
                     mp
                     (string->symbol (regexp-replace #rx"^.*/"
                                                     (symbol->string (syntax-e mp))
                                                     ""))
                     mp)]
      [((~literal lib) str) (extract-prefix #'str)]
      [((~literal file) str) (let-values ([(base name dir?) (split-path (syntax-e #'str))])
                               (datum->syntax
                                mp
                                (string->symbol (path-replace-suffix name #""))))]
      [_ (raise-syntax-error 'import
                             "don't know how to extract default prefix"
                             mp)]))
  
  (define-syntax-class :import-block
    #:datum-literals (block group op)
    #:literals (rhombus=)
    (pattern (group (~optional prefix:identifier
                               #:defaults ([prefix #'#f]))
                    (op rhombus=)
                    req ...)
             #:with r::import #'(group req ...)
             #:attr parsed #'r.parsed)
    (pattern (group req ...)
             #:with r::import #'(group req ...)
             #:attr parsed #'r.parsed
             #:attr prefix (extract-prefix #'r.parsed)))

  (define (apply-modifiers mods r-parsed)
    (cond
      [(null? mods) r-parsed]
      [else
       (syntax-parse (car mods)
         #:datum-literals (group)
         [(~var im (:import-modifier r-parsed))
          (apply-modifiers (cdr mods) #'im.parsed)]
         [(group form . _)
          (raise-syntax-error #f
                              "not an import modifier"
                              #'form)])])))

(define-syntax import
  (declaration-transformer
   (lambda (stx)
     (syntax-parse stx
       [(_ (block r ...))
        #'((rhombus-import r ...))]))))

(define-syntax (rhombus-import stx)
  ;; handle one `import-block` at a time, so it can import
  ;; transformers that are used for later imports
  (syntax-parse stx
    [(_) #'(begin)]
    [(_ r::import-block . more)
     (define prefix #'r.prefix)
     (define intro (if (syntax-e prefix)
                       (make-syntax-introducer)
                       values))
     (define r-parsed (introduce-but-skip-exposed intro #'r.parsed))
     #`(begin
         (require #,r-parsed)
         #,(if (syntax-e prefix)
               #`(define-syntax #,prefix
                   (import-name-root (lambda (tail)
                                       (parse-import-dot
                                        (quote-syntax #,(datum->syntax (intro #'r.parsed) 'ctx))
                                        tail))
                                     (quote-syntax #,(extract-module-path r-parsed))))
               #'(begin))
         (rhombus-import . more))]))

(define-for-syntax (parse-import-dot ctx stxes)
  (define (get what name)
    (define id (datum->syntax ctx
                              (syntax-e name)
                              name
                              name))
    (unless (identifier-binding id)
      (raise-syntax-error #f
                          (format "no such imported ~a" what)
                          name))
    id)
  (syntax-parse stxes
    #:datum-literals (op parens)
    #:literals (|.|)
    [(_ (op |.|) field:identifier . tail)
     (values (relocate #'field (get "identifier" #'field)) #'tail)]
    [(_ (op |.|) (parens (group (~and target (op field))))  . tail)
     (values (relocate #'target #`(op #,(get "operator" #'field))) #'tail)]
    [(form-id (op (~and dot |.|)) . tail)
     (raise-syntax-error #f
                         "expected an identifier or parentheses after dot"
                         #'dot)]
    [(form-id . tail)
     (raise-syntax-error #f
                         "expected a dot after import name"
                         #'form-id)]))
  
(define-syntax (define-import-syntax stx)
  (syntax-parse stx
    [(_ name:id rhs)
     (quasisyntax/loc stx
       (define-syntax #,(in-import-space #'name) rhs))]))

(define-import-syntax #%juxtapose
  (import-infix-operator
   #'#%juxtapose
   '((default . weaker))
   'macro
   (lambda (form1 stx)
     (syntax-parse stx
       #:datum-literals (block group)
       [(_ (block mod ...))
        (values (apply-modifiers (syntax->list #'(mod ...))
                                 form1)
                #'())]
       [(_ form . _)
        (raise-syntax-error #f
                            "unexpected term after import"
                            #'form)]))
   'left))

(define-import-syntax #%literal
  (make-module-path-literal-operator import-prefix-operator))

(define-import-syntax rhombus/
  (make-module-path-/-operator import-infix-operator))

(define-import-syntax rhombus-file
  (make-module-path-file-operator import-prefix-operator))

(define-import-syntax rhombus-lib
  (make-module-path-lib-operator import-prefix-operator))

(define-import-syntax rename
  (import-modifier
   (lambda (req stx)
     (syntax-parse stx
       #:datum-literals (block)
       [(_ (block (group int::reference #:to ext::reference)
                  ...))
        (datum->syntax req
                       (list* #'rename-in req #'([int.name ext.name] ...))
                       req)]))))

(define-import-syntax only
  (import-modifier
   (lambda (req stx)
     (syntax-parse stx
       #:datum-literals (block group)
       [(_ (block (group ref::reference ...) ...))
        (datum->syntax req
                       (list* #'only-in req #'(ref.name ... ...))
                       req)]))))

(define-import-syntax except
  (import-modifier
   (lambda (req stx)
     (syntax-parse stx
       #:datum-literals (block group)
       [(_ (block (group ref::reference ...) ...))
        (datum->syntax req
                       (list* #'except-in req #'(ref.name ... ...))
                       req)]))))

(define-import-syntax expose
  (import-modifier
   (lambda (req stx)
     (syntax-parse stx
       #:datum-literals (block group)
       [(_ (block (group ref::reference ...) ...))
        (datum->syntax req
                       (list* #'expose-in req #'(ref.name ... ...))
                       req)]))))