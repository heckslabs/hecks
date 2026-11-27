-- A genuinely finite and inspectable one-operation candidate: an extensional
-- table of allowed configuration pairs and one `fire?` lookup operation.
namespace OneFire

def Declared {S : Type} (table : List (S × S)) (source target : S) : Prop :=
  (source, target) ∈ table

def Functional {S : Type} (table : List (S × S)) : Prop :=
  ∀ source first second,
    Declared table source first → Declared table source second → first = second

def fire? {S : Type} [DecidableEq S] : List (S × S) → S → Option S
  | [], _ => none
  | (src, to) :: rest, source =>
      if src = source then some to else fire? rest source

theorem fire_sound {S : Type} [DecidableEq S]
    (table : List (S × S)) (source target : S)
    (h : fire? table source = some target) :
    Declared table source target := by
  induction table with
  | nil => simp [fire?] at h
  | cons edge rest ih =>
    obtain ⟨src, to⟩ := edge
    by_cases hs : src = source
    · simp [fire?, hs] at h
      subst src
      subst target
      simp [Declared]
    · simp [fire?, hs] at h
      exact List.mem_cons_of_mem _ (ih h)

theorem declared_has_a_result {S : Type} [DecidableEq S]
    (table : List (S × S)) (source target : S)
    (h : Declared table source target) :
    ∃ result, fire? table source = some result := by
  induction table with
  | nil => simp [Declared] at h
  | cons edge rest ih =>
    obtain ⟨src, to⟩ := edge
    by_cases hs : src = source
    · exact ⟨to, by simp [fire?, hs]⟩
    · have ht : Declared rest source target := by
        have hm : (source, target) = (src, to) ∨
            (source, target) ∈ rest := List.mem_cons.mp h
        rcases hm with hm | hm
        · have : source = src := congrArg Prod.fst hm
          exact False.elim (hs this.symm)
        · exact hm
      obtain ⟨result, hr⟩ := ih ht
      exact ⟨result, by simpa [fire?, hs] using hr⟩

theorem fire_complete_if_functional {S : Type} [DecidableEq S]
    (table : List (S × S)) (source target : S)
    (hf : Functional table) :
    Declared table source target ↔ fire? table source = some target := by
  constructor
  · intro hd
    obtain ⟨result, hr⟩ := declared_has_a_result table source target hd
    have hresult := fire_sound table source result hr
    have heq := hf source result target hresult hd
    simpa [heq] using hr
  · exact fire_sound table source target

theorem first_match_is_a_determination :
    Declared ([(0, 1), (0, 2)] : List (Nat × Nat)) 0 2 ∧
    fire? ([(0, 1), (0, 2)] : List (Nat × Nat)) 0 = some 1 ∧
    fire? ([(0, 1), (0, 2)] : List (Nat × Nat)) 0 ≠ some 2 := by
  simp [Declared, fire?]

-- Finite concrete tables cannot be total over unbounded fresh Nat sources.
def maxSource : List (Nat × Nat) → Nat
  | [] => 0
  | (src, _) :: rest => max src (maxSource rest)

theorem source_le_max (table : List (Nat × Nat))
    (source target : Nat) (h : Declared table source target) :
    source ≤ maxSource table := by
  induction table with
  | nil => simp [Declared] at h
  | cons edge rest ih =>
    obtain ⟨src, to⟩ := edge
    rcases List.mem_cons.mp h with head | tail
    · have hs : source = src := congrArg Prod.fst head
      subst source
      exact Nat.le_max_left _ _
    · exact Nat.le_trans (ih tail) (Nat.le_max_right _ _)

theorem fresh_source_has_no_fire (table : List (Nat × Nat)) :
    fire? table (maxSource table + 1) = none := by
  cases h : fire? table (maxSource table + 1) with
  | none => rfl
  | some target =>
    have hd := fire_sound table (maxSource table + 1) target h
    have hb := source_le_max table (maxSource table + 1) target hd
    exact False.elim ((Nat.not_le_of_gt (Nat.lt_succ_self _)) hb)

theorem finite_table_cannot_increment_everywhere (table : List (Nat × Nat)) :
    ¬ ∀ source, fire? table source = some (source + 1) := by
  intro h
  have hn := h (maxSource table + 1)
  rw [fresh_source_has_no_fire] at hn
  cases hn

-- A symbolic rule repairs that limitation without an arbitrary callback, but
-- the expression language and its evaluator are now explicit machinery.
inductive Expr where
  | input
  | literal : Nat → Expr
  | plus : Expr → Expr → Expr
  deriving Repr

def eval : Expr → Nat → Nat
  | .input, source => source
  | .literal n, _ => n
  | .plus left right, source => eval left source + eval right source

structure SymbolicRule where
  output : Expr

def symbolicDeclared (rule : SymbolicRule) (source target : Nat) : Prop :=
  eval rule.output source = target

def symbolicFire (rule : SymbolicRule) (source : Nat) : Nat :=
  eval rule.output source

theorem symbolic_fire_exact (rule : SymbolicRule) (source target : Nat) :
    symbolicDeclared rule source target ↔ symbolicFire rule source = target := by
  rfl

def incrementRule : SymbolicRule :=
  ⟨.plus .input (.literal 1)⟩

theorem symbolic_increment_everywhere (source : Nat) :
    symbolicFire incrementRule source = source + 1 := by
  rfl

#print axioms fire_sound
#print axioms fire_complete_if_functional
#print axioms first_match_is_a_determination
#print axioms fresh_source_has_no_fire
#print axioms finite_table_cannot_increment_everywhere
#print axioms symbolic_fire_exact
#print axioms symbolic_increment_everywhere

end OneFire
