-- Abstract, sequential Crystal experiment. No Hecks implementation is imported.
namespace CrystalExperiment

inductive Outcome (State Event Code : Type) where
  | success : State → List Event → Outcome State Event Code
  | refusal : State → Code → List Event → Outcome State Event Code
  | failure : State → Code → List Event → Outcome State Event Code
  deriving Repr, DecidableEq

abbrev Step (State Event Code : Type) := State → Outcome State Event Code

def pure {S E C : Type} : Step S E C := fun s => .success s []

def seq {S E C : Type} (f g : Step S E C) : Step S E C := fun s =>
  match f s with
  | .success s' t =>
    match g s' with
    | .success s'' u => .success s'' (t ++ u)
    | .refusal s'' c u => .refusal s'' c (t ++ u)
    | .failure s'' c u => .failure s'' c (t ++ u)
  | .refusal s' c t => .refusal s' c t
  | .failure s' c t => .failure s' c t

def ObsEq {S E C : Type} (f g : Step S E C) : Prop := ∀ s, f s = g s

def Preserves {S E C : Type} (I : S → Prop) (f : Step S E C) : Prop :=
  ∀ s s' t, I s → f s = .success s' t → I s'

def resultingState {S E C : Type} : Outcome S E C → S
  | .success s _ => s
  | .refusal s _ _ => s
  | .failure s _ _ => s

def PreservesEveryOutcome {S E C : Type} (I : S → Prop) (f : Step S E C) : Prop :=
  ∀ s, I s → I (resultingState (f s))

theorem seq_left_identity {S E C : Type} (f : Step S E C) :
    ObsEq (seq pure f) f := by
  intro s
  cases h : f s <;> simp [seq, pure, h]

theorem seq_right_identity {S E C : Type} (f : Step S E C) :
    ObsEq (seq f pure) f := by
  intro s
  cases h : f s <;> simp [seq, pure, h]

theorem seq_associative {S E C : Type} (f g h : Step S E C) :
    ObsEq (seq (seq f g) h) (seq f (seq g h)) := by
  intro s
  cases hf : f s with
  | refusal s' c t => simp [seq, hf]
  | failure s' c t => simp [seq, hf]
  | success s' t =>
    cases hg : g s' with
    | refusal s'' c u => simp [seq, hf, hg]
    | failure s'' c u => simp [seq, hf, hg]
    | success s'' u =>
      cases hh : h s'' <;> simp [seq, hf, hg, hh, List.append_assoc]

theorem preserves_seq {S E C : Type} {I : S → Prop} {f g : Step S E C}
    (hf : Preserves I f) (hg : Preserves I g) : Preserves I (seq f g) := by
  intro s s' t his hs
  cases hfs : f s with
  | refusal x c u => simp [seq, hfs] at hs
  | failure x c u => simp [seq, hfs] at hs
  | success x u =>
    have hix : I x := hf s x u his hfs
    cases hgs : g x with
    | refusal y c v => simp [seq, hfs, hgs] at hs
    | failure y c v => simp [seq, hfs, hgs] at hs
    | success y v =>
      simp only [seq, hfs, hgs] at hs
      have hiy : I y := hg x y v hix hgs
      cases hs
      exact hiy

def chain {S E C : Type} : List (Step S E C) → Step S E C
  | [] => pure
  | f :: fs => seq f (chain fs)

theorem preserves_chain {S E C : Type} {I : S → Prop}
    (fs : List (Step S E C)) (h : ∀ f ∈ fs, Preserves I f) :
    Preserves I (chain fs) := by
  induction fs with
  | nil =>
    intro s s' t his hs
    simp only [chain, pure] at hs
    cases hs
    exact his
  | cons f rest ih =>
    apply preserves_seq
    · exact h f (by simp)
    · exact ih (by
        intro g hg
        exact h g (by simp [hg]))

theorem preserves_every_outcome_seq {S E C : Type} {I : S → Prop}
    {f g : Step S E C}
    (hf : PreservesEveryOutcome I f) (hg : PreservesEveryOutcome I g) :
    PreservesEveryOutcome I (seq f g) := by
  intro s his
  have hfirst := hf s his
  cases hfs : f s with
  | refusal x c t => simpa [seq, hfs, resultingState] using hfirst
  | failure x c t => simpa [seq, hfs, resultingState] using hfirst
  | success x t =>
    have hsecond := hg x (by simpa [hfs, resultingState] using hfirst)
    cases hgs : g x <;> simpa [seq, hfs, hgs, resultingState] using hsecond

