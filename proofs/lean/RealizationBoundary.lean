import RelationshipExperiment

namespace RealizationBoundary

open RelationshipExperiment

-- A realizer returns a witnessed output, not just the proposition that an
-- output would be allowed. This is the smallest abstract execution interface.
def Total {A B : Type} (r : Rel A B) : Prop :=
  ∀ a, ∃ b, r a b

def Realizer {A B : Type} (r : Rel A B) : Type :=
  (a : A) → { b : B // r a b }

-- Determination is a narrower relationship within admissibility. Its
-- single-valued and total laws make the selected output unique per input.
def Refines {A B : Type} (determined admissible : Rel A B) : Prop :=
  ∀ a b, determined a b → admissible a b

def SingleValued {A B : Type} (r : Rel A B) : Prop :=
  ∀ a b c, r a b → r a c → b = c

theorem determined_witness_is_admissible {A B : Type}
    {determined admissible : Rel A B}
    (h : Refines determined admissible)
    (witness : Realizer determined) (a : A) :
    admissible a (witness a).val :=
  h a (witness a).val (witness a).property

-- Logical existence supplies a witness only via classical choice. This
-- noncomputable definition does not implement a runtime scheduler.
noncomputable def classicalRealizer {A B : Type} (r : Rel A B)
    (h : Total r) : Realizer r :=
  fun a => ⟨Classical.choose (h a), Classical.choose_spec (h a)⟩

def full : Rel Unit Bool := fun _ _ => True

def flipOutput (r : Rel Unit Bool) : Rel Unit Bool :=
  fun u b => r u (!b)

theorem full_is_flip_invariant : RelEq (flipOutput full) full := by
  intro _ _
  simp [flipOutput, full]

theorem no_bool_fixed_by_flip (b : Bool) : b ≠ !b := by
  cases b <;> decide

-- A representation-independent selector should commute with renaming its
-- outputs. On the symmetric full relation, this would require a Boolean
-- fixed by swapping true and false. None exists.
theorem no_equivariant_selector :
    ¬ ∃ (pick : (Rel Unit Bool) → Bool),
      (∀ r q, RelEq r q → pick r = pick q) ∧
      (∀ r, pick (flipOutput r) = !(pick r)) := by
  rintro ⟨pick, respects, equivariant⟩
  have same := respects (flipOutput full) full full_is_flip_invariant
  have flipped := equivariant full
  have fixed : pick full = !(pick full) := by
    rw [same] at flipped
    exact flipped
  exact (no_bool_fixed_by_flip (pick full)) fixed

-- A deterministic relation avoids choice in this finite example. The choice
-- is then specified by the relation's contents, not derived from relationhood.
def chosenTrue : Rel Unit Bool := graph (fun _ => true)
def chosenFalse : Rel Unit Bool := graph (fun _ => false)

def trueRealizer : Realizer chosenTrue :=
  fun _ => ⟨true, rfl⟩

theorem chosen_true_is_unique (b : Bool) (h : chosenTrue () b) : b = true := by
  simpa [chosenTrue, graph] using h.symm

theorem both_choices_refine_full :
    Refines chosenTrue full ∧ Refines chosenFalse full := by
  constructor <;> intro _ _ _ <;> trivial

theorem both_choices_are_single_valued :
    SingleValued chosenTrue ∧ SingleValued chosenFalse := by
  constructor <;> intro _ _ _ h₁ h₂
  · exact graph_query_is_single_valued (fun _ : Unit => true) () _ _ h₁ h₂
  · exact graph_query_is_single_valued (fun _ : Unit => false) () _ _ h₁ h₂

theorem determinations_can_disagree :
    ¬ RelEq chosenTrue chosenFalse := by
  intro h
  have hx := (h () true).mp rfl
  cases hx

-- Identity and composition alone cannot create a change. A nonidentity
-- generator (or an unrestricted relation parameter) must carry the behavior.
inductive CompositionOnly where
  | identity
  | thenDo : CompositionOnly → CompositionOnly → CompositionOnly

def denote : CompositionOnly → Rel Bool Bool
  | .identity => identity
  | .thenDo p q => thenRel (denote p) (denote q)

theorem composition_only_is_identity (p : CompositionOnly) :
    RelEq (denote p) identity := by
  induction p with
  | identity =>
    intro a b
    rfl
  | thenDo p q hp hq =>
    have h := composition_congruent hp hq
    intro a b
    exact (h a b).trans ((left_identity identity) a b)

def forceTrue : Rel Bool Bool := graph (fun _ => true)

theorem composition_only_cannot_force_true :
    ¬ ∃ p, RelEq (denote p) forceTrue := by
  rintro ⟨p, hp⟩
  have hid := composition_only_is_identity p
  have h := (hid false true).mp ((hp false true).mpr rfl)
  cases h

#print axioms full_is_flip_invariant
#print axioms no_equivariant_selector
#print axioms chosen_true_is_unique
#print axioms determined_witness_is_admissible
#print axioms both_choices_refine_full
#print axioms both_choices_are_single_valued
#print axioms determinations_can_disagree
#print axioms classicalRealizer
#print axioms composition_only_is_identity
#print axioms composition_only_cannot_force_true

end RealizationBoundary
