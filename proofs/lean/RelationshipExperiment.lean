-- Candidate relationship-only denotational core. A relation states which
-- input/output pairs are allowed; it does not itself choose or commit one.
namespace RelationshipExperiment

abbrev Rel (A B : Type) := A → B → Prop

def identity {A : Type} : Rel A A := fun a b => a = b

def thenRel {A B C : Type} (r : Rel A B) (q : Rel B C) : Rel A C :=
  fun a c => ∃ b, r a b ∧ q b c

def RelEq {A B : Type} (r q : Rel A B) : Prop :=
  ∀ a b, r a b ↔ q a b

theorem left_identity {A B : Type} (r : Rel A B) :
    RelEq (thenRel identity r) r := by
  intro a b
  simp [thenRel, identity]

theorem right_identity {A B : Type} (r : Rel A B) :
    RelEq (thenRel r identity) r := by
  intro a b
  simp [thenRel, identity]

theorem associative {A B C D : Type}
    (r : Rel A B) (q : Rel B C) (p : Rel C D) :
    RelEq (thenRel (thenRel r q) p) (thenRel r (thenRel q p)) := by
  intro a d
  constructor
  · rintro ⟨c, ⟨b, hr, hq⟩, hp⟩
    exact ⟨b, hr, c, hq, hp⟩
  · rintro ⟨b, hr, c, hq, hp⟩
    exact ⟨c, ⟨b, hr, hq⟩, hp⟩

theorem composition_congruent {A B C : Type}
    {r r' : Rel A B} {q q' : Rel B C}
    (hr : RelEq r r') (hq : RelEq q q') :
    RelEq (thenRel r q) (thenRel r' q') := by
  intro a c
  constructor
  · rintro ⟨b, hab, hbc⟩
    exact ⟨b, (hr a b).mp hab, (hq b c).mp hbc⟩
  · rintro ⟨b, hab, hbc⟩
    exact ⟨b, (hr a b).mpr hab, (hq b c).mpr hbc⟩

-- A Condition P embeds as the subidentity relationship below.
def condition {A : Type} (P : A → Prop) : Rel A A :=
  fun a b => a = b ∧ P a

theorem condition_satisfaction {A : Type} (P : A → Prop) (a : A) :
    condition P a a ↔ P a := by
  simp [condition]

theorem condition_cannot_change_state {A : Type} (P : A → Prop)
    (a b : A) (h : condition P a b) : a = b := h.1

theorem conditions_compose_as_conjunction {A : Type} (P Q : A → Prop) :
    RelEq (thenRel (condition P) (condition Q))
      (condition (fun a => P a ∧ Q a)) := by
  intro a b
  constructor
  · rintro ⟨middle, ⟨hm, hp⟩, ⟨hb, hq⟩⟩
    subst middle
    exact ⟨hb, hp, hq⟩
  · rintro ⟨hab, hp, hq⟩
    exact ⟨a, ⟨rfl, hp⟩, ⟨hab, hq⟩⟩

-- A function, including a query from state to an answer, has a graph relation.
def graph {A B : Type} (f : A → B) : Rel A B :=
  fun a b => f a = b

theorem graph_query_is_single_valued {A B : Type} (f : A → B)
    (a : A) (b₁ b₂ : B) (h₁ : graph f a b₁) (h₂ : graph f a b₂) :
    b₁ = b₂ := by
  exact h₁.symm.trans h₂

-- Invariants compose at arbitrary finite depth when every relation preserves them.
def Preserves {A : Type} (I : A → Prop) (r : Rel A A) : Prop :=
  ∀ a b, I a → r a b → I b

theorem preserves_then {A : Type} {I : A → Prop}
    {r q : Rel A A} (hr : Preserves I r) (hq : Preserves I q) :
    Preserves I (thenRel r q) := by
  intro a c hi h
  obtain ⟨b, hab, hbc⟩ := h
  exact hq b c (hr a b hi hab) hbc

def chain {A : Type} : List (Rel A A) → Rel A A
  | [] => identity
  | r :: rest => thenRel r (chain rest)

theorem preserves_chain {A : Type} {I : A → Prop}
    (rs : List (Rel A A)) (h : ∀ r ∈ rs, Preserves I r) :
    Preserves I (chain rs) := by
  induction rs with
  | nil =>
    intro a b hi hab
    simpa [chain, identity] using hab ▸ hi
  | cons r rest ih =>
    apply preserves_then
    · exact h r (by simp)
    · exact ih (by
        intro q hq
        exact h q (by simp [hq]))

-- Pointwise visible answers are too weak for contextual replacement.
def ObsEq {A B O : Type} (observe : B → O)
    (r q : Rel A B) : Prop :=
  ∀ a o, (∃ b, r a b ∧ observe b = o) ↔
         (∃ b, q a b ∧ observe b = o)

abbrev SecretState := Bool × Bool -- visible, hidden

def setHiddenTrue : Rel SecretState SecretState :=
  fun s t => t = (s.1, true)

def setHiddenFalse : Rel SecretState SecretState :=
  fun s t => t = (s.1, false)

def revealHidden : Rel SecretState SecretState :=
  fun s t => t = (s.2, s.2)

def visible (s : SecretState) : Bool := s.1

theorem same_immediate_observation :
    ObsEq visible setHiddenTrue setHiddenFalse := by
  intro s o
  simp [setHiddenTrue, setHiddenFalse, visible]

theorem observation_not_congruent_under_continuation :
    ¬ ObsEq visible
      (thenRel setHiddenTrue revealHidden)
      (thenRel setHiddenFalse revealHidden) := by
  intro h
  have hx := h (false, false) true
  simp [thenRel, setHiddenTrue, setHiddenFalse,
        revealHidden, visible] at hx

-- One allowed relation does not specify which possible result a concrete
-- implementation realizes. Mere refinement to it is too weak for parity.
def allowed : Rel Unit Bool := fun _ _ => True
def chooseTrue : Rel Unit Bool := graph (fun _ => true)
def chooseFalse : Rel Unit Bool := graph (fun _ => false)

theorem two_implementations_refine_same_relation :
    (∀ u b, chooseTrue u b → allowed u b) ∧
    (∀ u b, chooseFalse u b → allowed u b) ∧
    ¬ ObsEq (fun b : Bool => b) chooseTrue chooseFalse := by
  constructor
  · intro _ _ _
    trivial
  constructor
  · intro _ _ _
    trivial
  · intro h
    have hx := h () true
    simp [chooseTrue, chooseFalse, graph] at hx

#print axioms associative
#print axioms composition_congruent
#print axioms conditions_compose_as_conjunction
#print axioms preserves_chain
#print axioms observation_not_congruent_under_continuation
#print axioms two_implementations_refine_same_relation

end RelationshipExperiment
