import RelationshipExperiment

namespace PreStateEffects

open RelationshipExperiment

structure Gauge where
  current : Nat
  previous : Nat
  deriving DecidableEq, Repr

inductive Source where
  | literal : Nat → Source
  | oldCurrent : Source
  deriving DecidableEq, Repr

inductive Assignment where
  | current : Source → Assignment
  | previous : Source → Assignment
  deriving DecidableEq, Repr

def readSource (pre : Gauge) : Source → Nat
  | .literal n => n
  | .oldCurrent => pre.current

def apply (pre candidate : Gauge) : Assignment → Gauge
  | .current source => { candidate with current := readSource pre source }
  | .previous source => { candidate with previous := readSource pre source }

def run (pre : Gauge) : List Assignment → Gauge → Gauge
  | [], candidate => candidate
  | e :: rest, candidate => run pre rest (apply pre candidate e)

def assignmentRel (pre : Gauge) (e : Assignment) : Rel Gauge Gauge :=
  graph (fun candidate => apply pre candidate e)

def programRel (pre : Gauge) : List Assignment → Rel Gauge Gauge
  | [] => identity
  | e :: rest => thenRel (assignmentRel pre e) (programRel pre rest)

theorem run_realizes_relation (pre candidate result : Gauge)
    (effects : List Assignment) :
    programRel pre effects candidate result ↔
      run pre effects candidate = result := by
  induction effects generalizing candidate with
  | nil => simp [programRel, run, identity]
  | cons e rest ih =>
    simp only [programRel, thenRel, assignmentRel, graph, run]
    constructor
    · rintro ⟨middle, hm, hr⟩
      rw [hm]
      exact (ih middle).mp hr
    · intro hr
      exact ⟨apply pre candidate e, rfl, (ih (apply pre candidate e)).mpr hr⟩

def meterEffects (newReading : Nat) : List Assignment :=
  [.current (.literal newReading), .previous .oldCurrent]

theorem meter_reads_pre_state :
    run ⟨5, 0⟩ (meterEffects 9) ⟨5, 0⟩ = ⟨9, 5⟩ := by decide

-- The unsafe alternative changes the source state after each assignment.
def naiveRun : List Assignment → Gauge → Gauge
  | [], candidate => candidate
  | e :: rest, candidate => naiveRun rest (apply candidate candidate e)

theorem sequential_candidate_read_is_wrong :
    naiveRun (meterEffects 9) ⟨5, 0⟩ = ⟨9, 9⟩ ∧
    naiveRun (meterEffects 9) ⟨5, 0⟩ ≠
      run ⟨5, 0⟩ (meterEffects 9) ⟨5, 0⟩ := by decide

#print axioms run_realizes_relation
#print axioms meter_reads_pre_state
#print axioms sequential_candidate_read_is_wrong

end PreStateEffects
