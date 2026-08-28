require "spec_helper"

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
end
