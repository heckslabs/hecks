require "spec_helper"
require "hecks/fuzzing"

# THE QA LEDGER, EXERCISED THE WAY IT WILL ACTUALLY BE USED.
#
# Booted against Memory rather than the chapter's own Postgres binding — a
# spec that wrote to the real ledger would leave it different after every run,
# which is the one thing a durable store must not do to its own test. Only the
# WIRING is swapped; the chapter under test is the file the tool boots.
#
# Written through the facade: a creating verb is a module method returning the
# record in hand, every other verb is a method on that record. Queries and
# entity commands have no door and go through the runtime — the two helpers at
# the top are the only places this file reaches past it.
RSpec.describe "QualityControl" do
  QC_ROOT = File.join(InMemoryDomain::ROOT, "qa/bluebook").freeze

  class StubTracker
    # THE ADAPTER RETURNS WHAT THE ANSWERING COMMAND TAKES. The answer is
    # spread into the event payload, and a policy re-enters with that
    # payload verbatim — so these keys are `Ticket.Filed`'s arguments, in the
    # shape the runtime coerces.
    def file(**) = { "number" => { "value" => 43 }, "url" => { "value" => "https://example.com/issues/43" } }
  end

  class RefusingTracker
    def file(**) = raise IOError, "the token expired"
  end

  # CI, BOTH WAYS. A green suite ANSWERS with the summary `Clearance.Passed`
  # takes; a red one REFUSES, and the runtime hands that refusal to
  # `Clearance.Failed` under the key `refusal` — which is why that command
  # declares `refusal` and not `summary`. Nothing but running it says whether
  # those two words line up.
  class GreenCi
    def run(**) = { "summary" => { "value" => "1335 examples, 0 failures" } }
  end

  class RedCi
    def run(**) = raise "suite red against abc1234: 1335 examples, 2 failures"
  end

  # A FIXED CLOCK, WHICH IS THE WHOLE REASON THE CLOCK IS A PORT. A staleness
  # rule read against the real clock is untestable — the spec would either
  # sleep for fifteen minutes or never exercise the rule at all. Bound to this,
  # it is three lines.
  module FixedClock
    module_function

    def now = 1_000
  end

  def boot_quality_control(tracker = StubTracker, ci_adapter: GreenCi)
    registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(File.join(QC_ROOT, "quality_control.bluebook"))

      stub_const("Hecks::Adapters::QcTracker", tracker)
      Hecks.adapter("QcTracker") { port "IssueTracker" }

      stub_const("Hecks::Adapters::QcCi", ci_adapter)
      Hecks.adapter("QcCi") { port "CI" }

      stub_const("Hecks::Adapters::QcClock", FixedClock)
      Hecks.adapter("QcClock") { port "clock" }

      Hecks.hecksagon "QualityControl" do
        uses_framework "Governance"

        [QualityControl::Target, QualityControl::Sweep, QualityControl::Bug, QualityControl::Angle,
         QualityControl::Ticket, QualityControl::Patch, QualityControl::Improvement,
         QualityControl::Clearance].each do |aggregate|
          aggregate.persisted_by("Memory")
        end

        QualityControl::Ticket.port "IssueTracker" do
          asks "File", to: Ticket do
            answers "IssueFiled"
            refuses "IssueFilingRefused"
          end

          tells "Closed", to: Ticket do
            emits "IssueClosedUpstream"
          end
        end

        QualityControl::Clearance.port "CI" do
          asks "Run", to: Clearance do
            answers "SuitePassed"
            refuses "SuiteFailed"
          end
        end
      end
    end

    registry.verify!
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end

  let(:runtime) { boot_quality_control }

  def rows(query, **args) = runtime.query("QualityControl::#{query}", **args)
  def references(query, **args) = rows(query, **args).map { |row| row[:reference][:value] }
  def check(sweep, verb, **args) = runtime.dispatch("QualityControl::Sweep.Check.#{verb}", id: sweep.id, **args)

  def a_target(reference = "banking", path = "examples/banking")
    runtime
    QualityControl::Target.identify!(reference: { value: reference }, path: { value: path })
  end

  def a_sweep(target = nil, reference: "SW-1", engineer: "Claude QA")
    target ||= a_target
    QualityControl::Sweep.open!(target: target.id, reference: { value: reference },
                                engineer: { value: engineer })
  end

  def a_check(sweep, subject: "Banking::Account.Freeze", expectation: "a frozen account refuses a second freeze")
    sweep.check!(subject: { value: subject }, expectation: { value: expectation })
  end

  def a_bug(sweep, reference: "BUG#1", sequence: 1)
    QualityControl::Bug.log!(
      sweep: sweep.id,
      reference: { value: reference }, sequence: { value: sequence },
      title: { value: "as: is accepted and does not alias" },
      demonstration: { value: 'rspec spec/qa_bugs_spec.rb -e "aliasing"' },
      symptom: { value: "the alias is ignored and the original name still answers" },
      expectation: { value: "the aliased name answers and the original does not" },
      submitter: { value: "Claude QA" }
    )
  end

  # ── the clock, and the window it is measured against ─────────────────

  describe "the clock" do
    def cli(*argv) = Hecks::Facade::CliRunner.call(runtime: runtime, argv: argv, program: "bin/qc")

    def target = @target ||= a_target("banking")

    # THE FRICTION THIS REMOVED. Every claim used to want
    # `now.value=$(date +%s) window.value=900` typed in front of it, which is a
    # shell incantation an agent gets wrong by pasting a stale number.
    it "fills now from the clock when the caller leaves it out" do
      target
      text, code = cli("target.claim", "id=banking", "held_by.value=agent-one")

      expect(code).to eq(0)
      expect(JSON.parse(text).dig("state", "claimed_at", "value")).to eq(1_000)
    end

    # SO A SPEC OR A CALLER REPRODUCING A MOMENT IS BELIEVED. The door supplies
    # only what was omitted.
    it "believes an explicit time over the clock" do
      target
      text, = cli("target.claim", "id=banking", "held_by.value=agent-one", "now.value=55")

      expect(JSON.parse(text).dig("state", "claimed_at", "value")).to eq(55)
    end

    # THE HOLE THIS CLOSED. `window` was an argument, so any agent could take a
    # live claim from any other by asking with a window of one second — the
    # guard read a number the CALLER supplied and dutifully agreed.
    it "does not let a claimer name the window it is judged against" do
      target
      _, code = cli("target.claim", "id=banking", "held_by.value=agent-one")
      expect(code).to eq(0)

      text, refused = cli("target.claim", "id=banking", "held_by.value=agent-two", "window.value=1")

      expect(refused).to eq(1)
      expect(text).to include("no argument")
    end

    it "still goes stale on the practice own window, not the claimer own" do
      target.claim!(held_by: { value: "agent-one" }, now: { value: 1_000 })

      # 900 is the record default, so this is the first instant it is takeable.
      target.claim!(held_by: { value: "agent-two" }, now: { value: 1_900 })

      expect(target.held_by.to_h).to eq(value: "agent-two")
    end
  end

  # ── the composed reads ───────────────────────────────────────────────

  describe "the tally" do
    def report(name) = runtime.query("QualityControl.#{name}").first

    def a_logged_bug(reference, submitter: "agent-one")
      holder = sweep
      QualityControl::Bug.log!(sweep: holder.id, reference: { value: reference }, sequence: { value: 1 },
                               title: { value: "t" }, demonstration: { value: "spec/x_spec.rb" },
                               symptom: { value: "s" }, expectation: { value: "e" },
                               submitter: { value: submitter })
    end

    let(:sweep) { a_sweep }

    # THE ONE THING A QUERY CANNOT DO IS COUNT. `Bug.Open` answers rows and
    # leaves the arithmetic to whoever is reading; a tally IS the arithmetic,
    # and it is grouped by the LIFECYCLE state — which no `attribute` declares
    # and `group_by` used to refuse.
    it "counts every bug under what became of it" do
      one = a_logged_bug("BUG#1")
      a_logged_bug("BUG#2")
      one.investigate!(site: { value: "lib/x.rb" }, cause: { value: "c" })

      by_status = report("BugsByStatus")[:bugs]

      expect(by_status["logged"].keys).to eq(["BUG#2"])
      expect(by_status["investigating"].keys).to eq(["BUG#1"])
    end

    it "sorts by who reported it, so a quiet agent is visible" do
      a_logged_bug("BUG#1", submitter: "agent-one")
      a_logged_bug("BUG#2", submitter: "agent-two")
      a_logged_bug("BUG#3", submitter: "agent-one")

      by_submitter = report("BugsBySubmitter")[:bugs]

      expect(by_submitter["agent-one"].keys).to contain_exactly("BUG#1", "BUG#3")
      expect(by_submitter["agent-two"].keys).to eq(["BUG#2"])
    end

    # REACHABLE FROM THE ONLY DOOR THERE IS. The dispatcher has always
    # answered a report; the projected CLI never listed one, so a caller with
    # no Ruby could not ask for the one reading that counts.
    it "is a question the command line offers" do
      a_logged_bug("BUG#1")

      text, code = Hecks::Facade::CliRunner.call(
        runtime: runtime, argv: %w[ask bugs_by_status], program: "qa/quality_control"
      )

      expect(code).to eq(0)
      expect(JSON.parse(text).first["bugs"]["logged"].keys).to eq(["BUG#1"])
    end
  end

  # ── the rotation ─────────────────────────────────────────────────────

  describe "the rotation" do
    it "offers the least recently swept first" do
      swept = a_target("banking")
      swept.claim!(held_by: { value: "agent-one" }, now: { value: 1_000 })
      swept.release!(now: { value: 1_000 }, yield_score: { value: 0 }, next_streak: { value: 1 }, capabilities: { value: "" })
      a_target("pizzas", "examples/pizzas")

      # "never" sorts before any sweep reference, which is the ordering the
      # rotation wants: nobody has ever looked at pizzas.
      expect(references("Target.Rotation").first).to eq("pizzas")
    end

    it "shows what nobody has ever swept, which no count of checks could" do
      a_target("compliance", "examples/compliance")

      expect(references("Target.Untouched")).to eq(["compliance"])
      expect(rows("Sweep.Check.ForSubject", subject: { value: "compliance" })).to be_empty
    end

    # TWO AGENTS, ONE CHAPTER. The lifecycle is the lock: one transition
    # wins, the other is refused and takes the next chapter.
    it "gives a chapter to one agent and refuses the other" do
      target = a_target
      target.claim!(held_by: { value: "agent-one" }, now: { value: 1_000 })

      expect(target.held_by.to_h).to eq(value: "agent-one")

      expect do
        target.claim!(held_by: { value: "agent-two" }, now: { value: 1_060 })
      end.to raise_error(Hecks::Runtime::GivenNotMet, /not taken from the agent holding it/)
    end

    # AND THE FAILURE MODE EVERY LOCK HAS. An agent that dies holds the
    # chapter forever unless the claim can go stale.
    it "lets the next agent take a claim whose holder has gone quiet" do
      target = a_target
      target.claim!(held_by: { value: "agent-one" }, now: { value: 1_000 })

      target.claim!(held_by: { value: "agent-two" }, now: { value: 1_000 + 900 })

      expect(target.held_by.to_h).to eq(value: "agent-two")
    end

    it "puts a released chapter back at the end of the rotation" do
      target = a_target
      target.claim!(held_by: { value: "agent-one" }, now: { value: 1_000 })
      target.release!(now: { value: 1_000 }, yield_score: { value: 0 }, next_streak: { value: 1 }, capabilities: { value: "" })

      expect(target.status).to eq("waiting")
      expect(rows("Target.Untouched")).to be_empty
    end

    # ── yield-weighted priority ──────────────────────────────────────

    it "starts every target's yield score at zero" do
      target = a_target

      expect(target.yield_score.to_h).to eq(value: 0)
    end

    it "stores whatever yield score a release is given" do
      target = a_target
      target.claim!(held_by: { value: "agent-one" }, now: { value: 1_000 })
      released = target.release!(now: { value: 1_000 }, yield_score: { value: 7 }, next_streak: { value: 1 },
                                 capabilities: { value: "" })

      expect(released.yield_score.to_h).to eq(value: 7)
    end

    it "refuses to leave the yield score unsaid" do
      target = a_target
      target.claim!(held_by: { value: "agent-one" }, now: { value: 1_000 })

      expect { runtime.dispatch("QualityControl::Target.Release", id: target.id, now: { value: 1_000 }) }
        .to raise_error(Hecks::Runtime::AbsentArgument)
    end

    # THE FORMULA ITSELF, AGAINST REAL DISPATCH — `Hecks::Fuzzing::
    # RotationPriority.pick` is exercised directly (no ledger needed) in
    # spec/rotation_priority_spec.rb; this proves the SAME rows really
    # come back out of a booted `Target.Rotation` carrying a
    # `yield_score` a caller can feed it.
    it "picks the higher-yield target over the merely-older one, below the floor" do
      exhausted = a_target("pizzas", "examples/pizzas")
      exhausted.claim!(held_by: { value: "agent-one" }, now: { value: 0 })
      exhausted.release!(now: { value: 0 }, yield_score: { value: 0 }, next_streak: { value: 1 }, capabilities: { value: "" })

      roster = a_target("roster", "examples/roster")
      roster.claim!(held_by: { value: "agent-one" }, now: { value: 500 })
      roster.release!(now: { value: 500 }, yield_score: { value: 6 }, next_streak: { value: 1 }, capabilities: { value: "" })

      picked = Hecks::Fuzzing::RotationPriority.pick(
        rows("Target.Rotation"), now: 1_000, weight_seconds: 100, floor_seconds: 100_000
      )

      expect(picked[:reference][:value]).to eq("roster")
    end

    it "still picks the exhausted target once it crosses the floor, regardless of yield" do
      exhausted = a_target("pizzas", "examples/pizzas")
      exhausted.claim!(held_by: { value: "agent-one" }, now: { value: 0 })
      exhausted.release!(now: { value: 0 }, yield_score: { value: 0 }, next_streak: { value: 1 }, capabilities: { value: "" })

      roster = a_target("roster", "examples/roster")
      roster.claim!(held_by: { value: "agent-one" }, now: { value: 500 })
      roster.release!(now: { value: 500 }, yield_score: { value: 6 }, next_streak: { value: 1 }, capabilities: { value: "" })

      picked = Hecks::Fuzzing::RotationPriority.pick(
        rows("Target.Rotation"), now: 1_000, weight_seconds: 100, floor_seconds: 900
      )

      expect(picked[:reference][:value]).to eq("pizzas")
    end
  end

  # ── the clean streak ─────────────────────────────────────────────────
  #
  # `bin/qa_sweep` is the real caller and does this arithmetic for real
  # (read `clean_streak`, run a sweep sized by it, then compute
  # `next_streak`) — these examples do it by hand, the same way
  # `spec/quality_control_spec.rb`'s own header explains this whole file
  # is written "through the facade... the two helpers at the top are the
  # only places this file reaches past it": `Target::Release` trusts
  # whatever `next_streak` it is given, exactly as it already trusts
  # `now`, so what is actually under test here is that trust threading
  # correctly — the FIELD landing where it should, and `Check::Surprised`'s
  # own sticky bit surviving a `Remake` — not a reimplementation of
  # `bin/qa_sweep`'s own widening formula (that lives in, and is tested
  # against, `bin/qa_sweep` itself).
  describe "the clean streak" do
    it "starts at zero for a freshly identified target" do
      target = a_target

      expect(target.clean_streak.to_h).to eq(value: 0)
    end

    it "climbs by one on every clean release in a row" do
      target = a_target
      target.claim!(held_by: { value: "agent-one" }, now: { value: 1_000 })
      target = target.release!(now: { value: 1_000 }, yield_score: { value: 0 },
                               next_streak: { value: target.clean_streak.value + 1 }, capabilities: { value: "" })
      expect(target.clean_streak.to_h).to eq(value: 1)

      target.claim!(held_by: { value: "agent-one" }, now: { value: 2_000 })
      target = target.release!(now: { value: 2_000 }, yield_score: { value: 0 },
                               next_streak: { value: target.clean_streak.value + 1 }, capabilities: { value: "" })
      expect(target.clean_streak.to_h).to eq(value: 2)

      target.claim!(held_by: { value: "agent-one" }, now: { value: 3_000 })
      target = target.release!(now: { value: 3_000 }, yield_score: { value: 0 },
                               next_streak: { value: target.clean_streak.value + 1 }, capabilities: { value: "" })
      expect(target.clean_streak.to_h).to eq(value: 3)
    end

    it "resets to zero the moment a caller reports the pass was not clean" do
      target = a_target
      target.claim!(held_by: { value: "agent-one" }, now: { value: 1_000 })
      target = target.release!(now: { value: 1_000 }, yield_score: { value: 0 }, next_streak: { value: 4 },
                               capabilities: { value: "" })
      expect(target.clean_streak.to_h).to eq(value: 4)

      target.claim!(held_by: { value: "agent-one" }, now: { value: 2_000 })
      target = target.release!(now: { value: 2_000 }, yield_score: { value: 0 }, next_streak: { value: 0 },
                               capabilities: { value: "" })

      expect(target.clean_streak.to_h).to eq(value: 0)
    end

    # THE STICKY BIT `next_streak`'s OWN COMMENT DESCRIBES — a check
    # `Surprised` once and then resolved (`Remake` back to "made", then
    # `Held`) still shows the sweep once surprised, which is what a real
    # caller reads to decide `next_streak` is 0 rather than +1, EVEN
    # THOUGH the check's own CURRENT `outcome` by the time anyone looks
    # is "held" — indistinguishable from a check that was never anything
    # else, if `ever_surprised` did not exist.
    it "remembers a check was ever surprised, even after Remake resolves it clean" do
      sweep = a_sweep
      a_check(sweep)
      check(sweep, "Surprised", sequence: { value: 1 }, observation: { value: "as: was silently accepted" },
                                target: { value: "banking" })

      sweep = QualityControl::Sweep.find(sweep.id)
      expect(sweep.checks.first[:ever_surprised][:value]).to eq("yes")
      expect(sweep.checks.first[:outcome]).to eq("surprising")

      check(sweep, "Remake", sequence: { value: 1 })
      check(sweep, "Held", sequence: { value: 1 }, observation: { value: "fixed, re-run, now agrees" })

      sweep = QualityControl::Sweep.find(sweep.id)
      expect(sweep.checks.first[:outcome]).to eq("held")
      expect(sweep.checks.first[:ever_surprised][:value]).to eq("yes")
    end

    it "never marks a check that only ever held as having been surprised" do
      sweep = a_sweep
      a_check(sweep)
      check(sweep, "Held", sequence: { value: 1 }, observation: { value: "agreed" })

      sweep = QualityControl::Sweep.find(sweep.id)
      expect(sweep.checks.first[:ever_surprised][:value]).to eq("no")
    end
  end

  # ── the other queue ──────────────────────────────────────────────────

  # SWEEPING IS NOT THE ONLY WAY TO GET WORK. An agent that is not sweeping
  # takes the next open bug off the queue and fixes that instead — so a bug
  # is claimed for the same reason a chapter is.
  describe "taking a bug off the queue" do
    it "offers open bugs nobody is holding, oldest first" do
      sweep = a_sweep
      a_bug(sweep, reference: "BUG#2", sequence: 2)
      a_bug(sweep, reference: "BUG#1", sequence: 1)

      expect(references("Bug.Queue")).to eq(["BUG#1", "BUG#2"])
      expect(rows("Bug.InHand")).to be_empty
    end

    it "takes it out of the queue and into somebody's hands" do
      bug = a_bug(a_sweep)
      bug.claim!(held_by: { value: "agent-one" }, now: { value: 1_000 })

      expect(rows("Bug.Queue")).to be_empty
      expect(references("Bug.InHand")).to eq([bug.id])
    end

    it "refuses a second agent while the first is still on it" do
      bug = a_bug(a_sweep)
      bug.claim!(held_by: { value: "agent-one" }, now: { value: 1_000 })

      expect do
        bug.claim!(held_by: { value: "agent-two" }, now: { value: 1_060 })
      end.to raise_error(Hecks::Runtime::GivenNotMet, /not taken from the agent holding it/)
    end

    it "lets the next agent take one whose holder has gone quiet" do
      bug = a_bug(a_sweep)
      bug.claim!(held_by: { value: "agent-one" }, now: { value: 1_000 })
      bug.claim!(held_by: { value: "agent-two" }, now: { value: 1_900 })

      expect(bug.held_by.to_h).to eq(value: "agent-two")
    end

    # HOLDING IS ORTHOGONAL TO THE FIX. An agent picks up a bug that is
    # already `investigating` without moving it, which is why the claim is a
    # `given` here and a lifecycle edge on Target.
    it "does not move the fix along" do
      bug = a_bug(a_sweep)
      bug.investigate!(site: { value: "x.rb:1" }, cause: { value: "y" })
      bug.claim!(held_by: { value: "agent-one" }, now: { value: 1_000 })

      expect(bug.status).to eq("investigating")
    end

    it "puts it back on the queue when somebody gives up on it" do
      bug = a_bug(a_sweep)
      bug.claim!(held_by: { value: "agent-one" }, now: { value: 1_000 })
      bug.drop!(held_by: { value: "nobody" })

      expect(references("Bug.Queue")).to eq([bug.id])
    end
  end

  # ── the check ────────────────────────────────────────────────────────

  describe "a check" do
    it "is written down with its expectation before anything is observed" do
      sweep = a_sweep
      a_check(sweep)

      made = sweep.checks.first
      expect(made[:expectation][:value]).to eq("a frozen account refuses a second freeze")
      expect(made[:observation]).to be_nil
      expect(sweep.made.to_h).to eq(value: 1)
    end

    # `surprising` IS NOT `failed` — it covers the crash and the quiet
    # divergence without prejudging which, and the quiet one is the point.
    it "separates what the chapter promised from what surprised" do
      sweep = a_sweep
      a_check(sweep)
      a_check(sweep, subject: "Banking::Account.Open", expectation: "as: aliases the argument")

      check(sweep, "Held", sequence: { value: 1 }, observation: { value: "refused, as declared" })
      check(sweep, "Surprised", sequence:    { value: 2 },
                                observation: { value: "as: was accepted and the original name still answered" },
                                target:      { value: "banking" })

      surprising = rows("Sweep.Check.Surprising")
      expect(surprising.length).to eq(1)
      expect(surprising.first[:subject][:value]).to eq("Banking::Account.Open")
      expect(surprising.first[:sweep]).to eq(sweep.id)
    end

    it "counts a run that settled nothing as neither" do
      sweep = a_sweep
      a_check(sweep)
      check(sweep, "Unsettled", sequence: { value: 1 }, observation: { value: "the adapter was not reachable" })

      expect(rows("Sweep.Check.Surprising")).to be_empty
      expect(rows("Sweep.Check.Unsettled").length).to eq(1)
    end
  end

  # ── gates bend, and leave a mark ─────────────────────────────────────

  describe "a gate" do
    it "refuses a sweep that checked nothing" do
      sweep = a_sweep

      expect { sweep.conclude!(notes: { value: "Nothing was run, but here are forty characters of notes." }) }
        .to raise_error(Hecks::Runtime::GivenNotMet, /checked nothing/)
    end

    it "lets you through with a reason, and counts it" do
      sweep = a_sweep
      sweep.waive!(reason:    { value: "the chapter would not boot; recording the pass so the rotation moves on" },
                   waived_by: { value: "a person" })

      expect { sweep.conclude!(notes: { value: "Could not boot the chapter at all — see the waiver." }) }
        .not_to raise_error
      expect(references("Sweep.Waived")).to eq([sweep.id])
    end

    it "refuses notes too short to be a finding" do
      sweep = a_sweep
      a_check(sweep)

      expect { sweep.conclude!(notes: { value: "done" }) }
        .to raise_error(Hecks::Runtime::InvariantViolation, /what it learned/)
    end
  end

  # ── the one absolute rule ────────────────────────────────────────────

  # A GATE CAN BE WAIVED; AN ARGUMENT CANNOT. "No bug without the test that
  # proves it" is a required argument for exactly that reason.
  describe "no bug without evidence" do
    it "cannot be logged without the test that proves it" do
      sweep = a_sweep

      expect do
        QualityControl::Bug.log!(
          sweep: sweep.id, reference: { value: "BUG#2" }, sequence: { value: 2 },
          title: { value: "something is off" },
          symptom: { value: "it looked wrong" },
          expectation: { value: "it should not" }
        )
      end.to raise_error(Hecks::Runtime::AbsentArgument, /demonstration/)
    end

    it "is born proven — there is no state for an unproven report" do
      bug = a_bug(a_sweep)

      expect(bug.status).to eq("logged")
      expect(bug.demonstration.to_h[:value]).to include("rspec")
    end
  end

  describe "the fix" do
    def investigated
      bug = a_bug(a_sweep)
      bug.investigate!(site:  { value: "lib/hecksagain/bluebook/dsl/query_builder.rb:88" },
                       cause: { value: "the alias is parsed and then dropped before the IR is built" })
    end

    it "does not take a commit that is not a sha" do
      expect { investigated.fix!(reference: { value: "BUG#1" }, commit: { value: "later" }) }
        .to raise_error(Hecks::Runtime::TypeMismatch, /must match/)
    end

    it "does not be verified with nothing behind it" do
      expect { investigated.fix!(reference: { value: "BUG#1" }, commit: { value: "4f2a19c" }).verify! }
        .to raise_error(Hecks::Runtime::AbsentArgument, /evidence/)
    end

    it "keeps what was actually run, so the claim is checkable" do
      bug = investigated.fix!(reference: { value: "BUG#1" }, commit: { value: "4f2a19c" })
      bug.verify!(evidence: { value: "rspec --order random: 1335 examples, 0 failures, seed 12345" })

      expect(bug.status).to eq("verified")
      expect(bug.verification.to_h[:value]).to include("seed 12345")
    end

    it "cannot be fixed before anybody has looked at it" do
      expect { a_bug(a_sweep).fix!(reference: { value: "BUG#1" }, commit: { value: "4f2a19c" }) }
        .to raise_error(Hecks::Runtime::LifecycleRefused, /moves it only from "investigating"/)
    end

    it "says what would move a bug it stopped on" do
      bug = a_bug(a_sweep)

      expect { bug.pause!(reason: { value: "affects the whole type system" }) }
        .to raise_error(Hecks::Runtime::AbsentArgument, /next_step/)

      bug.pause!(reason:    { value: "affects the whole type system" },
                 next_step: { value: "architecture review — should coercion recurse into nested value objects?" })
      expect(references("Bug.Paused")).to eq([bug.id])
    end
  end

  # ── where to look next ───────────────────────────────────────────────

  def an_angle(reference: "ANGLE-1", proposer: "Claude QA",
               premise: "Nobody has fuzzed this construct combination before, and two existing bugs suggest it's ripe.",
               citation: "BUG#1", now: 1_000)
    runtime
    QualityControl::Angle.propose!(
      reference: { value: reference },
      premise:   { value: premise },
      citation:  { value: citation },
      proposer:  { value: proposer },
      now:       { value: now }
    )
  end

  describe "the backlog of where to look next" do
    # SAME FRICTION `Target.Claim` ALREADY REMOVED, for the same reason — see
    # "the clock" describe block above. Only the CLI door fills an omitted
    # argument from the clock port; the facade's own Ruby method (used
    # everywhere else in this file) always wants it named, the same way
    # `target.claim!`'s own direct calls do.
    it "fills proposed_at from the clock when the caller leaves it out" do
      runtime
      text, code = Hecks::Facade::CliRunner.call(
        runtime: runtime, program: "bin/qc",
        argv: ["propose", "reference.value=ANGLE-1", "premise.value=#{'a' * 60}",
               "citation.value=BUG#1", "proposer.value=Claude QA"]
      )

      expect(code).to eq(0)
      expect(JSON.parse(text).dig("state", "proposed_at", "value")).to eq(1_000)
    end

    it "refuses a premise too short to act on without the proposer in the room" do
      expect { an_angle(premise: "too short") }
        .to raise_error(Hecks::Runtime::InvariantViolation, /at least 60 characters/)
    end

    it "refuses an angle nobody will own" do
      expect { an_angle(proposer: "nobody") }
        .to raise_error(Hecks::Runtime::InvariantViolation, /proposed by somebody/)
    end

    it "sits in the backlog until it is investigated" do
      angle = an_angle(reference: "ANGLE-1")

      expect(references("Angle.Backlog")).to eq(["ANGLE-1"])
      expect(rows("Angle.Resolved")).to be_empty

      angle.investigate!
      expect(angle.status).to eq("investigating")
      expect(references("Angle.Backlog")).to eq(["ANGLE-1"])
    end

    it "offers the backlog oldest-first, by the scalar inside proposed_at, not the value object" do
      first  = an_angle(reference: "ANGLE-1") # takes the clock's fixed 1_000
      second = an_angle(reference: "ANGLE-2", citation: "BUG#2", now: 500)

      expect(references("Angle.Backlog")).to eq(["ANGLE-2", "ANGLE-1"])
      expect(second.proposed_at.to_h[:value]).to be < first.proposed_at.to_h[:value]
    end

    it "cannot be built before anybody has looked at it" do
      expect { an_angle.build!(resolution: { value: "PR #999" }) }
        .to raise_error(Hecks::Runtime::LifecycleRefused, /moves it only from "investigating"/)
    end

    it "moves a chased lead into what actually got built" do
      angle = an_angle
      angle.investigate!

      built = angle.build!(resolution: { value: "BUG#6, PR #530, qa/stress_domains/waybill" })

      expect(built.status).to eq("built")
      expect(references("Angle.Resolved")).to eq([angle.id])
      expect(rows("Angle.Backlog")).to be_empty
    end

    it "discards a lead — before or after investigating — with a reason" do
      never_started = an_angle(reference: "ANGLE-1")
      expect { never_started.discard! }
        .to raise_error(Hecks::Runtime::AbsentArgument, /reason/)
      never_started.discard!(reason: { value: "already covered by nested_pieces — not a distinct angle after all" })

      investigated = an_angle(reference: "ANGLE-2")
      investigated.investigate!
      investigated.discard!(reason: { value: "real investigation found no reachable divergence" })

      expect(references("Angle.Resolved")).to contain_exactly("ANGLE-1", "ANGLE-2")
      expect(rows("Angle.Backlog")).to be_empty
    end

    it "lists every angle ever proposed" do
      an_angle(reference: "ANGLE-1")
      an_angle(reference: "ANGLE-2", citation: "ADR 0037")

      expect(references("Angle.All")).to eq(["ANGLE-1", "ANGLE-2"])
    end
  end

  # ── the outside world ────────────────────────────────────────────────

  describe "raising a ticket" do
    def a_paused_bug
      bug = a_bug(a_sweep)
      bug.pause!(reason: { value: "architectural" }, next_step: { value: "architecture review" })
    end

    def raise_ticket(bug, reference: "TK-1")
      QualityControl::Ticket.raise!(
        bug: bug.id, reference: { value: reference },
        repository: { value: "chrisyoung/hecksagain" },
        title: { value: "as: is accepted and does not alias" },
        body: { value: "see the demonstration" }
      )
      runtime.dispatch("QualityControl::Ticket.Submit", id: "TK-1")
    end

    it "cannot be raised for a bug that does not exist" do
      a_sweep

      expect do
        QualityControl::Ticket.raise!(
          bug: "BUG#nope", reference: { value: "TK-9" },
          repository: { value: "chrisyoung/hecksagain" },
          title: { value: "x" }, body: { value: "y" }
        )
      end.to raise_error(Hecks::Runtime::NotFound)
    end

    # THE DOMAIN DOES THE ASKING. `Raise` records the intent; the policy fires
    # the port; the adapter answers; a second policy records what came back.
    #
    # FIXED: `trigger Ticket::IssueTracker::File` — a policy triggering an
    # `asks`/`tells` PORT OPERATION (three segments: aggregate, port,
    # operation) rather than a plain command (two segments: aggregate,
    # command) used to never resolve. `Naming.command_ref`'s bare-constant
    # rewrite (only the LAST `::` becomes `.`) turns this into
    # "Ticket::IssueTracker.File", which `Naming.split_verb` now folds any
    # LEFTOVER `::` past the already-resolved domain boundary into the
    # dot-joined command path instead of capping at two pieces — recovering
    # "Ticket.IssueTracker.File", the same shape a working port dispatch
    # already used. `ReactionInvocation#resolve_target` gained a matching
    # port-operation branch (checked before entity resolution, same order
    # `Dispatcher#dispatch` already uses), and `PortOperation#creates?`
    # (always false) lets `source_receiver_for` lift the triggering
    # event's own id as the operation's receiver the same way it already
    # does for a plain same-aggregate command.
    it "files it through the port and records what the tracker said" do
      raise_ticket(a_paused_bug)

      expect(runtime.events.map(&:name)).to include("IssueFiled", "TicketFiled")
      expect(rows("Ticket.Filed").first[:number][:value]).to eq(43)
    end

    # EVERY FAILURE IS AN ANSWER — the raise from the far side becomes the
    # refusal the chapter named, and the retry policy takes it from there.
    it "turns a dead token into the refusal it named, and asks again" do
      runtime = boot_quality_control(RefusingTracker)
      allow(self).to receive(:runtime).and_return(runtime) if respond_to?(:allow)

      target = QualityControl::Target.identify!(reference: { value: "banking" }, path: { value: "examples/banking" })
      sweep  = QualityControl::Sweep.open!(target: target.id, reference: { value: "SW-1" },
                                           engineer: { value: "Claude QA" })
      bug    = QualityControl::Bug.log!(
        sweep: sweep.id, reference: { value: "BUG#1" }, sequence: { value: 1 },
        title: { value: "t" }, demonstration: { value: "rspec x" },
        symptom: { value: "s" }, expectation: { value: "e" },
        submitter: { value: "Claude QA" }
      )
      bug.pause!(reason: { value: "architectural" }, next_step: { value: "review" })

      QualityControl::Ticket.raise!(
        bug: bug.id, reference: { value: "TK-1" },
        repository: { value: "chrisyoung/hecksagain" },
        title: { value: "x" }, body: { value: "y" }
      )
      runtime.dispatch("QualityControl::Ticket.Submit", id: "TK-1")

      names = runtime.events.map(&:name)
      expect(names).to include("IssueFilingRefused", "TicketFilingRefused", "TicketRetried")
      expect(runtime.query("QualityControl::Ticket.All").first[:refusal][:value]).to include("token expired")
    end
  end

  # ── which pull requests are ours ──────────────────────────────────────

  # THE WORKLIST `bin/qa_pr_check` NOW READS INSTEAD OF SEARCHING. A patch
  # is recorded the moment its number, branch and commit are already known
  # — at `gh pr create` — not rediscovered afterward by guessing at a
  # branch prefix or a title convention.
  describe "tracking a pull request" do
    def a_bug_needing_a_patch
      a_bug(a_sweep)
    end

    def open_patch(bug, number: 538, branch: "loop-parity/some-slug", commit: "4f2a19c", now: 1_000)
      QualityControl::Patch.open!(
        bug: bug.id, number: { value: number },
        url: { value: "https://github.com/heckslabs/hecks/pull/#{number}" },
        branch: { value: branch }, commit: { value: commit },
        title: { value: "loop-parity: #{branch}" },
        now: { value: now }
      )
    end

    def open_numbers = rows("Patch.Open").map { |row| row[:number][:value] }

    it "cannot be opened for a bug that does not exist" do
      a_sweep

      expect do
        QualityControl::Patch.open!(
          bug: "BUG#nope", number: { value: 1 },
          url: { value: "https://example.com/pull/1" },
          branch: { value: "x" }, commit: { value: "4f2a19c" },
          title: { value: "x" }, now: { value: 1_000 }
        )
      end.to raise_error(Hecks::Runtime::NotFound)
    end

    it "is born opened, and shows up in the worklist by number" do
      patch = open_patch(a_bug_needing_a_patch)

      expect(patch.status).to eq("opened")
      expect(open_numbers).to eq([538])
    end

    it "drops out of the worklist once GitHub merges it" do
      patch = open_patch(a_bug_needing_a_patch)
      patch.merge!

      expect(patch.status).to eq("merged")
      expect(open_numbers).to be_empty
    end

    it "drops out of the worklist once GitHub closes it without merging" do
      patch = open_patch(a_bug_needing_a_patch)
      patch.close!

      expect(patch.status).to eq("closed")
      expect(open_numbers).to be_empty
    end

    # THE DUPLICATE CHECK — the same shape `Ticket.ForBug` already gives
    # for an issue, restated here rather than shared (this file's own
    # habit for a per-aggregate query).
    it "finds every patch ever opened for one bug" do
      bug = a_bug_needing_a_patch
      open_patch(bug, number: 538, branch: "loop-parity/first")
      open_patch(bug, number: 540, branch: "loop-parity/second")

      numbers = rows("Patch.ForBug", bug_id: { value: bug.id }).map { |row| row[:number][:value] }
      expect(numbers).to contain_exactly(538, 540)
    end

    # THE WHOLE POINT: the worklist carries the commit already, so nothing
    # downstream has to ask GitHub to find it, or guess which Bug a commit
    # belongs to.
    it "carries the commit that makes checking it a lookup, not a guess" do
      bug = a_bug_needing_a_patch
      open_patch(bug, number: 538, commit: "4f2a19c")

      open = rows("Patch.Open").first
      expect(open[:number][:value]).to eq(538)
      expect(open[:commit][:value]).to eq("4f2a19c")
      expect(open[:bug]).to eq(bug.id)
    end

    it "lists every patch ever opened, whatever became of it" do
      bug = a_bug_needing_a_patch
      merged = open_patch(bug, number: 538, branch: "loop-parity/first")
      merged.merge!
      open_patch(bug, number: 540, branch: "loop-parity/second")

      numbers = rows("Patch.All").map { |row| row[:number][:value] }
      expect(numbers).to contain_exactly(538, 540)
    end
  end

  # ── deliberate work, landed ───────────────────────────────────────────

  # `Patch`'S SIBLING, NOT A SECOND DOOR INTO IT — a real PR that names no
  # `Bug` because nothing was proven wrong: a domain-modeling addition, a
  # tool, this very aggregate. `Open` records the PR is real; `Land` is
  # what puts a commit on the record worth watching, and it is a SEPARATE
  # command on purpose (see the aggregate's own header comment) — a fresh
  # `Land` is also how a `needs_fix` row gets a second chance.
  describe "tracking deliberate work" do
    def open_improvement(number: 9001, branch: "qa/some-slug", angle: nil, now: 1_000)
      runtime
      QualityControl::Improvement.open!(
        **(angle ? { angle: angle.id } : {}),
        number: { value: number },
        url:    { value: "https://github.com/heckslabs/hecks/pull/#{number}" },
        branch: { value: branch },
        title:  { value: "qa: #{branch}" },
        now:    { value: now }
      )
    end

    def open_numbers = rows("Improvement.Open").map { |row| row[:number][:value] }

    it "refuses an angle that does not exist, when one is cited" do
      runtime

      expect do
        QualityControl::Improvement.open!(
          angle: "ANGLE-nope", number: { value: 1 },
          url: { value: "https://example.com/pull/1" },
          branch: { value: "x" }, title: { value: "x" }, now: { value: 1_000 }
        )
      end.to raise_error(Hecks::Runtime::NotFound)
    end

    it "is born opened, with no commit on the record yet" do
      improvement = open_improvement

      expect(improvement.status).to eq("opened")
      expect(improvement.commit.to_h[:value]).to be_nil
      expect(open_numbers).to eq([9001])
    end

    it "records the commit once landed, and stays on the worklist" do
      improvement = open_improvement.land!(number: { value: 9001 }, commit: { value: "4f2a19c" })

      expect(improvement.status).to eq("landed")
      expect(improvement.commit.to_h[:value]).to eq("4f2a19c")
      expect(open_numbers).to eq([9001])
    end

    it "drops out of the worklist once GitHub merges it" do
      improvement = open_improvement.land!(number: { value: 9001 }, commit: { value: "4f2a19c" })
      improvement.merge!

      expect(improvement.status).to eq("merged")
      expect(open_numbers).to be_empty
    end

    it "drops out of the worklist once GitHub closes it without merging" do
      improvement = open_improvement.land!(number: { value: 9001 }, commit: { value: "4f2a19c" })
      improvement.close!

      expect(improvement.status).to eq("closed")
      expect(open_numbers).to be_empty
    end

    # REAL, NOT HYPOTHETICAL — PR #543 (a deliberate proof-only PR, never
    # meant to merge) was closed by a human the moment its point was made,
    # while still sitting at "opened" in this ledger: `bin/qa_pr_check`
    # never got a chance to dispatch `Land` at all. `retire_if_settled?`
    # dispatches `Close` the instant `gh pr view` reports CLOSED, whatever
    # this ledger's own status says — this is the case `Merge`/`Close`
    # being `from: ["landed", "needs_fix"]` alone (missing "opened") let
    # crash with an uncaught `LifecycleRefused` instead of retiring
    # cleanly, the same as `Patch`'s own equivalent test above (which has
    # no "landed" to skip) already exercises for a bug's own fix.
    it "drops out of the worklist when GitHub closes it before it was ever landed" do
      improvement = open_improvement
      improvement.close!

      expect(improvement.status).to eq("closed")
      expect(open_numbers).to be_empty
    end

    it "drops out of the worklist when GitHub merges it before it was ever landed" do
      improvement = open_improvement
      improvement.merge!

      expect(improvement.status).to eq("merged")
      expect(open_numbers).to be_empty
    end

    # A DELIBERATE CITATION IS REAL, NOT REQUIRED — `Angle.Build` already
    # marks a lead resolved-by-building-something; this is the other half
    # of that same loop, readable from the improvement's own side.
    it "can cite the angle it fulfills, and be found by it" do
      angle = an_angle(reference: "ANGLE-1")
      angle.investigate!
      improvement = open_improvement(angle: angle)

      numbers = rows("Improvement.ForAngle", angle_id: { value: angle.id }).map { |row| row[:number][:value] }
      expect(numbers).to eq([improvement.number.to_h[:value]])
    end

    it "lists every improvement ever landed, whatever became of it" do
      merged = open_improvement(number: 9001, branch: "qa/first").land!(number: { value: 9001 }, commit: { value: "4f2a19c" })
      merged.merge!
      open_improvement(number: 9002, branch: "qa/second")

      numbers = rows("Improvement.All").map { |row| row[:number][:value] }
      expect(numbers).to contain_exactly(9001, 9002)
    end
  end

  # ── is it safe to ship ───────────────────────────────────────────────

  # NOT A QUESTION ABOUT NOW — a record about a commit. CI went green at two
  # o'clock; you have pushed twice since; the green belongs to what it ran
  # against, and the new commit simply has none of its own.
  describe "clearance" do
    it "clears the exact commit it ran against, and nothing else" do
      runtime
      cleared = QualityControl::Clearance.start!(commit: { value: "4f2a19c" })
      cleared.passed!(summary: { value: "1335 examples, 0 failures, seed 12345" })
      QualityControl::Clearance.start!(commit: { value: "bc91d76" })

      expect(rows("Clearance.For", commit: { value: "4f2a19c" }).length).to eq(1)
      expect(rows("Clearance.For", commit: { value: "bc91d76" })).to be_empty
    end

    it "answers no for a commit nobody has run at all" do
      runtime

      expect(rows("Clearance.For", commit: { value: "deadbee" })).to be_empty
    end

    it "keeps what the run actually said when it went red" do
      runtime
      run = QualityControl::Clearance.start!(commit: { value: "0d85613" })
      # `refusal`, NOT `summary` — the argument is named for where it comes
      # from. A refused ask hands its policy the word `refusal`, so the
      # command that records a red run has to take that word or never fire;
      # `then_set` is what puts it in the `summary` this query reads.
      run.failed!(refusal: { value: "1335 examples, 5 failures, seed 12345" })

      expect(rows("Clearance.Red").first[:summary][:value]).to include("5 failures")
    end

    # THE GATE, DRIVEN END TO END BY THE PORT rather than by hand. The two
    # tests above dispatch `Passed`/`Failed` directly, which proves the
    # chapter but not the wiring — and the wiring is where this broke: the
    # refusal arrives under a key the command must already declare, and
    # nothing but running it says whether it does.
    it "records a clearance from whatever CI answers, both ways" do
      runtime

      QualityControl::Clearance.start!(commit: { value: "abc1234" })
      runtime.dispatch("QualityControl::Clearance.CI.Run", commit: "abc1234")

      expect(rows("Clearance.All").first[:status]).to eq("green")
    end

    it "records a red run under the word the runtime actually hands back" do
      red = boot_quality_control(StubTracker, ci_adapter: RedCi)
      QualityControl::Clearance.start!(commit: { value: "def5678" })
      red.dispatch("QualityControl::Clearance.CI.Run", commit: "def5678")

      expect(red.query("QualityControl::Clearance.Red").first[:summary][:value]).to include("2 failures")
    end
  end

  # ── noticing when a fix stops holding ───────────────────────────────

  # `BugCiWatch` — nothing dispatches `Bug.Regress` by hand here. It
  # starts the moment a bug is fixed, watches for the FIRST clearance
  # answer against that exact commit, and acts (or doesn't) entirely on
  # its own.
  describe "the CI watch" do
    def fixed_bug(commit)
      bug = a_bug(a_sweep)
      bug.investigate!(site: { value: "lib/x.rb" }, cause: { value: "c" })
      bug.fix!(reference: { value: "BUG#1" }, commit: { value: commit })
    end

    it "puts the bug back when its own commit comes back red" do
      fixed_bug("4f2a19c")

      QualityControl::Clearance.start!(commit: { value: "4f2a19c" })
                               .failed!(refusal: { value: "1335 examples, 3 failures, seed 999" })

      expect(QualityControl::Bug.find("BUG#1").status).to eq("investigating")
      expect(runtime.sagas).to include(hash_including(process_manager: "BugCiWatch", dispatch: "Bug.Regress", delivered: true))
    end

    # GREEN NEEDS NOBODY. The instance just ends — `ends_on` deletes it the
    # moment `ClearanceGiven` arrives for this commit, same as any other
    # process manager's own terminal event.
    it "just ends when the commit comes back green — nothing left to watch for" do
      fixed_bug("9a8b7c6")

      QualityControl::Clearance.start!(commit: { value: "9a8b7c6" })
                               .passed!(summary: { value: "1335 examples, 0 failures" })

      expect(QualityControl::Bug.find("BUG#1").status).to eq("fixed")
      expect(runtime.registry.saga_instances["BugCiWatch"]).to be_empty
    end

    # THE WHOLE REASON THIS CORRELATES BY COMMIT AND NOT BY BUG: a red run
    # against somebody ELSE's commit must never touch this bug.
    it "ignores a clearance against an unrelated commit" do
      fixed_bug("4f2a19c")

      QualityControl::Clearance.start!(commit: { value: "deadbee" })
                               .failed!(refusal: { value: "unrelated failure" })

      expect(QualityControl::Bug.find("BUG#1").status).to eq("fixed")
    end
  end

  # ── noticing when landed work stops holding ─────────────────────────

  # `ImprovementCiWatch` — the same mechanism as `BugCiWatch` above,
  # aimed at deliberate work instead of a proven-wrong finding. Nothing
  # dispatches `Improvement.Regress` by hand here either.
  describe "the CI watch for landed work" do
    def landed_improvement(commit, number: 9001)
      runtime
      improvement = QualityControl::Improvement.open!(
        number: { value: number },
        url: { value: "https://github.com/heckslabs/hecks/pull/#{number}" },
        branch: { value: "qa/smoke" }, title: { value: "smoke" }, now: { value: 1_000 }
      )
      improvement.land!(number: { value: number }, commit: { value: commit })
    end

    it "puts landed work back in needs_fix when its own commit comes back red" do
      landed_improvement("4f2a19c")

      QualityControl::Clearance.start!(commit: { value: "4f2a19c" })
                               .failed!(refusal: { value: "1335 examples, 3 failures, seed 999" })

      expect(QualityControl::Improvement.find(9001).status).to eq("needs_fix")
      expect(runtime.sagas).to include(hash_including(process_manager: "ImprovementCiWatch",
                                                      dispatch: "Improvement.Regress", delivered: true))
    end

    # GREEN NEEDS NOBODY — same reading `BugCiWatch`'s own spec already
    # gives: the instance just ends, `ends_on` deletes it the moment
    # `ClearanceGiven` arrives for this commit.
    it "just ends when the commit comes back green — nothing left to watch for" do
      landed_improvement("9a8b7c6")

      QualityControl::Clearance.start!(commit: { value: "9a8b7c6" })
                               .passed!(summary: { value: "1335 examples, 0 failures" })

      expect(QualityControl::Improvement.find(9001).status).to eq("landed")
      expect(runtime.registry.saga_instances["ImprovementCiWatch"]).to be_empty
    end

    # THE WHOLE REASON THIS CORRELATES BY COMMIT, NOT BY THE IMPROVEMENT'S
    # OWN REFERENCE: a red run against somebody ELSE's commit must never
    # touch this record.
    it "ignores a clearance against an unrelated commit" do
      landed_improvement("4f2a19c")

      QualityControl::Clearance.start!(commit: { value: "deadbee" })
                               .failed!(refusal: { value: "unrelated failure" })

      expect(QualityControl::Improvement.find(9001).status).to eq("landed")
    end

    # THE WHOLE REASON `Open` AND `Land` ARE TWO COMMANDS: a fresh `Land`
    # after `needs_fix` fires `ImprovementLanded` again, the SAME event
    # `starts_on` names, so the watch picks the new commit back up on its
    # own — proven here against a real, synthetic `Clearance` for the new
    # sha, not merely asserted.
    it "watches the fresh commit again once re-landed after a NeedsFix" do
      landed_improvement("4f2a19c")

      QualityControl::Clearance.start!(commit: { value: "4f2a19c" })
                               .failed!(refusal: { value: "1335 examples, 1 failure" })
      expect(QualityControl::Improvement.find(9001).status).to eq("needs_fix")

      QualityControl::Improvement.find(9001).land!(number: { value: 9001 }, commit: { value: "bbbbbbb" })
      expect(QualityControl::Improvement.find(9001).status).to eq("landed")

      QualityControl::Clearance.start!(commit: { value: "bbbbbbb" })
                               .failed!(refusal: { value: "1335 examples, 1 failure, still failing" })

      expect(QualityControl::Improvement.find(9001).status).to eq("needs_fix")
      expect(runtime.sagas.count { |s| s[:process_manager] == "ImprovementCiWatch" && s[:dispatch] == "Improvement.Regress" })
        .to eq(2)
    end
  end

  # TAGS — PUT ON, REPLACED, AND FOUND AGAIN.
  describe "tags" do
    let(:sweep) { a_sweep }

    def a_bug_tagged(reference, *tags)
      # `sweep` FIRST, because Ruby evaluates the receiver before the
      # arguments — `QualityControl::Bug` would be resolved before the boot
      # that defines it.
      holder = sweep

      QualityControl::Bug.log!(sweep: holder.id, reference: { value: reference }, sequence: { value: 1 },
                               title: { value: "t" }, demonstration: { value: "spec/x_spec.rb:1" },
                               symptom: { value: "s" }, expectation: { value: "e" },
                               submitter: { value: "Claude QA" },
                               tags: tags.map { |tag| { value: tag } })
    end

    it "finds every bug carrying one tag, whatever state it is in" do
      a_bug_tagged("BUG#1", "framework", "cli")
      a_bug_tagged("BUG#2", "docs")

      expect(references("Bug.Tagged", tag: { value: "framework" })).to eq(["BUG#1"])
      expect(references("Bug.Tagged", tag: { value: "docs" })).to eq(["BUG#2"])
      expect(references("Bug.Tagged", tag: { value: "nothing" })).to be_empty
    end

    it "does not match a tag that is merely a prefix of another" do
      a_bug_tagged("BUG#1", "framework")

      expect(references("Bug.Tagged", tag: { value: "frame" })).to be_empty
    end

    # REPLACES RATHER THAN APPENDS, and the spec says so out loud because it
    # is the one surprising thing about the verb. There is no append in this
    # language; `Tag` takes the whole set.
    it "replaces the set, so a tag can be taken off" do
      bug = a_bug_tagged("BUG#1", "framework", "cli")
      bug.tag!(tags: [{ value: "framework" }])

      expect(references("Bug.Tagged", tag: { value: "framework" })).to eq(["BUG#1"])
      expect(references("Bug.Tagged", tag: { value: "cli" })).to be_empty
    end

    it "can be tagged after it is verified — a tag is not a lifecycle move" do
      bug = a_bug_tagged("BUG#1")
      bug.investigate!(site: { value: "lib/x.rb" }, cause: { value: "c" })
      bug.fix!(reference: { value: "BUG#1" }, commit: { value: "abc1234" })
      bug.verify!(evidence: { value: "the failing spec now passes" })
      bug.tag!(tags: [{ value: "regression" }])

      expect(references("Bug.Tagged", tag: { value: "regression" })).to eq(["BUG#1"])
    end
  end

  # ── a surprised chapter waits for a person ───────────────────────────

  # `suspended` — the state `held` used to stand in for. Nothing here
  # dispatches `Target.Suspend` by hand: `SuspendOnSurprise` (the
  # chapter's own foot) does it, from the `target` a surprising check
  # restates, and that is the whole claim under test.
  describe "a surprised chapter" do
    def held_target_with_open_sweep
      target = a_target
      target.claim!(held_by: { value: "qa_sweep" }, now: { value: 1_000 })
      sweep = a_sweep(target)
      a_check(sweep)
      [target, sweep]
    end

    it "is suspended by the ledger itself the moment a check surprises, and leaves the rotation" do
      target, sweep = held_target_with_open_sweep
      check(sweep, "Surprised", sequence: { value: 1 }, observation: { value: "diverged" },
                                target: { value: target.id })

      suspended = QualityControl::Target.find(target.id)
      expect(suspended.status).to eq("suspended")
      expect(suspended.reason.to_h[:value]).to include("--release")
      expect(references("Target.Rotation")).to be_empty
      expect(references("Target.Held")).to be_empty
      expect(references("Target.Suspended")).to eq([target.id])
      expect(runtime.reactions).to include(hash_including(policy: "SuspendOnSurprise", delivered: true))
    end

    it "refuses a surprise that does not say which chapter it is about" do
      _target, sweep = held_target_with_open_sweep

      expect { check(sweep, "Surprised", sequence: { value: 1 }, observation: { value: "diverged" }) }
        .to raise_error(Hecks::Runtime::AbsentArgument, /target/)
    end

    # NO STALE-CLAIM ARITHMETIC REACHES A SUSPENDED CHAPTER — that is the
    # difference from `held`, and the reason the state exists.
    it "cannot be claimed, however old the suspension, and comes back only through Release" do
      target, sweep = held_target_with_open_sweep
      check(sweep, "Surprised", sequence: { value: 1 }, observation: { value: "diverged" },
                                target: { value: target.id })
      suspended = QualityControl::Target.find(target.id)

      expect { suspended.claim!(held_by: { value: "agent-two" }, now: { value: 1_000_000 }) }
        .to raise_error(Hecks::Runtime::LifecycleRefused)

      released = suspended.release!(now: { value: 2_000 }, yield_score: { value: 1 }, next_streak: { value: 0 },
                                    capabilities: { value: "rust" })
      expect(released.status).to eq("waiting")
      expect(references("Target.Rotation")).to eq([target.id])
    end
  end

  describe "restoring a shelved chapter" do
    it "refuses without a reason, and records the one it is given" do
      target = a_target
      target.shelve!(reason: { value: "no Rust binary, and no time to project one" })

      expect { target.restore! }.to raise_error(Hecks::Runtime::AbsentArgument, /reason/)

      restored = target.restore!(reason: { value: "bin/project_rust now covers it" })
      expect(restored.status).to eq("waiting")
      expect(restored.reason.to_h[:value]).to eq("bin/project_rust now covers it")
    end
  end

  # ── what a chapter can be compared against ───────────────────────────

  describe "capabilities" do
    def released_with(reference, path, capabilities)
      target = a_target(reference, path)
      target.claim!(held_by: { value: "qa_sweep" }, now: { value: 1_000 })
      target.release!(now: { value: 1_000 }, yield_score: { value: 0 }, next_streak: { value: 1 },
                      capabilities: { value: capabilities })
    end

    it "start empty — a chapter nobody has released is eligible for nothing yet" do
      expect(a_target.capabilities.to_h).to eq(value: "")
      expect(rows("Target.EligibleFor", mode: { value: "rust" })).to be_empty
    end

    it "are recorded at release and answer which waiting chapters a mode can reach" do
      released_with("directory", "examples/directory", "postgres_era")
      released_with("pizzas", "examples/pizzas", "rust,postgres_era")
      a_target("roster", "examples/roster")

      expect(references("Target.EligibleFor", mode: { value: "postgres_era" })).to contain_exactly("directory", "pizzas")
      expect(references("Target.EligibleFor", mode: { value: "rust" })).to eq(["pizzas"])
      expect(references("Target.EligibleFor", mode: { value: "wasm" })).to be_empty
    end

    it "only count a chapter that is actually waiting" do
      target = released_with("pizzas", "examples/pizzas", "rust")
      target.claim!(held_by: { value: "qa_sweep" }, now: { value: 5_000 })

      expect(rows("Target.EligibleFor", mode: { value: "rust" })).to be_empty
    end

    it "must be said at release — the runner always knows what it inferred" do
      target = a_target
      target.claim!(held_by: { value: "qa_sweep" }, now: { value: 1_000 })

      expect { target.release!(now: { value: 1_000 }, yield_score: { value: 0 }, next_streak: { value: 1 }) }
        .to raise_error(Hecks::Runtime::AbsentArgument, /capabilities/)
    end
  end

  # ── a waiver is signed by a person ───────────────────────────────────

  describe "a signed waiver" do
    let(:reason) { { value: "the chapter would not boot; recording the pass so the rotation moves on" } }

    it "refuses the loop's own identity, on a sweep and on a bug" do
      sweep = a_sweep
      expect { sweep.waive!(reason: reason, waived_by: { value: "qa_sweep" }) }
        .to raise_error(Hecks::Runtime::InvariantViolation, /never by the loop/)

      bug = a_bug(sweep)
      expect { bug.waive!(reason: reason, waived_by: { value: "qa_sweep" }) }
        .to raise_error(Hecks::Runtime::InvariantViolation, /never by the loop/)
    end

    it "refuses an unsigned one" do
      expect { a_sweep.waive!(reason: reason, waived_by: { value: "nobody" }) }
        .to raise_error(Hecks::Runtime::InvariantViolation, /signed/)
    end

    it "refuses one with no signature at all" do
      expect { a_sweep.waive!(reason: reason) }.to raise_error(Hecks::Runtime::AbsentArgument, /waived_by/)
    end

    it "counts a person's waiver and keeps the signature" do
      sweep = a_sweep.waive!(reason: reason, waived_by: { value: "Chris" })
      expect(sweep.waived.to_h).to eq(value: 1)
      expect(sweep.waived_by.to_h).to eq(value: "Chris")
      expect(references("Sweep.Waived")).to eq([sweep.id])

      bug = a_bug(sweep).waive!(reason: reason, waived_by: { value: "Chris" })
      expect(bug.waived_by.to_h).to eq(value: "Chris")
      expect(references("Bug.Waived")).to eq([bug.id])
    end

    # THE PIN. The invariant grammar reads literals, not constants, so
    # `WaivedBy` spells "qa_sweep" out where `bin/qa_sweep` reads
    # `AUTOMATED_ENGINEER` — this is what keeps the two from drifting.
    it "refuses exactly the identity the loop runs as" do
      runtime

      expect(QualityControlDials::AUTOMATED_ENGINEER).to eq("qa_sweep")
      %w[Sweep Bug].each do |aggregate|
        waived_by = runtime.registry.bluebook("QualityControl").aggregate(aggregate).value_objects
                           .find { |vo| vo.hecks_name == "WaivedBy" }
        refused = waived_by.invariants.map { |invariant| invariant.canonical.to_s }.join(" ")
        expect(refused).to include(QualityControlDials::AUTOMATED_ENGINEER.inspect)
      end
    end
  end

  # ── the judgment, recorded ───────────────────────────────────────────

  describe "triage" do
    def by_disposition = runtime.query("QualityControl.BugsByDisposition").first[:bugs]

    it "is born undecided, and owed until somebody decides" do
      bug = a_bug(a_sweep)

      expect(bug.disposition.to_h).to eq(value: "undecided")
      expect(references("Bug.Untriaged")).to eq([bug.id])
      expect(by_disposition["undecided"].keys).to eq([bug.id])
    end

    it "refuses undecided as a decision" do
      expect { a_bug(a_sweep).triage!(disposition: { value: "undecided" }) }
        .to raise_error(Hecks::Runtime::GivenNotMet, /never undecided/)
    end

    it "records the call, tallies it, and moves nothing else" do
      sweep = a_sweep
      one = a_bug(sweep, reference: "BUG#1", sequence: 1)
      two = a_bug(sweep, reference: "BUG#2", sequence: 2)
      one.investigate!(site: { value: "lib/x.rb" }, cause: { value: "c" })

      one = one.triage!(disposition: { value: "self_contained" })
      two.triage!(disposition: { value: "bigger" })

      expect(one.status).to eq("investigating")
      expect(rows("Bug.Untriaged")).to be_empty
      expect(by_disposition["self_contained"].keys).to eq(["BUG#1"])
      expect(by_disposition["bigger"].keys).to eq(["BUG#2"])
    end

    it "drops a bug out of Untriaged once it is no longer live, decided or not" do
      bug = a_bug(a_sweep)
      bug.withdraw!(reason: { value: "the test proved something else" })

      expect(rows("Bug.Untriaged")).to be_empty
    end
  end

  # ── when a PR was opened ─────────────────────────────────────────────

  describe "when a PR was opened" do
    def a_fixed_bug
      bug = a_bug(a_sweep)
      bug.investigate!(site: { value: "lib/x.rb" }, cause: { value: "c" })
      bug.fix!(reference: { value: "BUG#1" }, commit: { value: "4f2a19c" })
    end

    def open_patch(bug, number, now)
      QualityControl::Patch.open!(
        bug: bug.id, number: { value: number }, url: { value: "https://example.com/pull/#{number}" },
        branch: { value: "qa/x" }, commit: { value: "4f2a19c" }, title: { value: "x" }, now: { value: now }
      )
    end

    def open_improvement(number, now)
      QualityControl::Improvement.open!(
        number: { value: number }, url: { value: "https://example.com/pull/#{number}" },
        branch: { value: "qa/y" }, title: { value: "y" }, now: { value: now }
      )
    end

    def numbers(query, since) = rows(query, since: { value: since }).map { |row| row[:number][:value] }

    it "is stamped with when, and counted from any instant since" do
      bug = a_fixed_bug
      open_patch(bug, 1, 5_000)
      open_patch(bug, 2, 9_000)
      open_improvement(3, 9_500)

      expect(QualityControl::Patch.find(1).opened_at.to_h).to eq(value: 5_000)
      expect(numbers("Patch.OpenedSince", 4_000)).to eq([1, 2])
      expect(numbers("Patch.OpenedSince", 6_000)).to eq([2])
      expect(numbers("Patch.OpenedSince", 9_001)).to be_empty
      expect(numbers("Improvement.OpenedSince", 9_000)).to eq([3])
    end

    # A ROW FROM BEFORE THE FIELD EXISTED hydrates at the epoch, and the
    # epoch is before any midnight `bin/qa_open_pr` ever counts from.
    it "never counts a PR recorded at the epoch against a later day" do
      open_patch(a_fixed_bug, 1, 0)

      expect(numbers("Patch.OpenedSince", 1)).to be_empty
    end

    it "must say when" do
      bug = a_fixed_bug

      expect do
        QualityControl::Patch.open!(
          bug: bug.id, number: { value: 1 }, url: { value: "u" }, branch: { value: "qa/x" },
          commit: { value: "4f2a19c" }, title: { value: "x" }
        )
      end.to raise_error(Hecks::Runtime::AbsentArgument, /now/)
    end
  end

  # ── the duplicate-premise check ──────────────────────────────────────

  describe "citing" do
    it "finds every angle ever proposed on one exact citation, whatever became of it" do
      an_angle(reference: "ANGLE-1", citation: "BUG#7")
      an_angle(reference: "ANGLE-2", citation: "BUG#7").discard!(reason: { value: "already covered" })
      an_angle(reference: "ANGLE-3", citation: "ADR 0037 F5")

      expect(references("Angle.Citing", citation: { value: "BUG#7" })).to eq(["ANGLE-1", "ANGLE-2"])
      expect(references("Angle.Citing", citation: { value: "BUG#8" })).to be_empty
    end
  end

  # ── the dials the scripts read ───────────────────────────────────────

  describe "the dials" do
    before { runtime }

    # THE REAL TABLE'S OWN BOUNDARIES — `spec/sweep_depth_spec.rb` proves
    # the function against a table it passes in; this pins the dial.
    it "widen the sweep at exactly the fifth and the twentieth clean release" do
      depth = ->(streak) { Hecks::Fuzzing::SweepDepth.for_streak(streak, tiers: QualityControlDials::WIDENING_TIERS) }

      expect(depth.call(4)).to eq([10, 25])
      expect(depth.call(5)).to eq([25, 50])
      expect(depth.call(19)).to eq([25, 50])
      expect(depth.call(20)).to eq([50, 100])
    end

    it "bound --all to a positive number of children" do
      expect(QualityControlDials::SWEEP_MAX_PARALLEL).to be_a(Integer).and be_positive
    end

    it "say how the loop opens a PR" do
      expect(QualityControlDials::BRANCH_PREFIX).to end_with("/")
      expect(QualityControlDials::DRAFT_ONLY).to be(true).or be(false)
      expect(QualityControlDials::AUTO_MERGE).to be(true).or be(false)
      expect(QualityControlDials::PR_CAP_PER_DAY).to be_a(Integer).and be >= 0
      expect(QualityControlDials::LIVENESS_FALLBACK_SECONDS).to be_positive
    end
  end
end
