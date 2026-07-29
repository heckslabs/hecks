
require "spec_helper"

# THE SELF-HOSTING CLAIM, stated as a test.
#
# `bluebook.bluebook` opens with it: "loading a domain becomes dispatching commands
# into this meta-domain ; the IR it stores must equal the IR the DSL builder
# produces." The judge dispatches a bluebook in. Reconstruction reads it back out.
# This compares the two.
#
# Pizzas comes back EXACTLY. Banking does not, and the differences are the point:
# they are the constructs the language does not yet hold, asserted as an exact set,
# so a NEW loss fails here and a CLOSED gap fails here too. A round trip that
# reports success while dropping a category is the failure the retired
# `experiment/replay.rb` was built to catch and did not.
RSpec.describe "a bluebook dispatched in and read back out" do
  def load_corpus(file, name)
    registry = Hecksagain::Runtime::Registry.new
    Hecksagain.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(File.join(InMemoryDomain::ROOT, file))
    end
    registry.bluebook(name)
  end

  def pizzas  = @pizzas  ||= load_corpus("examples/pizzas/bluebook/pizzas.bluebook", "Pizzas")
  def banking = @banking ||= load_corpus("examples/banking/bluebook/banking.bluebook", "Banking")

  # Dispatch it in and KEEP the records — the only difference between judging a
  # bluebook and holding one.
  def read_back(bluebook)
    runtime = Hecksagain::Bluebook::MetaValidator.fresh_runtime
    judge   = Hecksagain::Bluebook::MetaValidator::Judge.allocate
    judge.instance_variable_set(:@bluebook, bluebook)
    judge.instance_variable_set(:@refusals, [])
    judge.instance_variable_set(:@runtime, runtime)
    judge.instance_variable_set(
      :@plan,
      Hecksagain::Bluebook::MetaValidator::Plan.for(Hecksagain::Bluebook::MetaValidator.grammar_registry)
    )
    judge.send(:judge!)

    [Hecksagain::Bluebook::MetaValidator::Reconstruction.of(runtime, bluebook.name),
     judge.instance_variable_get(:@refusals)]
  end

  # Sort the PRESENTATION axis on both sides. Which position a command occupies in
  # its aggregate's list is read by nothing — see spec/executes_spec — so the read
  # side canonicalises it and the comparison has to say so out loud.
  def canonical(node)
    case node
    when Hash then node.to_h { |key, value| [key, canonical(value)] }
    when Array
      mapped = node.map { |element| canonical(element) }
      mapped.all? { |e| e.is_a?(Hash) && e[:name] } ? mapped.sort_by { |e| e[:name].to_s } : mapped
    else node
    end
  end

  def differences(source, back, path = "")
    return [] if source == back

    if source.is_a?(Hash) && back.is_a?(Hash)
      (source.keys | back.keys).flat_map { |key| differences(source[key], back[key], "#{path}.#{key}") }
    elsif source.is_a?(Array) && back.is_a?(Array) && source.size == back.size
      source.each_with_index.flat_map { |element, i| differences(element, back[i], "#{path}[#{i}]") }
    else
      [path]
    end
  end

  def compare(bluebook)
    back, refusals = read_back(bluebook)
    expect(refusals).to be_empty, "the language refused its own corpus: #{refusals.inspect}"

    differences(canonical(bluebook.to_h.slice(*back.keys)), canonical(back))
  end

  it "gives pizzas back exactly as the builder made it" do
    expect(compare(pizzas)).to be_empty
  end

  it "gives banking back apart from the constructs the language does not hold" do
    # Classified rather than listed by path, so the set survives banking gaining an
    # aggregate but not banking losing a field.
    kinds = compare(banking).map { |path| classify(path) }.tally

    expect(kinds).to eq(
      "an entity's own commands"   => 2,
      "an entity's own queries"    => 2,
      "an entity's own lifecycle"  => 2,
      "a non-string default"       => 1,
      "a literal that is not a scalar" => 1
    )
  end

  def classify(path)
    case path
    when /entities\[\d+\]\.commands\z/  then "an entity's own commands"
    when /entities\[\d+\]\.queries\z/   then "an entity's own queries"
    when /entities\[\d+\]\.lifecycle\z/ then "an entity's own lifecycle"
    when /\.default\z/                  then "a non-string default"
    when /source\.value\z/              then "a literal that is not a scalar"
    else "UNCLASSIFIED: #{path}"
    end
  end

  # Each of these is a sentence about the LANGUAGE, not about the reconstruction.
  #
  #   an entity's commands, queries and lifecycle — the language's Entity holds
  #     attributes and transitions, and an entity's own commands and queries have no
  #     verb at all. Banking's Withdrawal and LedgerEntry both declare them. The fix
  #     is Command and Query parented by Entity as well as by Aggregate, which the
  #     plan's containment tree would pick up for free.
  #
  #   a non-string default — ShapeField types `default` as String, so
  #     `default: 0.0` comes back "0.0". The language cannot say what type a default
  #     is, which is the same gap that makes a closed set's members all strings.
  #
  #   a literal that is not a scalar — `then_set :standing, to: { value: "good" }`
  #     stores the hash's inspect string. Change's `source` is a String, so a literal
  #     with structure loses it.
  it "names its gaps as facts about the language" do
    # Not a tautology: it fails the moment `classify` meets a path it has no sentence
    # for, which is exactly when somebody has introduced a loss nobody described.
    expect(compare(banking).map { |path| classify(path) }.grep(/UNCLASSIFIED/)).to be_empty
  end
end
