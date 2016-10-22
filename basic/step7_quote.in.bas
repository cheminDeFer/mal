GOTO MAIN

REM $INCLUDE: 'readline.in.bas'
REM $INCLUDE: 'types.in.bas'
REM $INCLUDE: 'reader.in.bas'
REM $INCLUDE: 'printer.in.bas'
REM $INCLUDE: 'env.in.bas'
REM $INCLUDE: 'core.in.bas'

REM $INCLUDE: 'debug.in.bas'

REM READ(A$) -> R
MAL_READ:
  GOSUB READ_STR
  RETURN

REM PAIR_Q(B) -> R
PAIR_Q:
  R=0
  IF (Z%(B,0)AND31)<>6 AND (Z%(B,0)AND31)<>7 THEN RETURN
  IF (Z%(B,1)=0) THEN RETURN
  R=1
  RETURN

REM QUASIQUOTE(A) -> R
QUASIQUOTE:
  B=A:GOSUB PAIR_Q
  IF R=1 THEN GOTO QQ_UNQUOTE
    REM ['quote, ast]
    AS$="quote":T=5:GOSUB STRING
    B2=R:B1=A:GOSUB LIST2
    AY=B2:GOSUB RELEASE

    RETURN

  QQ_UNQUOTE:
    R=A+1:GOSUB DEREF_R
    IF (Z%(R,0)AND31)<>5 THEN GOTO QQ_SPLICE_UNQUOTE
    IF S$(Z%(R,1))<>"unquote" THEN GOTO QQ_SPLICE_UNQUOTE
      REM [ast[1]]
      R=Z%(A,1)+1:GOSUB DEREF_R
      Z%(R,0)=Z%(R,0)+32

      RETURN

  QQ_SPLICE_UNQUOTE:
    REM push A on the stack
    X=X+1:X%(X)=A
    REM rest of cases call quasiquote on ast[1..]
    A=Z%(A,1):GOSUB QUASIQUOTE:T6=R
    REM pop A off the stack
    A=X%(X):X=X-1

    REM set A to ast[0] for last two cases
    A=A+1:GOSUB DEREF_A

    B=A:GOSUB PAIR_Q
    IF R=0 THEN GOTO QQ_DEFAULT
    B=A+1:GOSUB DEREF_B
    IF (Z%(B,0)AND31)<>5 THEN GOTO QQ_DEFAULT
    IF S$(Z%(B,1))<>"splice-unquote" THEN QQ_DEFAULT
      REM ['concat, ast[0][1], quasiquote(ast[1..])]

      B=Z%(A,1)+1:GOSUB DEREF_B:B2=B
      AS$="concat":T=5:GOSUB STRING:B3=R
      B1=T6:GOSUB LIST3
      REM release inner quasiquoted since outer list takes ownership
      AY=B1:GOSUB RELEASE
      AY=B3:GOSUB RELEASE
      RETURN

  QQ_DEFAULT:
    REM ['cons, quasiquote(ast[0]), quasiquote(ast[1..])]

    REM push T6 on the stack
    X=X+1:X%(X)=T6
    REM A set above to ast[0]
    GOSUB QUASIQUOTE:B2=R
    REM pop T6 off the stack
    T6=X%(X):X=X-1

    AS$="cons":T=5:GOSUB STRING:B3=R
    B1=T6:GOSUB LIST3
    REM release inner quasiquoted since outer list takes ownership
    AY=B1:GOSUB RELEASE
    AY=B2:GOSUB RELEASE
    AY=B3:GOSUB RELEASE
    RETURN


REM EVAL_AST(A, E) -> R
REM called using GOTO to avoid basic return address stack usage
REM top of stack should have return label index
EVAL_AST:
  REM push A and E on the stack
  X=X+2:X%(X-1)=E:X%(X)=A

  IF ER<>-2 THEN GOTO EVAL_AST_RETURN

  GOSUB DEREF_A

  T=Z%(A,0)AND31
  IF T=5 THEN GOTO EVAL_AST_SYMBOL
  IF T>=6 AND T<=8 THEN GOTO EVAL_AST_SEQ

  REM scalar: deref to actual value and inc ref cnt
  R=A:GOSUB DEREF_R
  Z%(R,0)=Z%(R,0)+32
  GOTO EVAL_AST_RETURN

  EVAL_AST_SYMBOL:
    K=A:GOSUB ENV_GET
    GOTO EVAL_AST_RETURN

  EVAL_AST_SEQ:
    REM allocate the first entry (T already set above)
    L=0:N=0:GOSUB ALLOC

    REM make space on the stack
    X=X+4
    REM push type of sequence
    X%(X-3)=T
    REM push sequence index
    X%(X-2)=-1
    REM push future return value (new sequence)
    X%(X-1)=R
    REM push previous new sequence entry
    X%(X)=R

    EVAL_AST_SEQ_LOOP:
      REM update index
      X%(X-2)=X%(X-2)+1

      REM check if we are done evaluating the source sequence
      IF Z%(A,1)=0 THEN GOTO EVAL_AST_SEQ_LOOP_DONE

      REM if hashmap, skip eval of even entries (keys)
      IF (X%(X-3)=8) AND ((X%(X-2) AND 1)=0) THEN GOTO EVAL_AST_DO_REF
      GOTO EVAL_AST_DO_EVAL

      EVAL_AST_DO_REF:
        R=A+1:GOSUB DEREF_R: REM deref to target of referred entry
        Z%(R,0)=Z%(R,0)+32: REM inc ref cnt of referred value
        GOTO EVAL_AST_ADD_VALUE

      EVAL_AST_DO_EVAL:
        REM call EVAL for each entry
        A=A+1:GOSUB EVAL
        A=A-1
        GOSUB DEREF_R: REM deref to target of evaluated entry

      EVAL_AST_ADD_VALUE:

      REM update previous value pointer to evaluated entry
      Z%(X%(X)+1,1)=R

      IF ER<>-2 THEN GOTO EVAL_AST_SEQ_LOOP_DONE

      REM allocate the next entry
      REM same new sequence entry type
      T=X%(X-3):L=0:N=0:GOSUB ALLOC

      REM update previous sequence entry value to point to new entry
      Z%(X%(X),1)=R
      REM update previous ptr to current entry
      X%(X)=R

      REM process the next sequence entry from source list
      A=Z%(A,1)

      GOTO EVAL_AST_SEQ_LOOP
    EVAL_AST_SEQ_LOOP_DONE:
      REM if no error, get return value (new seq)
      IF ER=-2 THEN R=X%(X-1)
      REM otherwise, free the return value and return nil
      IF ER<>-2 THEN R=0:AY=X%(X-1):GOSUB RELEASE

      REM pop previous, return, index and type
      X=X-4
      GOTO EVAL_AST_RETURN

  EVAL_AST_RETURN:
    REM pop A and E off the stack
    E=X%(X-1):A=X%(X):X=X-2

    REM pop EVAL AST return label/address
    RN=X%(X):X=X-1
    ON RN GOTO EVAL_AST_RETURN_1,EVAL_AST_RETURN_2,EVAL_AST_RETURN_3
    RETURN

REM EVAL(A, E)) -> R
EVAL:
  LV=LV+1: REM track basic return stack level

  REM push A and E on the stack
  X=X+2:X%(X-1)=E:X%(X)=A

  EVAL_TCO_RECUR:

  REM AZ=A:PR=1:GOSUB PR_STR
  REM PRINT "EVAL: "+R$+" [A:"+STR$(A)+", LV:"+STR$(LV)+"]"

  GOSUB DEREF_A

  GOSUB LIST_Q
  IF R THEN GOTO APPLY_LIST
  REM ELSE
    REM push EVAL_AST return label/address
    X=X+1:X%(X)=1
    GOTO EVAL_AST
    EVAL_AST_RETURN_1:

    GOTO EVAL_RETURN

  APPLY_LIST:
    GOSUB EMPTY_Q
    IF R THEN R=A:Z%(R,0)=Z%(R,0)+32:GOTO EVAL_RETURN

    A0=A+1
    R=A0:GOSUB DEREF_R:A0=R

    REM get symbol in A$
    IF (Z%(A0,0)AND31)<>5 THEN A$=""
    IF (Z%(A0,0)AND31)=5 THEN A$=S$(Z%(A0,1))

    IF A$="def!" THEN GOTO EVAL_DEF
    IF A$="let*" THEN GOTO EVAL_LET
    IF A$="quote" THEN GOTO EVAL_QUOTE
    IF A$="quasiquote" THEN GOTO EVAL_QUASIQUOTE
    IF A$="do" THEN GOTO EVAL_DO
    IF A$="if" THEN GOTO EVAL_IF
    IF A$="fn*" THEN GOTO EVAL_FN
    GOTO EVAL_INVOKE

    EVAL_GET_A3:
      A3=Z%(Z%(Z%(A,1),1),1)+1
      R=A3:GOSUB DEREF_R:A3=R
    EVAL_GET_A2:
      A2=Z%(Z%(A,1),1)+1
      R=A2:GOSUB DEREF_R:A2=R
    EVAL_GET_A1:
      A1=Z%(A,1)+1
      R=A1:GOSUB DEREF_R:A1=R
      RETURN

    EVAL_DEF:
      REM PRINT "def!"
      GOSUB EVAL_GET_A2: REM set A1 and A2

      X=X+1:X%(X)=A1: REM push A1
      A=A2:GOSUB EVAL: REM eval a2
      A1=X%(X):X=X-1: REM pop A1

      IF ER<>-2 THEN GOTO EVAL_RETURN

      REM set a1 in env to a2
      K=A1:V=R:GOSUB ENV_SET
      GOTO EVAL_RETURN

    EVAL_LET:
      REM PRINT "let*"
      GOSUB EVAL_GET_A2: REM set A1 and A2

      X=X+1:X%(X)=A2: REM push/save A2
      X=X+1:X%(X)=E: REM push env for for later release

      REM create new environment with outer as current environment
      O=E:GOSUB ENV_NEW
      E=R
      EVAL_LET_LOOP:
        IF Z%(A1,1)=0 THEN GOTO EVAL_LET_LOOP_DONE

        X=X+1:X%(X)=A1: REM push A1
        REM eval current A1 odd element
        A=Z%(A1,1)+1:GOSUB EVAL
        A1=X%(X):X=X-1: REM pop A1

        REM set environment: even A1 key to odd A1 eval'd above
        K=A1+1:V=R:GOSUB ENV_SET
        AY=R:GOSUB RELEASE: REM release our use, ENV_SET took ownership

        REM skip to the next pair of A1 elements
        A1=Z%(Z%(A1,1),1)
        GOTO EVAL_LET_LOOP

      EVAL_LET_LOOP_DONE:
        E4=X%(X):X=X-1: REM pop previous env

        REM release previous environment if not the current EVAL env
        IF E4<>X%(X-2) THEN AY=E4:GOSUB RELEASE

        A2=X%(X):X=X-1: REM pop A2
        A=A2:GOTO EVAL_TCO_RECUR: REM TCO loop

    EVAL_DO:
      A=Z%(A,1): REM rest

      REM TODO: TCO

      REM push EVAL_AST return label/address
      X=X+1:X%(X)=2
      GOTO EVAL_AST
      EVAL_AST_RETURN_2:

      X=X+1:X%(X)=R: REM push eval'd list
      A=R:GOSUB LAST: REM return the last element
      AY=X%(X):X=X-1: REM pop eval'd list
      GOSUB RELEASE: REM release the eval'd list
      GOTO EVAL_RETURN

    EVAL_QUOTE:
      R=Z%(A,1)+1:GOSUB DEREF_R
      Z%(R,0)=Z%(R,0)+32
      GOTO EVAL_RETURN

    EVAL_QUASIQUOTE:
      R=Z%(A,1)+1:GOSUB DEREF_R
      A=R:GOSUB QUASIQUOTE
      REM add quasiquote result to pending release queue to free when
      REM next lower EVAL level returns (LV)
      Y=Y+1:Y%(Y,0)=R:Y%(Y,1)=LV

      A=R:GOTO EVAL_TCO_RECUR: REM TCO loop

    EVAL_IF:
      GOSUB EVAL_GET_A1: REM set A1
      REM push A
      X=X+1:X%(X)=A
      A=A1:GOSUB EVAL
      REM pop A
      A=X%(X):X=X-1
      IF (R=0) OR (R=1) THEN GOTO EVAL_IF_FALSE

      EVAL_IF_TRUE:
        AY=R:GOSUB RELEASE
        GOSUB EVAL_GET_A2: REM set A1 and A2 after EVAL
        A=A2:GOTO EVAL_TCO_RECUR: REM TCO loop
      EVAL_IF_FALSE:
        AY=R:GOSUB RELEASE
        REM if no false case (A3), return nil
        IF Z%(Z%(Z%(A,1),1),1)=0 THEN R=0:GOTO EVAL_RETURN
        GOSUB EVAL_GET_A3: REM set A1 - A3 after EVAL
        A=A3:GOTO EVAL_TCO_RECUR: REM TCO loop

    EVAL_FN:
      GOSUB EVAL_GET_A2: REM set A1 and A2
      A=A2:P=A1:GOSUB MAL_FUNCTION
      GOTO EVAL_RETURN

    EVAL_INVOKE:
      REM push EVAL_AST return label/address
      X=X+1:X%(X)=3
      GOTO EVAL_AST
      EVAL_AST_RETURN_3:

      REM if error, return f/args for release by caller
      IF ER<>-2 THEN GOTO EVAL_RETURN

      REM push f/args for release after call
      X=X+1:X%(X)=R

      F=R+1

      AR=Z%(R,1): REM rest
      R=F:GOSUB DEREF_R:F=R

      REM if metadata, get the actual object
      IF (Z%(F,0)AND31)>=16 THEN F=Z%(F,1)

      IF (Z%(F,0)AND31)=9 THEN GOTO EVAL_DO_FUNCTION
      IF (Z%(F,0)AND31)=10 THEN GOTO EVAL_DO_MAL_FUNCTION

      REM if error, pop and return f/args for release by caller
      R=X%(X):X=X-1
      ER=-1:ER$="apply of non-function":GOTO EVAL_RETURN

      EVAL_DO_FUNCTION:
        GOSUB DO_FUNCTION

        REM pop and release f/args
        AY=X%(X):X=X-1:GOSUB RELEASE
        GOTO EVAL_RETURN

      EVAL_DO_MAL_FUNCTION:
        E4=E: REM save the current environment for release

        REM create new environ using env stored with function
        O=Z%(F+1,1):BI=Z%(F+1,0):EX=AR:GOSUB ENV_NEW_BINDS

        REM release previous env if it is not the top one on the
        REM stack (X%(X-2)) because our new env refers to it and
        REM we no longer need to track it (since we are TCO recurring)
        IF E4<>X%(X-2) THEN AY=E4:GOSUB RELEASE

        REM claim the AST before releasing the list containing it
        A=Z%(F,1):Z%(A,0)=Z%(A,0)+32
        REM add AST to pending release queue to free as soon as EVAL
        REM actually returns (LV+1)
        Y=Y+1:Y%(Y,0)=A:Y%(Y,1)=LV+1

        REM pop and release f/args
        AY=X%(X):X=X-1:GOSUB RELEASE

        REM A set above
        E=R:GOTO EVAL_TCO_RECUR: REM TCO loop

  EVAL_RETURN:
    REM AZ=R: PR=1: GOSUB PR_STR
    REM PRINT "EVAL_RETURN R: ["+R$+"] ("+STR$(R)+"), LV:"+STR$(LV)+",ER:"+STR$(ER)

    REM release environment if not the top one on the stack
    IF E<>X%(X-1) THEN AY=E:GOSUB RELEASE

    LV=LV-1: REM track basic return stack level

    REM release everything we couldn't release earlier
    GOSUB RELEASE_PEND

    REM trigger GC
    TA=FRE(0)

    REM pop A and E off the stack
    E=X%(X-1):A=X%(X):X=X-2

    RETURN

REM PRINT(A) -> R$
MAL_PRINT:
  AZ=A:PR=1:GOSUB PR_STR
  RETURN

REM RE(A$) -> R
REM Assume D has repl_env
REM caller must release result
RE:
  R1=0
  GOSUB MAL_READ
  R1=R
  IF ER<>-2 THEN GOTO REP_DONE

  A=R:E=D:GOSUB EVAL

  REP_DONE:
    REM Release memory from MAL_READ
    IF R1<>0 THEN AY=R1:GOSUB RELEASE
    RETURN: REM caller must release result of EVAL

REM REP(A$) -> R$
REM Assume D has repl_env
REP:
  R1=0:R2=0
  GOSUB MAL_READ
  R1=R
  IF ER<>-2 THEN GOTO REP_DONE

  A=R:E=D:GOSUB EVAL
  R2=R
  IF ER<>-2 THEN GOTO REP_DONE

  A=R:GOSUB MAL_PRINT
  RT$=R$

  REP_DONE:
    REM Release memory from MAL_READ and EVAL
    IF R2<>0 THEN AY=R2:GOSUB RELEASE
    IF R1<>0 THEN AY=R1:GOSUB RELEASE
    R$=RT$
    RETURN

REM MAIN program
MAIN:
  GOSUB INIT_MEMORY

  LV=0

  REM create repl_env
  O=-1:GOSUB ENV_NEW:D=R

  REM core.EXT: defined in Basic
  E=D:GOSUB INIT_CORE_NS: REM set core functions in repl_env

  ZT=ZI: REM top of memory after base repl_env

  REM core.mal: defined using the language itself
  A$="(def! not (fn* (a) (if a false true)))"
  GOSUB RE:AY=R:GOSUB RELEASE

  A$="(def! load-file (fn* (f) (eval (read-string (str "
  A$=A$+CHR$(34)+"(do "+CHR$(34)+" (slurp f) "+CHR$(34)+")"+CHR$(34)+")))))"
  GOSUB RE:AY=R:GOSUB RELEASE

  REM load the args file
  A$="(def! -*ARGS*- (load-file "+CHR$(34)+".args.mal"+CHR$(34)+"))"
  GOSUB RE:AY=R:GOSUB RELEASE

  REM set the argument list
  A$="(def! *ARGV* (rest -*ARGS*-))"
  GOSUB RE:AY=R:GOSUB RELEASE

  REM get the first argument
  A$="(first -*ARGS*-)"
  GOSUB RE

  REM if there is an argument, then run it as a program
  IF R<>0 THEN AY=R:GOSUB RELEASE:GOTO RUN_PROG
  REM no arguments, start REPL loop
  IF R=0 THEN GOTO REPL_LOOP

  RUN_PROG:
    REM run a single mal program and exit
    A$="(load-file (first -*ARGS*-))"
    GOSUB RE
    IF ER<>-2 THEN GOSUB PRINT_ERROR
    END

  REPL_LOOP:
    A$="user> ":GOSUB READLINE: REM call input parser
    IF EOF=1 THEN GOTO QUIT

    A$=R$:GOSUB REP: REM call REP

    IF ER<>-2 THEN GOSUB PRINT_ERROR:GOTO REPL_LOOP
    PRINT R$
    GOTO REPL_LOOP

  QUIT:
    REM P1=ZT: P2=-1: GOSUB PR_MEMORY
    GOSUB PR_MEMORY_SUMMARY
    END

  PRINT_ERROR:
    PRINT "Error: "+ER$
    ER=-2:ER$=""
    RETURN