theorem preserves_every_outcome_chain {S E C : Type} {I : S → Prop}
    (fs : List (Step S E C))
    (h : ∀ f ∈ fs, PreservesEveryOutcome I f) :
    PreservesEveryOutcome I (chain fs) := by
  induction fs with
  | nil =>
    intro s his
    simpa [chain, pure, resultingState] using his
  | cons f rest ih =>
    apply preserves_every_outcome_seq
    · exact h f (by simp)
    · exact ih (by
        intro g hg
        exact h g (by simp [hg]))

theorem seq_congr {S E C : Type} {f f' g g' : Step S E C}
    (hf : ObsEq f f') (hg : ObsEq g g') :
    ObsEq (seq f g) (seq f' g') := by
  intro s
  simp only [seq, ← hf s]
  cases h : f s with
  | success x t => simp [hg x]
  | refusal x c t => rfl
  | failure x c t => rfl

theorem fusion_in_context {S E C : Type} {pre old fused post : Step S E C}
    (h : ObsEq old fused) :
    ObsEq (seq pre (seq old post)) (seq pre (seq fused post)) := by
  exact seq_congr (fun _ => rfl) (seq_congr h (fun _ => rfl))

-- Counterexamples use exact observations: status, resulting state, code and ordered trace.
def emitThenRefuse : Step Nat String String :=
  fun s => .refusal s "denied" ["charged"]

def silentRefuse : Step Nat String String :=
  fun s => .refusal s "denied" []

theorem unsafe_fusion_loses_effect : ¬ ObsEq emitThenRefuse silentRefuse := by
  intro h
  have hx := h 0
  cases hx

def failed : Step Nat String String := fun s => .failure s "boom" []

theorem unsafe_fusion_changes_status : ¬ ObsEq failed silentRefuse := by
  intro h
  have hx := h 0
  cases hx

def ab : Step Nat String String := fun s => .success s ["a", "b"]
def ba : Step Nat String String := fun s => .success s ["b", "a"]

theorem unsafe_fusion_reorders_effects : ¬ ObsEq ab ba := by
  intro h
  have hx := h 0
  simp [ab, ba] at hx

def failedWithCommit : Step Nat String String :=
  fun s => .failure (s + 1) "boom" ["external-write"]

theorem failure_need_not_be_atomic :
    resultingState (failedWithCommit 0) = 1 ∧
    failedWithCommit 0 = .failure 1 "boom" ["external-write"] := by
  decide

-- A candidate two-constructor syntax. Guard is pure; Change is total and
-- records an ordered effect trace. A program is their sequential composition.
inductive Abort (Code : Type) where
  | refusal : Code → Abort Code
  | failure : Code → Abort Code

inductive Atom (S E C : Type) where
  | guard : (S → Option (Abort C)) → Atom S E C
  | change : (S → S × List E) → Atom S E C

