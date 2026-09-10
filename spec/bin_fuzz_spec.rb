require "spec_helper"
require "hecks/fuzzing"

# M24 — `bin/fuzz` is a CLI script, not a lib/ file: `shrink_arguments`,
# `outcome`, and friends are plain top-level methods, and the file's own
# tail (ARGV parsing, a real domain sweep, `exit`) runs unconditionally
# the moment the file loads — `require`/`load`ing it directly would run
# a full fuzz sweep and kill the spec process. `bin_fuzz_methods` slices
# out ONLY the method definitions (everything before the CLI's own
# arg-parsing preamble) and evaluates them into a private, throwaway
# module instead, so a method under test can be called directly.
RSpec.describe "bin/fuzz" do
  def bin_fuzz_methods
    path = File.join(InMemoryDomain::ROOT, "bin/fuzz")
    source = File.read(path)
    boundary = source.index("\nseeds = 20\n")
    raise "bin/fuzz's own CLI preamble moved — update this spec's slice point" unless boundary

    sandbox = Module.new
    sandbox.module_eval(source[0...boundary], path, 1)
    Object.new.extend(sandbox)
  end

  describe "#args_of" do
    # key? first, never `||` — a step's own "args" spelling must win even
    # when it holds a value that looks falsy, rather than silently
    # substituting whatever the OTHER spelling happens to hold.
    it "returns the string-keyed value even when it is literally `false`, rather than falling to the symbol spelling" do
      fuzz = bin_fuzz_methods

      expect(fuzz.args_of({ "args" => false, args: { "a" => 1 } })).to be(false)
    end

    it "falls to the symbol spelling only when the string key is genuinely absent" do
      fuzz = bin_fuzz_methods

      expect(fuzz.args_of({ args: { "a" => 1 } })).to eq({ "a" => 1 })
    end
  end

  describe "#shrink_arguments" do
    # `outcome` is stubbed to reproduce the SAME finding unconditionally,
    # regardless of which arguments survive — isolating exactly the bug
    # this property is checked against: whether ACCEPTED drops accumulate,
    # with no other consideration (which argument is "really" relevant)
    # confounding the result.
    def always_reproduces(fuzz)
      fuzz.define_singleton_method(:outcome) { |_domain, _steps, _adapter = :memory| [:crash, "boom"] }
    end

    it "accumulates every accepted drop instead of reverting earlier ones" do
      fuzz = bin_fuzz_methods
      always_reproduces(fuzz)

      steps = [{ "verb" => "Some.Verb", "args" => { "a" => 1, "b" => 2 } }]
      shrunk = fuzz.shrink_arguments("unused-domain", steps, "crash: boom")

      # BOTH "a" and "b" are independently droppable (the stub reproduces
      # no matter what), so the fully-shrunk result should carry NEITHER —
      # a shrinker whose accepted drops don't accumulate would instead end
      # up with only the LAST one dropped and the first one reverted.
      expect(shrunk.first["args"]).to eq({})
    end

    it "still reverts a drop the domain genuinely needs, mid-accumulation" do
      fuzz = bin_fuzz_methods
      # "a" is droppable ; "b" is NOT — dropping it changes the outcome
      # (no longer reproduces), so it must come straight back, the same
      # way `StepBuilder#malform`'s own doc names an argument the domain
      # requires as changing the refusal and un-reverting itself.
      fuzz.define_singleton_method(:outcome) do |_domain, steps, _adapter = :memory|
        steps.first["args"].key?("b") ? [:crash, "boom"] : [:clean, nil]
      end

      steps = [{ "verb" => "Some.Verb", "args" => { "a" => 1, "b" => 2 } }]
      shrunk = fuzz.shrink_arguments("unused-domain", steps, "crash: boom")

      expect(shrunk.first["args"]).to eq({ "b" => 2 })
    end

    it "accumulates drops across more than two arguments" do
      fuzz = bin_fuzz_methods
      always_reproduces(fuzz)

      steps = [{ "verb" => "Some.Verb", "args" => { "a" => 1, "b" => 2, "c" => 3, "d" => 4 } }]
      shrunk = fuzz.shrink_arguments("unused-domain", steps, "crash: boom")

      expect(shrunk.first["args"]).to eq({})
    end
  end

  # KNOWN_FUZZ_FINDINGS/#known_finding? — the same "names nothing the
  # checker no longer finds" discipline `spec/model_check_spec.rb` already
  # holds `Bluebook::ModelCheck::ALLOWED_FINDINGS` to, applied to this
  # file's own allowlist: an entry here is honest only while the finding
  # it excuses is STILL a real, currently-reproducing one — the moment
  # `mutations_match_recompute`'s own underlying bug (hecks_qa BUG#4) is
  # actually fixed, seed 2 below stops producing this violation and this
  # spec starts failing, which is the signal to delete the entry.
  describe "KNOWN_FUZZ_FINDINGS" do
    NESTED_PIECES_DOMAIN = File.join(InMemoryDomain::ROOT, "qa/stress_domains/nested_pieces").freeze

    # bin/fuzz's own defaults (seeds 20, steps 30) — seed 2 is one of the
    # two (2 and 16) the real CI run on PR #527 actually hit; steps must
    # match bin/fuzz's own default because SequenceGenerator's draw is
    # seed-AND-length-sensitive.
    def nested_pieces_mutation_violation
      steps = Hecks::Fuzzing::SequenceGenerator.generate(NESTED_PIECES_DOMAIN, seed: 2, steps: 30, adapter: :memory)
      history = Hecks::Fuzzing::Replay.call(NESTED_PIECES_DOMAIN, steps, adapter: :memory)
      violations = Hecks::Fuzzing::Properties.check(history).reject { |_, result| result == true }
      violations[:mutations_match_recompute]
    end

    it "still reproduces the exact BUG#4 shape the nested_pieces allowlist entry excuses" do
      message = nested_pieces_mutation_violation
      expect(message).not_to be_nil, "seed 2 no longer trips mutations_match_recompute at all — " \
                                     "if BUG#4 was fixed, delete the nested_pieces entry from KNOWN_FUZZ_FINDINGS"

      fuzz = bin_fuzz_methods
      failure = { signature: "property_violation: mutations_match_recompute",
                  message:   "mutations_match_recompute: #{message}" }
      still_known = fuzz.known_finding?("nested_pieces", failure)

      expect(still_known).to be(true), "seed 2's own violation no longer matches KNOWN_FUZZ_FINDINGS' exact " \
                                       "shape (#{message.inspect}) — either BUG#4 changed shape or was fixed " \
                                       "differently; update or delete the nested_pieces entry"
    end

    it "does not excuse a different construct hitting the same property" do
      fuzz = bin_fuzz_methods
      different_construct = {
        signature: "property_violation: mutations_match_recompute",
        message:   "mutations_match_recompute: NestedPieces::Workspace.AddBoard — append on boards — " \
                   "recomputing independently gives [{:number=>3}], but the real dispatch left " \
                   "[{:number=>{:value=>3}}]"
      }

      expect(fuzz.known_finding?("nested_pieces", different_construct)).to be(false)
    end

    it "does not excuse the known shape riding alongside a second, unrelated offender" do
      fuzz = bin_fuzz_methods
      known_message = "mutations_match_recompute: NestedPieces::Workspace.Board.AddCard — append on cards — " \
                      "recomputing independently gives [{:sequence=>821}], but the real dispatch left " \
                      "[{:sequence=>{:value=>821}}]"
      unrelated = "mutations_match_recompute: NestedPieces::Workspace.Board.Label — set on label — " \
                  "recomputing independently gives \"x\", but the real dispatch left \"y\""
      compound = { signature: "property_violation: mutations_match_recompute",
                   message:   "#{known_message}; #{unrelated}" }

      expect(fuzz.known_finding?("nested_pieces", compound)).to be(false)
    end

    it "does not excuse any other domain" do
      fuzz = bin_fuzz_methods
      elsewhere = { signature: "property_violation: mutations_match_recompute",
                    message:   "mutations_match_recompute: NestedPieces::Workspace.Board.AddCard — append on " \
                               "cards — recomputing independently gives [{:sequence=>821}], but the real " \
                               "dispatch left [{:sequence=>{:value=>821}}]" }

      expect(fuzz.known_finding?("some_other_domain", elsewhere)).to be(false)
    end
  end
end
