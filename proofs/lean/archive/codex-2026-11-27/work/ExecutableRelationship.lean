-- Finite, inspectable operational fragment. No callback or arbitrary relation
-- value occurs in the instruction grammar.
import RelationshipExperiment

namespace ExecutableRelationship

open RelationshipExperiment

inductive Primary where
  | working | accepted | refused | faulted
  deriving DecidableEq, Repr

inductive Reaction where
  | idle | delivered | refused
  deriving DecidableEq, Repr

structure Config where
  durable : Nat
  staged : Nat
  pending : List String
  events : List String
  primary : Primary
  reaction : Reaction
  deriving DecidableEq, Repr

inductive Instr where
  | requireAtLeast : Nat → Instr
  | add : Nat → Instr
  | emit : String → Instr
  | commit : Instr
  | commitFault : Instr
  | reactionRefuse : Instr
  deriving DecidableEq, Repr

def initial (n : Nat) : Config :=
  ⟨n, n, [], [], .working, .idle⟩

def step : Instr → Config → Config
  | .requireAtLeast n, s =>
      if s.primary == .working && s.staged < n then
        { s with staged := s.durable, pending := [], primary := .refused }
      else s
  | .add n, s =>
      if s.primary == .working then { s with staged := s.staged + n } else s
  | .emit e, s =>
      if s.primary == .working then { s with pending := s.pending ++ [e] } else s
  | .commit, s =>
      if s.primary == .working then
        { s with durable := s.staged, events := s.events ++ s.pending,
                 pending := [], primary := .accepted }
      else s
  | .commitFault, s =>
      if s.primary == .working then
        { s with staged := s.durable, pending := [], primary := .faulted }
      else s
  | .reactionRefuse, s =>
      if s.primary == .accepted then { s with reaction := .refused } else s

def run : List Instr → Config → Config
  | [], s => s
  | i :: rest, s => run rest (step i s)

-- Every instruction denotes exactly its executable graph relation. Thus the
-- recursive program interpreter realizes relational composition, not merely
-- a subset of an unrestricted nondeterministic specification.
def instrRel (i : Instr) : Rel Config Config := graph (step i)

def programRel : List Instr → Rel Config Config
  | [] => identity
  | i :: rest => thenRel (instrRel i) (programRel rest)

theorem run_realizes_relation (is : List Instr) (s t : Config) :
    programRel is s t ↔ run is s = t := by
  induction is generalizing s with
  | nil => simp [programRel, run, identity]
  | cons i rest ih =>
    simp only [programRel, thenRel, instrRel, graph, run]
    constructor
    · rintro ⟨middle, hm, hr⟩
      rw [hm]
      exact (ih middle).mp hr
    · intro hr
      exact ⟨step i s, rfl, (ih (step i s)).mpr hr⟩

theorem commit_atomic_in_model (s : Config) (h : s.primary = .working) :
    (step .commit s).durable = s.staged ∧
    (step .commit s).events = s.events ++ s.pending ∧
    (step .commit s).primary = .accepted := by
  simp [step, h]

theorem refused_guard_does_not_commit (s : Config) (n : Nat)
    (hw : s.primary = .working) (hbad : s.staged < n) :
    (step (.requireAtLeast n) s).durable = s.durable ∧
    (step (.requireAtLeast n) s).events = s.events ∧
    (step (.requireAtLeast n) s).pending = [] ∧
    (step (.requireAtLeast n) s).primary = .refused := by
  simp [step, hw, hbad]

theorem reaction_refusal_keeps_commit (s : Config)
    (h : s.primary = .accepted) :
    (step .reactionRefuse s).durable = s.durable ∧
    (step .reactionRefuse s).events = s.events ∧
    (step .reactionRefuse s).primary = .accepted ∧
    (step .reactionRefuse s).reaction = .refused := by
  simp [step, h]

theorem commit_fault_rolls_back (s : Config)
    (h : s.primary = .working) :
    (step .commitFault s).durable = s.durable ∧
    (step .commitFault s).events = s.events ∧
    (step .commitFault s).pending = [] ∧
    (step .commitFault s).primary = .faulted := by
  simp [step, h]

-- This function represents an adapter that wrote state before event failure.
-- Its observable result is forbidden by the atomic commit contract.
def tornCommit (s : Config) : Config :=
  { s with durable := s.staged, pending := [], primary := .faulted }

theorem torn_commit_is_not_atomic :
    tornCommit (step (.emit "Placed") (step (.add 2) (initial 1))) ≠
      step .commitFault (step (.emit "Placed") (step (.add 2) (initial 1))) := by decide

def acceptedExample : List Instr :=
  [.requireAtLeast 1, .add 2, .emit "Credited", .commit]

def refusedExample : List Instr :=
  [.add 2, .emit "uncommitted", .requireAtLeast 5, .commit]

def reactionExample : List Instr :=
  [.add 2, .emit "Requested", .commit, .reactionRefuse]

theorem accepted_example :
    run acceptedExample (initial 1) =
      ⟨3, 3, [], ["Credited"], .accepted, .idle⟩ := by decide

theorem refused_example :
    run refusedExample (initial 1) =
      ⟨1, 1, [], [], .refused, .idle⟩ := by decide

theorem reaction_example :
    run reactionExample (initial 1) =
      ⟨3, 3, [], ["Requested"], .accepted, .refused⟩ := by decide

#print axioms run_realizes_relation
#print axioms commit_atomic_in_model
#print axioms refused_guard_does_not_commit
#print axioms reaction_refusal_keeps_commit
#print axioms commit_fault_rolls_back
#print axioms torn_commit_is_not_atomic
#print axioms accepted_example
#print axioms refused_example
#print axioms reaction_example

end ExecutableRelationship
