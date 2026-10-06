require "spec_helper"
require "json"
require "hecks/fuzzing"

# The caller draw, dry-run draw and late-stage precedence pairs, on real generated sequences.
# Each shape's fingerprint is in the step's own `role`/`actor_id`/`dry_run` keys.
RSpec.describe Hecks::Fuzzing::SequenceGenerator, :aggregate_failures do
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

  def banking_steps(seeds, **options)
    (1..seeds).flat_map { |seed| described_class.generate(ROLE_BANKING, seed: seed, steps: 40, **options) }
  end

  def banking_bluebooks = Hecks::Fuzzing::Replay.call(ROLE_BANKING, [])[:bluebooks]

  def adversarial_with?(step, key, value)
    (step["adversarial"] || []).any? { |m| m[key] == value }
  end

  # Walks a step's verb ("Domain::Aggregate.Entity.Command") down to the command it names.
  def command_for(bluebooks, verb)
    domain, rest = verb.split("::", 2)
    aggregate, *path = rest.split(".")
    owner = bluebooks[domain].aggregate(aggregate)
    path[0...-1].each { |name| owner = owner.entities.find { |e| e.hecks_name == name } }
    owner.command(path.last)
  end

  describe "the seed contract" do
    # One seed's script, generated twice with every draw on and required to match.
    def stable_script(seed)
      pair = Array.new(2) do
        described_class.generate(ROLE_BANKING, seed: seed, steps: 40, adversarial: 0.5, role_draw: 1.0, dry_run: 0.3)
      end
      expect(pair.first).to eq(pair.last), "banking seed #{seed} diverged between two identical calls"
      pair.first
    end

    def steps_with(scripts, key) = scripts.sum { |script| script.count { |step| step.key?(key) } }

    it "is byte-identical with both draws at zero, and carries no role/actor_id/dry_run keys" do
      plain = described_class.generate(ROLE_BANKING, seed: 3, steps: 25)
      off   = described_class.generate(ROLE_BANKING, seed: 3, steps: 25, role_draw: 0.0, dry_run: 0.0)

      expect(off).to eq(plain)
      expect(plain.none? { |s| s.key?("role") || s.key?("actor_id") || s.key?("dry_run") }).to be(true)
    end

    it "reproduces the same script for the same seed with every draw on" do
      scripts = (1..4).map { |seed| stable_script(seed) }

      # Counted across seeds: a role-heavy sequence refuses more and reaches less state,
      # so a draw is not guaranteed per seed.
      expect(steps_with(scripts, "role")).to be_positive
      expect(steps_with(scripts, "dry_run")).to be_positive
    end
  end

  describe "the caller draw (ANGLE-5)" do
    def expect_matching_shape(shapes)
      shapes.fetch("matching").each do |step, note|
        expect(step["role"]).to eq(note["gated_role"])
        expect(step).not_to have_key("actor_id")
      end
    end

    def expect_role_shapes(shapes)
      expect_matching_shape(shapes)
      shapes.fetch("mismatched").each { |step, note| expect(step["role"]).not_to eq(note["gated_role"]) }
      shapes.fetch("absent_on_gated").map(&:first).each { |step| expect(step).not_to have_key("role") }
    end

    def expect_unknown_actor_shape(shapes)
      shapes.fetch("actor_unknown").each do |step, note|
        expect(step["role"]).to eq(note["gated_role"])
        expect(step["actor_id"]).to be_a(String)
      end
    end

    def expect_actor_shapes(shapes)
      expect_unknown_actor_shape(shapes)
      shapes.fetch("actor_known").map(&:first).each { |step| expect(step["actor_id"]).to be_a(String) }
    end

    # Only grants whose `role_name` the argument layer left alone: a
    # `refusal_precedence`/`omit_mapped_argument` mutation can corrupt or drop it.
    def untouched_grants(steps, grant_verbs)
      steps.select do |s|
        grant_verbs.include?(s["verb"]) &&
          (s["adversarial"] || []).none? { |m| m.value?("role_name") }
      end
    end

    # The grant verb comes from the loaded authorization provider, not a constant.
    def grant_verbs_of(bluebooks) = bluebooks.values.filter_map { |b| b.provided_verb("authorization", :grant) }

    def declared_roles(bluebooks)
      bluebooks.values.flat_map { |b| b.aggregates.flat_map { |a| a.commands.map(&:role) } }.compact.map(&:to_s)
    end

    it "produces every shape on banking, with the fingerprint in the step's own keys" do
      pairs  = notes_over(ROLE_BANKING, seeds: 16, mutation: "caller_role", adversarial: 0.3, role_draw: 1.0)
      shapes = pairs.group_by { |_, note| note["shape"] }

      expect(shapes.keys).to match_array(described_class::CALLER_SHAPES)
      expect_role_shapes(shapes)
      expect_actor_shapes(shapes)
    end

    it "draws only on a role-gated command — every drawn step's verb declares a role" do
      bluebooks = banking_bluebooks
      drawn = banking_steps(6, role_draw: 1.0).select { |s| adversarial_with?(s, "mutation", "caller_role") }

      expect(drawn).not_to be_empty
      drawn.each { |step| expect(command_for(bluebooks, step["verb"]).role.to_s).not_to be_empty }
    end

    it "finds the grant verb through the authorization provider" do
      expect(grant_verbs_of(banking_bluebooks)).to eq(["Governance::RoleAssignment.Assign"])
    end

    it "steers a grant at a declared role, so actor_known can reach holds_role?'s authorized branch for real" do
      bluebooks = banking_bluebooks
      grants = untouched_grants(banking_steps(16, adversarial: 0.3, role_draw: 1.0), grant_verbs_of(bluebooks))

      expect(grants).not_to be_empty
      grants.each { |s| expect(declared_roles(bluebooks)).to include(s["args"]["role_name"]["value"]) }
    end

    context "with a mismatched caller on replay" do
      before do
        steps = banking_steps(6, role_draw: 1.0)
        @mismatched = steps.select { |s| adversarial_with?(s, "shape", "mismatched") }
        @history = Hecks::Fuzzing::Replay.call(ROLE_BANKING, @mismatched)
        @kinds = @history[:refusals].map { |r| r[:kind].split("::").last }.uniq
      end

      it "never lands one — every one is refused and no event is recorded" do
        expect(@mismatched).not_to be_empty
        expect(@history[:refusals].size).to eq(@mismatched.size)
        expect(@history[:events]).to be_empty
      end

      # The only refusals ahead of Unauthorized are the argument-gate stages
      # `DISPATCH_ORDER` places before `refuse_role_mismatch`.
      it "binds the SAME caller — it is Unauthorized past the argument gate" do
        expect(@kinds).to include("Unauthorized")
        expect(@kinds - %w[Unauthorized UnknownArgument AbsentArgument TypeMismatch InvariantViolation]).to be_empty
      end
    end

    it "draws nothing on a domain with no role-gated command at all" do
      steps = (1..4).flat_map { |seed| described_class.generate(ROLE_CHESS, seed: seed, steps: 25, role_draw: 1.0) }
      expect(steps.none? { |s| s.key?("role") }).to be(true)
    end
  end

  describe "the dry-run draw" do
    def writing_dry_run_history
      { dry_run_traces: [{ verb: "Pizzas::Order.CreatePizza", ok: true,
                           before: { instances: {}, events: 0 },
                           after:  { instances: { "Pizzas::Order#x" => {} }, events: 1 } }] }
    end

    context "with half the pizza steps drawn as dry runs" do
      before do
        @steps = described_class.generate(ROLE_PIZZAS, seed: 4, steps: 30, dry_run: 0.5)
        @dry = @steps.select { |s| s.key?("dry_run") }
        @history = Hecks::Fuzzing::Replay.call(ROLE_PIZZAS, @steps)
      end

      it "turns a command step into a dry_run step" do
        expect(@dry).not_to be_empty
        @dry.each { |s| expect(s).not_to have_key("verb") }
      end

      # `dry_runs` keeps exactly the shape the Rust binary answers, so the conformance
      # comparison sees no extra key; `before:`/`after:` live in `dry_run_traces`.
      it "replays them compared by verb/ok" do
        expect(@history[:dry_runs].size).to eq(@dry.size)
        expect(@history[:dry_runs]).to all(include(:verb, :ok))
        expect(@history[:dry_runs]).to all(satisfy { |e| !e.key?(:before) && !e.key?(:after) })
      end

      it "replays them with no trace" do
        expect(Hecks::Fuzzing::Properties.dry_runs_leave_no_trace(@history)).to be(true)
        expect(@history[:dry_run_traces].size).to eq(@dry.size)
        expect(@history[:dry_run_traces]).to all(include(:verb, :ok, :before, :after))
      end
    end

    it "dry_runs_leave_no_trace names a hypothetical that wrote something" do
      result = Hecks::Fuzzing::Properties.dry_runs_leave_no_trace(writing_dry_run_history)

      expect(result).to be_a(String)
      expect(result).to include("CreatePizza", "events 0 -> 1", "instances changed")
    end

    it "dry_runs_leave_no_trace passes an entry with no snapshots through — no claim, no finding" do
      expect(Hecks::Fuzzing::Properties.dry_runs_leave_no_trace({ dry_run_traces: [{ verb: "x", ok: false }] })).to be(true)
    end
  end

  describe "the late-stage precedence pairs" do
    def precedence_pairs(seeds) = notes_over(ROLE_BANKING, seeds: seeds, mutation: "refusal_precedence", adversarial: 1.0)

    it "produces nonexistent and role pairings on banking, never an empty shape" do
      shapes = precedence_pairs(24).map { |_, note| note["shape"] }.uniq

      expect(shapes).to include("nonexistent+unknown", "mismatch+nonexistent")
      expect(shapes.any? { |s| s.include?("role") }).to be(true)
      expect(shapes).not_to include("")
    end

    it "records each pairing in the note" do
      precedence_pairs(24).each do |step, note|
        expect(step).to have_key("role") if note.key?("role")
        expect(step["args"]).to have_key(note["nonexistent"]) if note.key?("nonexistent")
      end
    end

    # `lifecycle+mismatch` needs a transition-guarded, non-creating command, which is rare
    # at `adversarial: 1.0` (little state exists), so it is pinned against a hand-built entry.
    context "with a transition-guarded, non-creating command with flat addressing" do
      def shapes_for(args, entry) = @generator.send(:precedence_shapes_for, args, entry)

      before do
        bluebooks = banking_bluebooks
        # Needs an argument to mismatch: `Transfer.Settle` is guarded but takes none,
        # and `lifecycle` pairs only with `mismatch`.
        aggregate, @command = bluebooks["Banking"].aggregates.flat_map { |a| a.commands.map { |c| [a, c] } }.find do |a, c|
          !c.creates? && c.from && c.attributes.reject(&:list?).any? && a.lifecycle
        end
        @generator = described_class.new(ROLE_BANKING, seed: 1, steps: 1, adversarial: 1.0)
        @entry = { verb: "Banking::#{aggregate.hecks_name}.#{@command.hecks_name}", command: @command, aggregate: aggregate }
        @args = @command.attributes.to_h { |a| [a.name.to_s, "x"] }.merge("id" => "t1")
        @transfer = bluebooks["Banking"].aggregate("Transfer")
      end

      it "exists in the banking domain" do
        expect(@command).not_to be_nil
      end

      it "offers lifecycle+mismatch exactly to it" do
        expect(shapes_for(@args, @entry)).to include("lifecycle+mismatch", "nonexistent+unknown")
      end

      it "withholds them once an argument is a stand-in" do
        expect(shapes_for(@args.merge("to" => {}), @entry)).not_to include("lifecycle+mismatch", "nonexistent+unknown")
      end

      it "withholds them from a creating command" do
        creating = { verb: "Banking::Transfer.Request", command: @transfer.command("Request"), aggregate: @transfer }

        expect(shapes_for({ "id" => "t1" }, creating).grep(/lifecycle|nonexistent/)).to be_empty
      end
    end

    it "never offers a late-stage part to a creating command" do
      bluebooks = banking_bluebooks
      late = precedence_pairs(12).select { |_, note| note.key?("nonexistent") || note.key?("lifecycle") }

      late.map(&:first).each { |step| expect(command_for(bluebooks, step["verb"]).creates?).to be(false) }
    end
  end
end
