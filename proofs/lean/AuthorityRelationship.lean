-- A narrow World boundary: only the owning actor may run instructions.
-- This proves a composition law for the wrapper, not Hecks authorization.
import ExecutableRelationship

namespace AuthorityRelationship

open ExecutableRelationship
open RelationshipExperiment

structure WorldConfig where
  world : Nat
  actor : Nat
  core : Config
  deriving DecidableEq, Repr

def authorized (s : WorldConfig) : Prop := s.actor = s.world

def protectedStep (i : Instr) (s : WorldConfig) : WorldConfig :=
  if s.actor == s.world then { s with core := step i s.core }
  else
    let core := s.core
    let refusedCore := { core with staged := s.core.durable,
                                    pending := [], primary := .refused }
    { s with core := refusedCore }

def protectedRun : List Instr → WorldConfig → WorldConfig
  | [], s => s
  | i :: rest, s => protectedRun rest (protectedStep i s)

def protectedRel (i : Instr) : Rel WorldConfig WorldConfig :=
  graph (protectedStep i)

def protectedProgramRel : List Instr → Rel WorldConfig WorldConfig
  | [] => identity
  | i :: rest => thenRel (protectedRel i) (protectedProgramRel rest)

theorem protected_run_realizes_relation (is : List Instr) (s t : WorldConfig) :
    protectedProgramRel is s t ↔ protectedRun is s = t := by
  induction is generalizing s with
  | nil => simp [protectedProgramRel, protectedRun, identity]
  | cons i rest ih =>
    simp only [protectedProgramRel, thenRel, protectedRel, graph, protectedRun]
    constructor
    · rintro ⟨middle, hm, hr⟩
      rw [hm]
      exact (ih middle).mp hr
    · intro hr
      exact ⟨protectedStep i s, rfl, (ih (protectedStep i s)).mpr hr⟩

theorem protected_step_keeps_owner (i : Instr) (s : WorldConfig) :
    (protectedStep i s).world = s.world ∧
    (protectedStep i s).actor = s.actor := by
  by_cases h : s.actor = s.world <;> simp [protectedStep, h]

theorem unauthorized_step_cannot_commit (i : Instr) (s : WorldConfig)
    (h : s.actor ≠ s.world) :
    (protectedStep i s).core.durable = s.core.durable ∧
    (protectedStep i s).core.events = s.core.events ∧
    (protectedStep i s).core.primary = .refused := by
  simp [protectedStep, h]

theorem unauthorized_program_cannot_commit (is : List Instr) (s : WorldConfig)
    (h : s.actor ≠ s.world) :
    (protectedRun is s).core.durable = s.core.durable ∧
    (protectedRun is s).core.events = s.core.events ∧
    (protectedRun is s).world = s.world ∧
    (protectedRun is s).actor = s.actor := by
  induction is generalizing s with
  | nil => simp [protectedRun]
  | cons i rest ih =>
    have hs := unauthorized_step_cannot_commit i s h
    have ho := protected_step_keeps_owner i s
    have hnext : (protectedStep i s).actor ≠ (protectedStep i s).world := by
      simpa [ho.1, ho.2] using h
    have tail := ih (protectedStep i s) hnext
    simpa [protectedRun, hs.1, hs.2.1, ho.1, ho.2] using tail

def foreignStart : WorldConfig := ⟨1, 2, initial 0⟩

theorem cross_world_write_is_refused :
    (protectedRun [.add 5, .emit "unauthorized", .commit] foreignStart).core =
      { initial 0 with primary := .refused } := by decide

-- A bypassing adapter would violate the theorem; the model cannot prove
-- that the actual entry points always use protectedStep.
def bypassWrite (s : WorldConfig) : WorldConfig :=
  { s with core := { s.core with durable := s.core.durable + 1 } }

theorem bypass_is_not_protected :
    bypassWrite foreignStart ≠ protectedRun [.add 1, .commit] foreignStart := by decide

#print axioms protected_run_realizes_relation
#print axioms unauthorized_program_cannot_commit
#print axioms cross_world_write_is_refused
#print axioms bypass_is_not_protected

end AuthorityRelationship
