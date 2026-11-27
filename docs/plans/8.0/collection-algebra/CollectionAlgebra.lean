import Std

namespace Hecks.CollectionAlgebra

variable {α β γ : Type}

def select (p : α → Bool) (xs : List α) : List α := xs.filter p

def project (f : α → β) (xs : List α) : List β := xs.map f

theorem select_fusion (p q : α → Bool) (xs : List α) :
    select q (select p xs) = select (fun x => p x && q x) xs := by
  induction xs with
  | nil => rfl
  | cons x xs ih =>
    cases hp : p x <;> cases hq : q x <;>
      simp [select, hp, hq, ← select, ih]

theorem project_fusion (f : α → β) (g : β → γ) (xs : List α) :
    project g (project f xs) = project (fun x => g (f x)) xs := by
  induction xs with
  | nil => rfl
  | cons x xs ih => simp [project, ← project, ih]

structure AverageState where
  total : Int
  count : Nat
  deriving DecidableEq, Repr

def empty : AverageState := ⟨0, 0⟩
def combine (a b : AverageState) : AverageState :=
  ⟨a.total + b.total, a.count + b.count⟩
def accumulate (xs : List Int) : AverageState :=
  match xs with
  | [] => empty
  | x :: rest => combine ⟨x, 1⟩ (accumulate rest)

theorem combine_assoc (a b c : AverageState) :
    combine (combine a b) c = combine a (combine b c) := by
  cases a; cases b; cases c
  simp [combine, Int.add_assoc, Nat.add_assoc]

theorem combine_empty (a : AverageState) : combine empty a = a := by
  cases a
  simp [combine, empty]

theorem partition (xs ys : List Int) :
    accumulate (xs ++ ys) = combine (accumulate xs) (accumulate ys) := by
  induction xs with
  | nil => simp [accumulate, combine_empty]
  | cons x xs ih => simp [accumulate, ih, combine_assoc]

end Hecks.CollectionAlgebra
