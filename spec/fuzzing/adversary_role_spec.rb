require "spec_helper"
require "json"
require "hecks/fuzzing"

# THE CALLER DRAW, THE DRY-RUN DRAW, AND THE LATE-STAGE PRECEDENCE PAIRS
# (items 2, 3 and 5 of the detection plan; ANGLE-5) — checked against
# REAL generated sequences the way `adversary_spec.rb` checks the
# argument mutations: the seed contract holds (same seed, same script;
# off is byte-identical and carries no metadata), every shape actually
# appears, and each shape's fingerprint is IN the step's own keys —
# `role`/`actor_id`/`dry_run` — which is what both `Fuzzing::Replay`
# and `kernel/cli.rs` read, so the generator's inline dispatch and both
# replays bind the same caller.
RSpec.describe Hecks::Fuzzing::SequenceGenerator do
  ROLE_BANKING = File.join(InMemoryDomain::ROOT, "examples/banking")
  ROLE_PIZZAS  = File.join(InMemoryDomain::ROOT, "examples/pizzas")
  ROLE_CHESS   = File.join(InMemoryDomain::ROOT, "examples/chess")

  def notes_over(domain, seeds:, mutation:, **options)
    (1..seeds).flat_map do |seed|
      described_class.generate(domain, seed: seed, steps: 40, **options).flat_map do |step|
        (step["adversarial"] || []).select { |m| m["mutation"] == mutation }.map { |m| [step, m] }
      end
    end
  end

  describe "the seed contract" do
    it "is byte-identical with both draws at zero, and carries no role/actor_id/dry_run keys" do
      plain = described_class.generate(ROLE_BANKING, seed: 3, steps: 25)
      off   = described_class.generate(ROLE_BANKING, seed: 3, steps: 25, role_draw: 0.0, dry_run: 0.0)

      expect(off).to eq(plain)
      expect(plain.none? { |s| s.key?("role") || s.key?("actor_id") || s.key?("dry_run") }).to be(true)
    end

    it "reproduces the same script for the same seed with every draw on" do
      scripts = (1..4).map do |seed|
        pair = Array.new(2) do
          described_class.generate(ROLE_BANKING, seed: seed, steps: 40, adversarial: 0.5, role_draw: 1.0, dry_run: 0.3)
        end
        expect(pair.first).to eq(pair.last), "banking seed #{seed} diverged between two identical calls"
        pair.first
      end

      # Counted across seeds rather than per seed: a role-heavy sequence
      # refuses more, reaches less state, and can land on a handful of
      # command steps — the draws are real, not guaranteed per seed.
      expect(scripts.sum { |s| s.count { |step| step.key?("role") } }).to be_positive
      expect(scripts.sum { |s| s.count { |step| step.key?("dry_run") } }).to be_positive
    end

    it "refuses a draw fraction outside 0..1, naming the option" do
      expect { described_class.generate(ROLE_PIZZAS, seed: 1, steps: 5, role_draw: 1.5) }
        .to raise_error(ArgumentError, /role_draw/)
      expect { described_class.generate(ROLE_PIZZAS, seed: 1, steps: 5, dry_run: -0.1) }
        .to raise_error(ArgumentError, /dry_run/)
    end
  end

  describe "the caller draw (ANGLE-5)" do
    it "produces every shape on banking, with the fingerprint in the step's own keys" do
      pairs  = notes_over(ROLE_BANKING, seeds: 16, mutation: "caller_role", adversarial: 0.3, role_draw: 1.0)
      shapes = pairs.group_by { |_, note| note["shape"] }

      expect(shapes.keys).to match_array(described_class::CALLER_SHAPES)

      shapes.fetch("matching").each do |step, note|
        expect(step["role"]).to eq(note["gated_role"])
        expect(step).not_to have_key("actor_id")
      end
      shapes.fetch("mismatched").each { |step, note| expect(step["role"]).not_to eq(note["gated_role"]) }
      shapes.fetch("absent_on_gated").map(&:first).each { |step| expect(step).not_to have_key("role") }
      shapes.fetch("actor_unknown").each do |step, note|
        expect(step["role"]).to eq(note["gated_role"])
        expect(step["actor_id"]).to be_a(String)
      end
      shapes.fetch("actor_known").map(&:first).each { |step| expect(step["actor_id"]).to be_a(String) }
    end

    it "draws only on a role-gated command — every drawn step's verb declares a role" do
      steps = (1..6).flat_map { |seed| described_class.generate(ROLE_BANKING, seed: seed, steps: 40, role_draw: 1.0) }
      bluebooks = Hecks::Fuzzing::Replay.call(ROLE_BANKING, [])[:bluebooks]

      drawn = steps.select { |s| (s["adversarial"] || []).any? { |m| m["mutation"] == "caller_role" } }
      expect(drawn).not_to be_empty
      drawn.each do |step|
        domain, rest = step["verb"].split("::", 2)
        aggregate, *path = rest.split(".")
        owner = bluebooks[domain].aggregate(aggregate)
        path[0...-1].each { |name| owner = owner.entities.find { |e| e.hecks_name == name } }
        expect(owner.command(path.last).role.to_s).not_to be_empty
      end
    end

    it "steers a grant at a declared role, so actor_known can reach holds_role?'s authorized branch for real" do
      steps = (1..16).flat_map do |seed|
        described_class.generate(ROLE_BANKING, seed: seed, steps: 40, adversarial: 0.3, role_draw: 1.0)
      end
      # Only grants whose `role_name` the argument layer left alone — a
      # `refusal_precedence`/`omit_mapped_argument` mutation can corrupt or
      # drop it AFTER the steer (that is exactly its job); a `caller_role`
      # note touches no argument at all.
      grants = steps.select do |s|
        s["verb"] == described_class::GRANT_VERB &&
          (s["adversarial"] || []).none? { |m| m.values.include?("role_name") }
      end
      expect(grants).not_to be_empty

      bluebooks = Hecks::Fuzzing::Replay.call(ROLE_BANKING, [])[:bluebooks]
      declared  = bluebooks.values.flat_map { |b| b.aggregates.flat_map { |a| a.commands.map(&:role) } }.compact.map(&:to_s)
      grants.each { |s| expect(declared).to include(s["args"]["role_name"]["value"]) }
    end

    it "binds the SAME caller on replay — a mismatched caller never lands, and is Unauthorized past the argument gate" do
      steps = (1..6).flat_map { |seed| described_class.generate(ROLE_BANKING, seed: seed, steps: 40, role_draw: 1.0) }
      mismatched = steps.select { |s| (s["adversarial"] || []).any? { |m| m["shape"] == "mismatched" } }
      expect(mismatched).not_to be_empty

      history = Hecks::Fuzzing::Replay.call(ROLE_BANKING, mismatched)
      # Every one refused (nothing a wrong hat dispatches ever lands), and
      # the ONLY refusals ahead of Unauthorized are the argument-gate
      # stages `DISPATCH_ORDER` places before `refuse_role_mismatch`.
      expect(history[:refusals].size).to eq(mismatched.size)
      expect(history[:events]).to be_empty
      kinds = history[:refusals].map { |r| r[:kind].split("::").last }.uniq
      expect(kinds).to include("Unauthorized")
      expect(kinds - %w[Unauthorized UnknownArgument AbsentArgument TypeMismatch InvariantViolation]).to be_empty
    end

    it "draws nothing on a domain with no role-gated command at all" do
      steps = (1..4).flat_map { |seed| described_class.generate(ROLE_CHESS, seed: seed, steps: 25, role_draw: 1.0) }
      expect(steps.none? { |s| s.key?("role") }).to be(true)
    end
  end

  describe "the dry-run draw" do
    it "turns a command step into a dry_run step, replayed with no trace and compared by verb/ok" do
      steps = described_class.generate(ROLE_PIZZAS, seed: 4, steps: 30, dry_run: 0.5)
      dry   = steps.select { |s| s.key?("dry_run") }
      expect(dry).not_to be_empty
      dry.each { |s| expect(s).not_to have_key("verb") }

      history = Hecks::Fuzzing::Replay.call(ROLE_PIZZAS, steps)
      expect(history[:dry_runs].size).to eq(dry.size)
      expect(Hecks::Fuzzing::Properties.dry_runs_leave_no_trace(history)).to be(true)
      expect(history[:dry_runs]).to all(include(:verb, :ok, :before, :after))
    end

    it "dry_runs_leave_no_trace names a hypothetical that wrote something" do
      history = { dry_runs: [{ verb: "Pizzas::Order.CreatePizza", ok: true,
                               before: { instances: {}, events: 0 },
                               after:  { instances: { "Pizzas::Order#x" => {} }, events: 1 } }] }
      result = Hecks::Fuzzing::Properties.dry_runs_leave_no_trace(history)
      expect(result).to be_a(String)
      expect(result).to include("CreatePizza", "events 0 -> 1", "instances changed")
    end

    it "dry_runs_leave_no_trace passes an entry with no snapshots through — no claim, no finding" do
      expect(Hecks::Fuzzing::Properties.dry_runs_leave_no_trace({ dry_runs: [{ verb: "x", ok: false }] })).to be(true)
    end
  end

  describe "the late-stage precedence pairs" do
    it "produces nonexistent and role pairings on banking, each recorded in the note, never an empty shape" do
      pairs  = notes_over(ROLE_BANKING, seeds: 24, mutation: "refusal_precedence", adversarial: 1.0)
      shapes = pairs.map { |_, note| note["shape"] }.uniq

      expect(shapes).to include("nonexistent+unknown", "mismatch+nonexistent")
      expect(shapes.any? { |s| s.include?("role") }).to be(true)
      expect(shapes).not_to include("")

      pairs.each do |step, note|
        expect(step).to have_key("role") if note.key?("role")
        expect(step["args"]).to have_key(note["nonexistent"]) if note.key?("nonexistent")
      end
    end

    # `lifecycle+mismatch` is offered only when a transition-guarded,
    # non-creating command is ADDRESSED — rare at `adversarial: 1.0`,
    # where nearly every creating step is mutated into a refusal and
    # little state exists to act on — so its applicability is pinned
    # directly against a hand-built entry rather than left to the draw.
    it "offers lifecycle+mismatch exactly to a transition-guarded, non-creating command with flat addressing" do
      bluebooks = Hecks::Fuzzing::Replay.call(ROLE_BANKING, [])[:bluebooks]
      # The first guarded, non-creating command that ALSO declares an
      # argument to mismatch (`Transfer.Settle` is guarded but takes none,
      # so `mismatch` has nothing to corrupt there — `lifecycle` pairs
      # only with `mismatch` by design).
      aggregate, command = bluebooks["Banking"].aggregates.flat_map { |a| a.commands.map { |c| [a, c] } }.find do |a, c|
        !c.creates? && c.from && c.attributes.reject(&:list?).any? && a.lifecycle
      end
      expect(command).not_to be_nil

      generator = described_class.new(ROLE_BANKING, seed: 1, steps: 1, adversarial: 1.0)
      entry     = { verb: "Banking::#{aggregate.hecks_name}.#{command.hecks_name}", command: command, aggregate: aggregate }
      args      = command.attributes.to_h { |a| [a.name.to_s, "x"] }.merge("id" => "t1")

      expect(generator.send(:precedence_shapes_for, args, entry)).to include("lifecycle+mismatch", "nonexistent+unknown")
      expect(generator.send(:precedence_shapes_for, args.merge("to" => {}), entry))
        .not_to include("lifecycle+mismatch", "nonexistent+unknown")

      transfer = bluebooks["Banking"].aggregate("Transfer")
      creating = { verb: "Banking::Transfer.Request", command: transfer.command("Request"), aggregate: transfer }
      expect(generator.send(:precedence_shapes_for, { "id" => "t1" }, creating).grep(/lifecycle|nonexistent/)).to be_empty
    end

    it "never offers a late-stage part to a creating command" do
      pairs = notes_over(ROLE_BANKING, seeds: 12, mutation: "refusal_precedence", adversarial: 1.0)
      bluebooks = Hecks::Fuzzing::Replay.call(ROLE_BANKING, [])[:bluebooks]

      pairs.each do |step, note|
        next unless note.key?("nonexistent") || note.key?("lifecycle")

        domain, rest = step["verb"].split("::", 2)
        aggregate, *path = rest.split(".")
        owner = bluebooks[domain].aggregate(aggregate)
        path[0...-1].each { |name| owner = owner.entities.find { |e| e.hecks_name == name } }
        expect(owner.command(path.last).creates?).to be(false)
      end
    end
  end
end
