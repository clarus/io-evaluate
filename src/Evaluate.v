Require Import Io.All.
Require Import Monad.All.

Import C.Notations.
Local Open Scope type.

Fixpoint pure {E : Effect.t} {A : Type}
  (eval : forall (c : Effect.command E), Effect.answer E c)
  (eval_choose : forall A, A -> A -> A) (x : C.t E A) : A :=
  match x with
  | C.Ret _ v => v
  | C.Call c => eval c
  | C.Let _ _ x f =>
    let x := pure eval eval_choose x in
    pure eval eval_choose (f x)
  | C.Join _ _ x y => (pure eval eval_choose x, pure eval eval_choose y)
  | C.Choose _ x y =>
    eval_choose _ (pure eval eval_choose x) (pure eval eval_choose y)
  end.

(** Evaluate the commands of a computation using other commands. *)
Fixpoint command {E1 E2 : Effect.t} {A : Type}
  (eval : forall (c : Effect.command E1), C.t E2 (Effect.answer E1 c))
  (x : C.t E1 A) : C.t E2 A :=
  match x with
  | C.Ret _ v => C.Ret _ v
  | C.Call c => eval c
  | C.Let _ _ x f => C.Let _ _ (command eval x) (fun x => command eval (f x))
  | C.Join _ _ x y => C.Join _ _ (command eval x) (command eval y)
  | C.Choose _ x y => C.Choose _ (command eval x) (command eval y)
  end.

Fixpoint exception {E1 E2 : Effect.t} {Exc A : Type}
  (eval : forall (c : Effect.command E1), C.t E2 (Effect.answer E1 c + Exc))
  (eval_join : Exc -> Exc -> Exc) (x : C.t E1 A) : C.t E2 (A + Exc) :=
  match x with
  | C.Ret _ v => ret (inl v)
  | C.Call c => eval c
  | C.Let _ _ x f =>
    let! x := exception eval eval_join x in
    match x with
    | inl x => exception eval eval_join (f x)
    | inr exc => ret (inr exc)
    end
  | C.Join _ _ x y =>
    let! xy := join (exception eval eval_join x) (exception eval eval_join y) in
    match xy with
    | (inl x, inl y) => ret (inl (x, y))
    | (inr exc, inl _) | (inl _, inr exc) => ret (inr exc)
    | (inr exc_x, inr exc_y) => ret (inr (eval_join exc_x exc_y))
    end
  | C.Choose _ x y =>
    choose (exception eval eval_join x) (exception eval eval_join y)
  end.

Module EvalMonad.
  Record t (E : Effect.t) (M : Type -> Type) := New {
    command : forall (c : Effect.command E), M (Effect.answer E c);
    join : forall A B, M A -> M B -> M (A * B);
    choose : forall A, M A -> M A -> M A }.
  Arguments command {E M} _ _.
  Arguments join {E M} _ {A B} _ _.
  Arguments choose {E M} _ {A} _ _.
End EvalMonad.

Fixpoint monad {E : Effect.t} {A : Type} {M : Type -> Type} (m : Monad.t M)
  (eval : EvalMonad.t E M) (x : C.t E A) : M A :=
  match x with
  | C.Ret _ v => Monad.ret m v
  | C.Call c => EvalMonad.command eval c
  | C.Let _ _ x f =>
    Monad.bind m (monad m eval x) (fun x =>
    monad m eval (f x))
  | C.Join _ _ x y => EvalMonad.join eval (monad m eval x) (monad m eval y)
  | C.Choose _ x y => EvalMonad.choose eval (monad m eval x) (monad m eval y)
  end.

Module Handler.
  Record t (E : Effect.t) (S : Type) (M : Type -> Type) : Type := New {
    command : forall A (c : Effect.command E),
      S -> (Effect.answer E c -> S -> M A) -> M A }.
  Arguments command {E S M} _ {A} _ _ _.
End Handler.

Fixpoint algebraic {E S M A B} (h : Handler.t E S M) (x : C.t E A) (s : S)
  : (A -> S -> M B) -> M B :=
  match x with
  | C.Ret _ v => fun k => k v s
  | C.Call c => fun k => Handler.command h c s k
  | C.Let _ _ x f => fun k =>
    (algebraic h x s) (fun v_x s =>
    algebraic h (f v_x) s k)
  | C.Join _ _ x y => fun k =>
    (algebraic h x s) (fun v_x s =>
    (algebraic h y s) (fun v_y s =>
    k (v_x, v_y) s))
  | C.Choose _ x _ => fun k => algebraic h x s k
  end.

