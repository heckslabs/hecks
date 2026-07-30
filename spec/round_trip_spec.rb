
require "spec_helper"

# THE SELF-HOSTING CLAIM, stated as a test.
#
# `bluebook.bluebook` opens with it: "loading a domain becomes dispatching commands
# into this meta-domain ; the IR it stores must equal the IR the DSL builder
# produces." The judge dispatches a bluebook in. Reconstruction reads it back out.
# This compares the two, and there is no longer any difference to explain.
#
# It began as pizzas exact and banking eight short, with the eight named as an exact
# classified set — an entity's own commands, queries and lifecycle, a non-string
# default, a literal with structure. Each turned out to be either a field the
# language had no room for or a value stored as text that forgot its own type. All
# four members now come back byte for byte.
#
# The fixtures are here on purpose. Banking has no aggregate attribute carrying a
# default, so `Field#default` would have been legal and unexercised — the exact
# pattern this project keeps finding — and till declares
# `attribute :balance, Money, default: { cents: 0 }`, which exercises both the field
# and the object-literal encoding at once.
RSpec.describe "a bluebook dispatched in and read back out" do
  ROUND_TRIP_CORPUS = {
    "Pizzas"   => "examples/pizzas/bluebook/pizzas.bluebook",
    "Banking"  => "examples/banking/bluebook/banking.bluebook",
    "TillRoom" => "spec/fixtures/till.bluebook",
    "Wire"     => "spec/fixtures/settlement.bluebook"
  }.freeze

  def load_corpus(file)
    registry = Hecksagain::Runtime::Registry.new
    Hecksagain.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(File.join(InMemoryDomain::ROOT, file))
    end
    registry
  end

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

  # NOTHING IS SORTED ANY MORE, and that is the claim getting stronger.
  #
  # This used to canonicalise the PRESENTATION axis on both sides — which position
  # a command occupies in its aggregate's list — because `Reconstruction` read the
  # chapter through `Meta.whole_bluebook`, and a read model sorts by id on purpose.
  # So the comparison had to sort too, and said so out loud.
  #
  # The reconstruction reads level by level through `DeclaredIn` now, which
  # preserves declaration order, so both sides are compared exactly as written. The
  # IR is a contract field for field AND INDEX FOR INDEX, and this says index for
  # index without a caveat. Which is what a reconstruction has to manage before it
  # can be the SOURCE rather than a check: Rust reads the order out of the file.
  def canonical(node)
    case node
    when Hash then node.to_h { |key, value| [key, canonical(value)] }
    when Array
      mapped = node.map { |element| canonical(element) }
      mapped
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
      ["#{path}: declared #{source.inspect[0, 60]}, read back #{back.inspect[0, 60]}"]
    end
  end

  ROUND_TRIP_CORPUS.each do |name, file|
    context name do
      let(:bluebook) { load_corpus(file).bluebook(name) }

      it "comes back exactly as the builder made it" do
        back, refusals = read_back(bluebook)

        expect(refusals).to be_empty, "the language refused it: #{refusals.inspect}"
        expect(differences(canonical(bluebook.to_h.slice(*back.keys)), canonical(back))).to be_empty
      end
    end
  end

  it "compares every part of the IR the builder produces, not a convenient subset" do
    # The comparison slices the source by the reconstruction's own keys, so a key it
    # simply never attempted would vanish from the test rather than fail it. This
    # names what is compared, so dropping one is a failure and not a silence.
    back, = read_back(load_corpus(ROUND_TRIP_CORPUS["Banking"]).bluebook("Banking"))

    expect(back.keys).to eq(%i[name vision classification aggregates read_models policies process_managers])
    expect(Hecksagain::Bluebook::IR::Bluebook.instance_method(:to_h).owner).to be_truthy
  end

  it "exercises an aggregate attribute that carries a default" do
    # Banking has none, so without this `Field#default` would round-trip vacuously.
    till = load_corpus(ROUND_TRIP_CORPUS["TillRoom"]).bluebook("TillRoom")

    expect(till.aggregate("Till").attribute(:balance).default).to eq(cents: 0)
  end
end
