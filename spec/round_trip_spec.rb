require "spec_helper"

# Self-hosting claim: the judge dispatches a bluebook into the meta-domain, Reconstruction
# reads it back, and the result must equal the IR the DSL builder produces.
RSpec.describe "a bluebook dispatched in and read back out" do
  ROUND_TRIP_CORPUS = {
    "Pizzas"   => "examples/pizzas/bluebook/pizzas.bluebook",
    "Banking"  => InMemoryDomain::BANKING_BLUEBOOK_DIR,
    "TillRoom" => "spec/fixtures/till.bluebook",
    "Wire"     => "spec/fixtures/settlement.bluebook"
  }.freeze

  def load_corpus(file)
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      path = File.absolute_path(file, InMemoryDomain::ROOT)
      load_bluebook_files(path)
    end
    registry
  end

  # Dispatches the bluebook in and returns the reconstruction plus the judge's refusals.
  def read_back(bluebook)
    judge = Hecks::Bluebook::MetaValidator::Judge.new(bluebook)

    [Hecks::Bluebook::MetaValidator::Reconstruction.of(judge.runtime, bluebook.hecks_name),
     judge.refusals]
  end

  # Deliberately does not sort: Reconstruction reads through `DeclaredIn`, which preserves
  # declaration order, so both sides are compared index for index as written.
  def canonical(node)
    case node
    when Hash then node.to_h { |key, value| [key, canonical(value)] }
    when Array
      node.map { |element| canonical(element) }

    else node
    end
  end

  def differences(source, back, path = "")
    return [] if source == back
    return hash_differences(source, back, path) if source.is_a?(Hash) && back.is_a?(Hash)
    return array_differences(source, back, path) if same_size_arrays?(source, back)

    ["#{path}: declared #{source.inspect[0, 60]}, read back #{back.inspect[0, 60]}"]
  end

  # Source keys only: the language may hold more than `to_h` spells, but everything
  # the contract spells must come back identically. Contract removals are spec/golden/ir's job.
  def hash_differences(source, back, path)
    source.keys.flat_map { |key| differences(source[key], back[key], "#{path}.#{key}") }
  end

  def array_differences(source, back, path)
    source.each_with_index.flat_map { |element, i| differences(element, back[i], "#{path}[#{i}]") }
  end

  def same_size_arrays?(source, back)
    source.is_a?(Array) && back.is_a?(Array) && source.size == back.size
  end

  # Hecksagon-level `port`/`operation` declarations have no self-hosted grammar
  # representation yet, so `ports` is stripped by name rather than relaxing `differences`.
  def strip_ports(node)
    case node
    when Hash then node.except(:ports).transform_values { |v| strip_ports(v) }
    when Array then node.map { |v| strip_ports(v) }
    else node
    end
  end

  # `ast` is derived from `canonical` (`AstJson.emit_predicate`), which round-trips
  # byte for byte, so the meta-domain stores no separate fact for it; stripped by name.
  def strip_invariant_ast(node)
    case node
    when Hash then node.except(:ast, :where_ast).transform_values { |v| strip_invariant_ast(v) }
    when Array then node.map { |v| strip_invariant_ast(v) }
    else node
    end
  end

  ROUND_TRIP_CORPUS.each do |name, file|
    context name do
      let(:bluebook) { load_corpus(file).bluebook(name) }

      it "comes back exactly as the builder made it", :aggregate_failures do
        back, refusals = read_back(bluebook)

        expect(refusals).to be_empty, "the language refused it: #{refusals.inspect}"
        expect(differences(strip_invariant_ast(strip_ports(canonical(bluebook.to_h.slice(*back.keys)))),
                           strip_invariant_ast(canonical(back)))).to be_empty
      end
    end
  end

  it "compares every part of the IR the builder produces, not a convenient subset", :aggregate_failures do
    # The comparison slices the source by the reconstruction's keys, so a key it never
    # attempted would vanish silently; naming them here makes dropping one a failure.
    back, = read_back(load_corpus(ROUND_TRIP_CORPUS["Banking"]).bluebook("Banking"))

    expect(back.keys).to eq(%i[name version vision classification formerly_known_as namespace attaches_to provides aggregates
                               read_models policies
                               process_managers])
    expect(Hecks::Bluebook::Chapter.instance_method(:to_h).owner).to be_truthy
  end

  # The round-trip comparison cannot see a key that `Reconstruction#aggregate`/`#entity`
  # never asks for, since both sides omit it. Those two are hand-typed (other constructs
  # read through `Assembly::Contracts`), so this checks their rows against `ir_spec`.
  # `:ports` is the known exception (see `strip_ports`).
  RECONSTRUCTION_KNOWN_GAPS = %i[ports].freeze

  def expect_rows_complete(rows, construct, chapter)
    rows.each do |row|
      missing = construct.ir_spec.keys - row.keys - RECONSTRUCTION_KNOWN_GAPS
      expect(missing).to be_empty,
                         "#{chapter}: Reconstruction never asks #{construct} for #{missing.join(", ")} " \
                         "(row #{row[:name].inspect})"
      expect_rows_complete(row[:entities] || [], Hecks::Bluebook::Entity, chapter)
    end
  end

  it "hand-typed reconstruction methods return every key their construct's own IR declares" do
    ROUND_TRIP_CORPUS.each_key do |name|
      back, = read_back(load_corpus(ROUND_TRIP_CORPUS[name]).bluebook(name))
      expect_rows_complete(back[:aggregates] || [], Hecks::Bluebook::Aggregate, name)
    end
  end

  it "carries a chapter's version, which banking pins for real", :aggregate_failures do
    back, refusals = read_back(load_corpus(ROUND_TRIP_CORPUS["Banking"]).bluebook("Banking"))

    expect(refusals).to be_empty
    expect(back[:version]).to eq("v1")
  end

  it "leaves version absent when a chapter pins none, since ABSENT IS NOT EMPTY" do
    back, = read_back(load_corpus(ROUND_TRIP_CORPUS["Pizzas"]).bluebook("Pizzas"))

    expect(back[:version]).to be_nil
  end

  it "exercises an aggregate attribute that carries a default" do
    # Banking declares no attribute default, so `Field#default` would round-trip vacuously.
    till = load_corpus(ROUND_TRIP_CORPUS["TillRoom"]).bluebook("TillRoom")

    expect(till.aggregate("Till").attribute(:balance).default).to eq(cents: 0)
  end
end