Module Run.
  Fixpoint command {E1 E2 : Effect.t} {A : Type}
    {eval : forall (c : Effect.command E1), C.t E2 (Effect.answer E1 c)}
    (run : forall c (a : Effect.answer E1 c), Run.t (eval c) a)
    {x : C.t E1 A} {v : A} (r : Run.t x v) : Run.t (command eval x) v.
    destruct r; simpl.
    - apply Run.Ret.
    - apply run.
    - eapply Run.Let. apply (command _ _ _ _ run _ _ r1).
      apply (command _ _ _ _ run _ _ r2).
    - apply Run.ChooseLeft.
      apply (command _ _ _ _ run _ _ r).
    - apply Run.ChooseRight.
      apply (command _ _ _ _ run _ _ r).
    - apply Run.Join.
      + apply (command _ _ _ _ run _ _ r1).
      + apply (command _ _ _ _ run _ _ r2).
  Defined.

  Fixpoint exception {E1 E2 : Effect.t} {Exc A : Type}
    {eval : forall (c : Effect.command E1), C.t E2 (Effect.answer E1 c + Exc)}
    {eval_join : Exc -> Exc -> Exc}
    (run : forall c (a : Effect.answer E1 c), Run.t (eval c) (inl a))
    {x : C.t E1 A} {v : A} (r : Run.t x v)
    : Run.t (exception eval eval_join x) (inl v).
    destruct r; simpl.
    - apply Run.Ret.
    - apply run.
    - eapply Run.Let. apply (exception _ _ _ _ _ _ run _ _ r1).
      apply (exception _ _ _ _ _ _ run _ _ r2).
    - apply Run.ChooseLeft.
      apply (exception _ _ _ _ _ _ run _ _ r).
    - apply Run.ChooseRight.
      apply (exception _ _ _ _ _ _ run _ _ r).
    - eapply Run.Let.
      + eapply Run.Join.
        * apply (exception _ _ _ _ _ _ run _ _ r1).
        * apply (exception _ _ _ _ _ _ run _ _ r2).
      + apply Run.Ret.
  Defined.
End Run.

Module I.
  Import C.I.Notations.

  CoFixpoint command {E1 E2 : Effect.t} {A : Type}
    (eval : forall (c : Effect.command E1), C.I.t E2 (Effect.answer E1 c))
    (x : C.I.t E1 A) : C.I.t E2 A :=
    match x with
    | C.I.Ret _ v => C.I.Ret _ v
    | C.I.Call c => eval c
    | C.I.Let _ _ x f =>
      C.I.Let _ _ (command eval x) (fun x => command eval (f x))
    | C.I.Join _ _ x y => C.I.Join _ _ (command eval x) (command eval y)
    | C.I.Choose _ x y => C.I.Choose _ (command eval x) (command eval y)
    end.

  CoFixpoint exception {E1 E2 : Effect.t} {Exc A : Type}
    (eval : forall (c : Effect.command E1), C.I.t E2 (Effect.answer E1 c + Exc))
    (eval_join : Exc -> Exc -> Exc) (x : C.I.t E1 A) : C.I.t E2 (A + Exc) :=
    match x with
    | C.I.Ret _ v => I.ret (inl v)
    | C.I.Call c => eval c
    | C.I.Let _ _ x f =>
      ilet! x := exception eval eval_join x in
      match x with
      | inl x => exception eval eval_join (f x)
      | inr exc => I.ret (inr exc)
      end
    | C.I.Join _ _ x y =>
      ilet! xy :=
        I.join (exception eval eval_join x) (exception eval eval_join y) in
      match xy with
      | (inl x, inl y) => I.ret (inl (x, y))
      | (inr exc, inl _) | (inl _, inr exc) => I.ret (inr exc)
      | (inr exc_x, inr exc_y) => I.ret (inr (eval_join exc_x exc_y))
      end
    | C.I.Choose _ x y =>
      I.choose (exception eval eval_join x) (exception eval eval_join y)
    end.
End I.
