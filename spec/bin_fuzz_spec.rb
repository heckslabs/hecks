require "spec_helper"
require "hecks/fuzzing"

# bin/fuzz runs a full sweep and exits when loaded, so `bin_fuzz_methods`
# evaluates only its method definitions (before the CLI preamble) into a throwaway module.
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
    # key? first, never `||`: a falsy "args" value must still win over the other spelling.
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
    # `outcome` always reproduces, so only whether accepted drops accumulate is tested.
    def always_reproduces(fuzz)
      fuzz.define_singleton_method(:outcome) { |_domain, _steps, _adapter = :memory| [:crash, "boom"] }
    end

    it "accumulates every accepted drop instead of reverting earlier ones" do
      fuzz = bin_fuzz_methods
      always_reproduces(fuzz)

      steps = [{ "verb" => "Some.Verb", "args" => { "a" => 1, "b" => 2 } }]
      shrunk = fuzz.shrink_arguments("unused-domain", steps, "crash: boom")

      # Both are droppable, so neither should survive; a shrinker that fails to
      # accumulate drops would keep the first one.
      expect(shrunk.first["args"]).to eq({})
    end

    it "still reverts a drop the domain genuinely needs, mid-accumulation" do
      fuzz = bin_fuzz_methods
      # "a" is droppable; dropping "b" changes the outcome, so it must be restored.
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