def lower {S E C : Type} : Atom S E C → Step S E C
  | .guard test => fun s =>
      match test s with
      | none => .success s []
      | some (.refusal c) => .refusal s c []
      | some (.failure c) => .failure s c []
  | .change update => fun s =>
      let (s', trace) := update s
      .success s' trace

def runAtoms {S E C : Type} (atoms : List (Atom S E C)) : Step S E C :=
  chain (atoms.map lower)

theorem guard_preserves_every_outcome {S E C : Type} (I : S → Prop)
    (test : S → Option (Abort C)) :
    PreservesEveryOutcome I (lower (.guard test : Atom S E C)) := by
  intro s his
  cases h : test s with
  | none => simpa [lower, h, resultingState] using his
  | some outcome =>
    cases outcome <;> simpa [lower, h, resultingState] using his

theorem change_preserves_every_outcome {S E C : Type} (I : S → Prop)
    (update : S → S × List E)
    (h : ∀ s, I s → I (update s).1) :
    PreservesEveryOutcome I (lower (.change update : Atom S E C)) := by
  intro s his
  simpa [lower, resultingState] using h s his

theorem atoms_preserve_every_outcome {S E C : Type} {I : S → Prop}
    (atoms : List (Atom S E C))
    (h : ∀ a ∈ atoms, PreservesEveryOutcome I (lower a)) :
    PreservesEveryOutcome I (runAtoms atoms) := by
  apply preserves_every_outcome_chain
  intro f hf
  obtain ⟨a, ha, rfl⟩ := List.mem_map.mp hf
  exact h a ha

structure PizzaState where
  actor : String
  requested : String
  records : List String
  deriving Repr, DecidableEq

abbrev PizzaCode := String × String -- stable code and dispatch stage

def pizzaAtoms : List (Atom PizzaState String PizzaCode) :=
  [ .guard (fun s => if s.requested == "" then
      some (.refusal ("type_mismatch", "arguments")) else none),
    .guard (fun s => if s.actor != "Chef" then
      some (.refusal ("unauthorized", "role")) else none),
    .guard (fun s => if s.records.contains s.requested then
      some (.refusal ("already_exists", "state")) else none),
    .change (fun s => ({s with records := s.records ++ [s.requested]}, ["PizzaCreated"])) ]

theorem pizza_valid :
    runAtoms pizzaAtoms ⟨"Chef", "First", []⟩ =
      .success ⟨"Chef", "First", ["First"]⟩ ["PizzaCreated"] := by
  decide

theorem pizza_blank_name :
    runAtoms pizzaAtoms ⟨"Chef", "", ["First"]⟩ =
      .refusal ⟨"Chef", "", ["First"]⟩ ("type_mismatch", "arguments") [] := by
  decide

theorem pizza_duplicate :
    runAtoms pizzaAtoms ⟨"Chef", "First", ["First"]⟩ =
      .refusal ⟨"Chef", "First", ["First"]⟩ ("already_exists", "state") [] := by
  decide

theorem pizza_wrong_role :
    runAtoms pizzaAtoms ⟨"Customer", "Second", ["First"]⟩ =
      .refusal ⟨"Customer", "Second", ["First"]⟩ ("unauthorized", "role") [] := by
  decide

theorem pizza_valid_after_refusals :
    runAtoms pizzaAtoms ⟨"Chef", "Second", ["First"]⟩ =
      .success ⟨"Chef", "Second", ["First", "Second"]⟩ ["PizzaCreated"] := by
  decide

structure PassageState where
  stage : String
  pushed : Option String
  deriving Repr, DecidableEq

def passageLand : List (Atom PassageState String PizzaCode) :=
  [ .guard (fun s => if s.stage == "planned" || s.stage == "dispatched" then none
      else some (.refusal ("lifecycle_refused", "state"))),
    .change (fun s => ({s with stage := "landed"}, ["PassageLanded"])) ]

def passagePush : List (Atom PassageState String PizzaCode) :=
  [ .guard (fun s => if s.stage == "landed" then none
      else some (.refusal ("lifecycle_refused", "state"))),
    .change (fun s => ({s with stage := "pushed", pushed := some "abc"}, ["PassagePushed"])) ]

theorem pipeline_push_before_land :
    runAtoms passagePush ⟨"planned", none⟩ =
      .refusal ⟨"planned", none⟩ ("lifecycle_refused", "state") [] := by
  decide

theorem pipeline_land_then_push :
    runAtoms passageLand ⟨"planned", none⟩ =
      .success ⟨"landed", none⟩ ["PassageLanded"] ∧
    runAtoms passagePush ⟨"landed", none⟩ =
      .success ⟨"pushed", some "abc"⟩ ["PassagePushed"] := by
  decide

-- A primary command can succeed even when a later reaction is refused.
-- The observation alphabet must include that reaction and its outbox status.
inductive DeliveryObservation where
  | orderPlaced
  | reactionRefused
  | outboxRefused
  | auditRecorded
  deriving Repr, DecidableEq

def withRefusedReaction : Step Nat DeliveryObservation String :=
  fun s => .success (s + 1)
    [.orderPlaced, .reactionRefused, .outboxRefused]

def droppedReaction : Step Nat DeliveryObservation String :=
  fun s => .success (s + 1) [.orderPlaced]

theorem dropping_reaction_is_observable :
    ¬ ObsEq withRefusedReaction droppedReaction := by
  intro h
  have hx := h 0
  simp [withRefusedReaction, droppedReaction] at hx

def primaryOrder : Step Nat DeliveryObservation String :=
  fun s => .success (s + 1) [.orderPlaced]

def refusedConsumer : Step Nat DeliveryObservation String :=
  fun s => .refusal s "deliberate refusal" [.reactionRefused, .outboxRefused]

theorem linear_reaction_composition_misclassifies_command :
    ¬ ObsEq (seq primaryOrder refusedConsumer) withRefusedReaction := by
  intro h
  have hx := h 0
  simp [seq, primaryOrder, refusedConsumer, withRefusedReaction] at hx

theorem success_then_refusal_is_refusal {S E C : Type}
    (f g : Step S E C) (s s₁ s₂ : S) (firstTrace secondTrace : List E)
    (code : C)
    (hf : f s = .success s₁ firstTrace)
    (hg : g s₁ = .refusal s₂ code secondTrace) :
    seq f g s = .refusal s₂ code (firstTrace ++ secondTrace) := by
  simp [seq, hf, hg]

-- Commit and reaction delivery are separate phases. This is a candidate
-- observation model for one consumer, not an implementation refinement proof.
inductive DeliveryStatus where
  | pending | claimed | delivered | refused | failed
  deriving Repr, DecidableEq

structure DeliveryResult (S E C : Type) where
  world : S
  status : DeliveryStatus
  reason : Option C
  trace : List E

structure Execution (S E C : Type) where
  primary : Outcome S E C
  world : S
  row : Option DeliveryStatus
  reason : Option C
  trace : List E

def commit {S E C : Type} (hasConsumer : Bool) (primary : Step S E C)
    (initial : S) : Execution S E C :=
  match primary initial with
  | .success s events =>
      { primary := .success s events, world := s,
        row := if hasConsumer then some .pending else none,
        reason := none, trace := events }
  | .refusal s code events =>
      { primary := .refusal s code events, world := s,
        row := none, reason := none, trace := events }
  | .failure s code events =>
      { primary := .failure s code events, world := s,
        row := none, reason := none, trace := events }

def deliverPending {S E C : Type} (consumer : S → DeliveryResult S E C)
    (execution : Execution S E C) : Execution S E C :=
  match execution.row with
  | some .pending =>
      let result := consumer execution.world
      ⟨execution.primary, result.world, some result.status,
        result.reason, execution.trace ++ result.trace⟩
  | _ => execution

theorem delivery_preserves_primary {S E C : Type}
    (consumer : S → DeliveryResult S E C) (execution : Execution S E C) :
    (deliverPending consumer execution).primary = execution.primary := by
  cases h : execution.row with
  | none => simp [deliverPending, h]
  | some status => cases status <;> simp [deliverPending, h]

theorem commit_preserves_invariant {S E C : Type} {I : S → Prop}
    (primary : Step S E C) (hasConsumer : Bool)
    (hp : PreservesEveryOutcome I primary) (initial : S) (hi : I initial) :
    I (commit hasConsumer primary initial).world := by
  have h := hp initial hi
  cases hc : primary initial <;> simpa [commit, hc, resultingState] using h

theorem delivery_preserves_invariant {S E C : Type} {I : S → Prop}
    (consumer : S → DeliveryResult S E C)
    (hd : ∀ s, I s → I (consumer s).world)
    (execution : Execution S E C) (hi : I execution.world) :
    I (deliverPending consumer execution).world := by
  cases h : execution.row with
  | none => simpa [deliverPending, h] using hi
  | some status =>
      cases status <;> simp [deliverPending, h]
      · exact hd execution.world hi
      all_goals exact hi

theorem commit_then_delivery_preserves_invariant {S E C : Type} {I : S → Prop}
    (primary : Step S E C) (consumer : S → DeliveryResult S E C)
    (hp : PreservesEveryOutcome I primary)
    (hd : ∀ s, I s → I (consumer s).world)
    (initial : S) (hi : I initial) :
    I (deliverPending consumer (commit true primary initial)).world := by
  exact delivery_preserves_invariant consumer hd _
    (commit_preserves_invariant primary true hp initial hi)

theorem delivery_preserves_trace_prefix {S E C : Type}
    (consumer : S → DeliveryResult S E C) (execution : Execution S E C) :
    ∃ suffix, (deliverPending consumer execution).trace = execution.trace ++ suffix := by
  cases h : execution.row with
  | none => exact ⟨[], by simp [deliverPending, h]⟩
  | some status =>
      cases status <;> simp [deliverPending, h]

def refuseReaction : Nat → DeliveryResult Nat DeliveryObservation String :=
  fun s => { world := s, status := .refused, reason := some "deliberate refusal",
             trace := [.reactionRefused, .outboxRefused] }

def succeedReaction : Nat → DeliveryResult Nat DeliveryObservation String :=
  fun s => { world := s + 10, status := .delivered, reason := none, trace := [] }

def failReaction : Nat → DeliveryResult Nat DeliveryObservation String :=
  fun s => { world := s, status := .failed, reason := some "consumer exploded", trace := [] }

theorem committed_primary_with_refused_reaction :
    (deliverPending refuseReaction (commit true primaryOrder 0)).primary =
      .success 1 [.orderPlaced] ∧
    (deliverPending refuseReaction (commit true primaryOrder 0)).row =
      some .refused ∧
    (deliverPending refuseReaction (commit true primaryOrder 0)).trace =
      [.orderPlaced, .reactionRefused, .outboxRefused] := by
  decide

theorem pending_redrive_delivers :
    (commit true primaryOrder 0).row = some .pending ∧
    (deliverPending succeedReaction (commit true primaryOrder 0)).row =
      some .delivered ∧
    (deliverPending succeedReaction (commit true primaryOrder 0)).primary =
      .success 1 [.orderPlaced] := by
  decide

theorem committed_primary_with_failed_reaction :
    (deliverPending failReaction (commit true primaryOrder 0)).primary =
      .success 1 [.orderPlaced] ∧
    (deliverPending failReaction (commit true primaryOrder 0)).row =
      some .failed := by
  decide

theorem claimed_is_not_replayed_without_evidence {S E C : Type}
    (consumer : S → DeliveryResult S E C) (execution : Execution S E C)
    (h : execution.row = some .claimed) :
    deliverPending consumer execution = execution := by
  simp [deliverPending, h]

theorem settled_row_is_not_replayed {S E C : Type}
    (consumer : S → DeliveryResult S E C) (execution : Execution S E C)
    (h : execution.row = some .delivered ∨
         execution.row = some .refused ∨ execution.row = some .failed) :
    deliverPending consumer execution = execution := by
  rcases h with h | h | h <;> simp [deliverPending, h]

theorem primary_refusal_has_no_delivery_row {S E C : Type}
    (hasConsumer : Bool) (primary : Step S E C) (initial s : S)
    (code : C) (events : List E)
    (h : primary initial = .refusal s code events) :
    (commit hasConsumer primary initial).row = none := by
  simp [commit, h]

-- Multiple consumers continue independently in declaration order. Their
-- ordered delivery records are part of the observation, even if final world
-- state and primary event names happen to coincide.
structure FanoutExecution (S E C : Type) where
  primary : Outcome S E C
  world : S
  deliveries : List (String × DeliveryStatus)
  trace : List E

def deliverOne {S E C : Type} (name : String)
    (consumer : S → DeliveryResult S E C)
    (execution : FanoutExecution S E C) : FanoutExecution S E C :=
  let result := consumer execution.world
  ⟨execution.primary, result.world,
    execution.deliveries ++ [(name, result.status)],
    execution.trace ++ result.trace⟩

def deliverAll {S E C : Type} :
    List (String × (S → DeliveryResult S E C)) →
    FanoutExecution S E C → FanoutExecution S E C
  | [], execution => execution
  | named :: rest, execution =>
      deliverAll rest (deliverOne named.1 named.2 execution)

theorem fanout_preserves_primary {S E C : Type}
    (consumers : List (String × (S → DeliveryResult S E C)))
    (execution : FanoutExecution S E C) :
    (deliverAll consumers execution).primary = execution.primary := by
  induction consumers generalizing execution with
  | nil => rfl
  | cons named rest ih =>
      simpa [deliverAll, deliverOne] using
        ih (deliverOne named.1 named.2 execution)

theorem fanout_preserves_invariant {S E C : Type} {I : S → Prop}
    (consumers : List (String × (S → DeliveryResult S E C)))
    (h : ∀ named ∈ consumers, ∀ s, I s → I (named.2 s).world)
    (execution : FanoutExecution S E C) (hi : I execution.world) :
    I (deliverAll consumers execution).world := by
  induction consumers generalizing execution with
  | nil => simpa [deliverAll] using hi
  | cons named rest ih =>
      apply ih
      · intro other ho
        exact h other (by simp [ho])
      · simpa [deliverOne] using h named (by simp) execution.world hi

def auditReaction : Nat → DeliveryResult Nat DeliveryObservation String :=
  fun s => { world := s + 10, status := .delivered, reason := none,
             trace := [.auditRecorded] }

def fanoutBase : FanoutExecution Nat DeliveryObservation String :=
  ⟨.success 1 [.orderPlaced], 1, [], [.orderPlaced]⟩

def refusalFirst : FanoutExecution Nat DeliveryObservation String :=
  deliverAll [("RefuseLedger", refuseReaction), ("RecordAudit", auditReaction)] fanoutBase

def successFirst : FanoutExecution Nat DeliveryObservation String :=
  deliverAll [("RecordAudit", auditReaction), ("RefuseLedger", refuseReaction)] fanoutBase

theorem fanout_order_is_observable :
    refusalFirst.deliveries ≠ successFirst.deliveries ∧
    refusalFirst.world = successFirst.world ∧
    refusalFirst.primary = successFirst.primary := by
  decide

-- A deliberately narrow projection of Hecks' blocker rule: a refused
-- reaction is excused by a delivered different command on the same
-- aggregate answering the same event instance. Other Hecks exceptions
-- (already-exists, answered asks, held stores) are not modeled here.
structure ReactionObservation where
  eventId : String
  aggregate : String
  command : String
  status : DeliveryStatus
  deriving Repr, DecidableEq

def alternativeFor (refused other : ReactionObservation) : Bool :=
  other.status == .delivered &&
  other.eventId == refused.eventId &&
  other.aggregate == refused.aggregate &&
  other.command != refused.command

def isBlocking (row : ReactionObservation)
    (all : List ReactionObservation) : Bool :=
  row.status == .refused && !(all.any (alternativeFor row))

def waitExit (wait : Bool) (all : List ReactionObservation) : Nat :=
  if wait && all.any (fun row => isBlocking row all || row.status == .failed)
  then 1 else 0

def refusedLedger : ReactionObservation :=
  ⟨"event-1", "Ledger", "Record", .refused⟩

def deliveredAudit : ReactionObservation :=
  ⟨"event-1", "Audit", "Record", .delivered⟩

def deliveredLedgerAlternative : ReactionObservation :=
  ⟨"event-1", "Ledger", "Accept", .delivered⟩

theorem different_aggregate_remains_blocking :
    isBlocking refusedLedger [refusedLedger, deliveredAudit] = true ∧
    waitExit false [refusedLedger, deliveredAudit] = 0 ∧
    waitExit true [refusedLedger, deliveredAudit] = 1 := by
  decide

theorem same_aggregate_alternative_excuses_refusal :
    isBlocking refusedLedger [refusedLedger, deliveredLedgerAlternative] = false ∧
    waitExit true [refusedLedger, deliveredLedgerAlternative] = 0 := by
  decide

theorem different_event_does_not_excuse_refusal :
    isBlocking refusedLedger
      [refusedLedger, {deliveredLedgerAlternative with eventId := "event-2"}] = true := by
  decide

theorem blocker_cannot_be_decided_from_row_alone :
    isBlocking refusedLedger [refusedLedger, deliveredAudit] ≠
    isBlocking refusedLedger [refusedLedger, deliveredLedgerAlternative] := by
  decide

-- A wider abstraction of ReactionOutcome.blocking. `alreadyThere` is an
-- explicit certificate here; Hecks currently derives it by matching the
-- refusal wording against a template and the command/aggregate name.
structure ReactionEvidence where
  eventId : Option String
  eventName : String
  aggregate : String
  command : String
  status : DeliveryStatus
  refusesEvent : Option String
  alreadyThere : Bool
  held : Bool
  defect : Bool
  deriving Repr, DecidableEq

def sameEvent (a b : ReactionEvidence) : Bool :=
  a.eventName == b.eventName &&
  match a.eventId, b.eventId with
  | some x, some y => x == y
  | _, _ => true

def fullAlternative (a b : ReactionEvidence) : Bool :=
  b.status == .delivered && sameEvent a b &&
  a.aggregate == b.aggregate && a.command != b.command

def answeredAsk (a : ReactionEvidence) (rows : List ReactionEvidence) : Bool :=
  match a.refusesEvent with
  | none => false
  | some eventName => rows.any (fun b => b.status == .delivered && b.eventName == eventName)

def fullBlocking (a : ReactionEvidence) (rows : List ReactionEvidence) : Bool :=
  a.status == .refused && !a.defect && !a.held && !a.alreadyThere &&
  !answeredAsk a rows && !(rows.any (fullAlternative a))

def fullWaitExit (wait : Bool) (rows : List ReactionEvidence) : Nat :=
  if wait && rows.any (fun r => fullBlocking r rows || r.defect)
  then 1 else 0

def evidenceRefusal : ReactionEvidence :=
  ⟨some "e1", "OrderPlaced", "Ledger", "Record", .refused,
    none, false, false, false⟩

def evidenceAlternative : ReactionEvidence :=
  ⟨some "e1", "OrderPlaced", "Ledger", "Accept", .delivered,
    none, false, false, false⟩

def evidenceAnswer : ReactionEvidence :=
  ⟨some "e4", "OutsideRefused", "Audit", "Note", .delivered,
    none, false, false, false⟩

theorem full_blocker_examples :
    fullBlocking evidenceRefusal [evidenceRefusal] = true ∧
    fullBlocking evidenceRefusal [evidenceRefusal, evidenceAlternative] = false ∧
    fullBlocking {evidenceRefusal with alreadyThere := true}
      [{evidenceRefusal with alreadyThere := true}] = false ∧
    fullBlocking {evidenceRefusal with refusesEvent := some "OutsideRefused"}
      [{evidenceRefusal with refusesEvent := some "OutsideRefused"}, evidenceAnswer] = false ∧
    fullBlocking {evidenceRefusal with held := true}
      [{evidenceRefusal with held := true}] = false ∧
    fullWaitExit true [{evidenceRefusal with defect := true}] = 1 := by
  decide

theorem missing_event_identity_can_change_classification :
    fullBlocking evidenceRefusal
      [evidenceRefusal, {evidenceAlternative with eventId := some "e2"}] = true ∧
    fullBlocking evidenceRefusal
      [evidenceRefusal, {evidenceAlternative with eventId := none}] = false := by
  decide

-- Queries expose a return value without changing state or emitting events.
-- The command-only Step observation has no answer channel, so mapping both
-- queries to `pure` would incorrectly identify them.
def availablePrices (prices : List Nat) : List Nat := prices
def cheaperThan1000 (prices : List Nat) : List Nat :=
  prices.filter (fun price => price < 1000)

def eraseAnswer (_query : List Nat → List Nat) : Step (List Nat) String String :=
  pure

theorem state_and_effect_only_observation_loses_query_answer :
    ObsEq (eraseAnswer availablePrices) (eraseAnswer cheaperThan1000) ∧
    availablePrices [1200] ≠ cheaperThan1000 [1200] := by
  constructor
  · intro s
    rfl
  · decide

#print axioms seq_associative
#print axioms preserves_chain
#print axioms preserves_every_outcome_chain
#print axioms fusion_in_context
#print axioms unsafe_fusion_loses_effect
#print axioms atoms_preserve_every_outcome
#print axioms pizza_valid
#print axioms pipeline_land_then_push
#print axioms linear_reaction_composition_misclassifies_command
#print axioms success_then_refusal_is_refusal
#print axioms delivery_preserves_primary
#print axioms commit_then_delivery_preserves_invariant
#print axioms delivery_preserves_trace_prefix
#print axioms pending_redrive_delivers
#print axioms committed_primary_with_failed_reaction
#print axioms claimed_is_not_replayed_without_evidence
#print axioms primary_refusal_has_no_delivery_row
#print axioms fanout_preserves_primary
#print axioms fanout_preserves_invariant
#print axioms fanout_order_is_observable
#print axioms different_aggregate_remains_blocking
#print axioms same_aggregate_alternative_excuses_refusal
#print axioms different_event_does_not_excuse_refusal
#print axioms blocker_cannot_be_decided_from_row_alone
#print axioms full_blocker_examples
#print axioms missing_event_identity_can_change_classification
#print axioms state_and_effect_only_observation_loses_query_answer

end CrystalExperiment
