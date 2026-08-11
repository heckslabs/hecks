require "spec_helper"

# A PORT GENERATOR LEARNS BY EXAMPLE, and the examples are only as good
# as what they cover. Every real gap `bin/project_rust` hit while
# building the Rust port turned out to be a shape neither example
# domain exercised: composite identity that's actually dispatchable
# (SafeDepositBox's is blocked by entities), a multi-field closed set,
# a bare-but-declared identity component. Each one was a real Ruby
# mechanism, already correct, that simply hadn't been walked before.
#
# This is the gate against that happening again, silently. It reads
# Banking's own exported IR and checks it against the list of
# structural shapes a second runtime has to handle differently —
# not every DSL keyword (`spec/syntax_conformance_spec.rb` already
# holds those to the language), but every SHAPE OF IR a port's
# generator branches on. Both directions matter, the same as
# `ModelCheck::ALLOWED_FINDINGS`: a shape Banking stops exercising
# is a regression; a shape found missing has to be added to Banking,
# or named here as a deliberate, accepted gap — never silently absent.
RSpec.describe "the shapes a port generator needs Banking to exercise" do
  # Booted ONCE per file, not per example — every example here only reads
  # the exported IR back out (`ir`, `all_value_objects`, `all_attributes`
  # below), nothing dispatches a command, so a shared registry is safe.
  before(:context) do
    registry = Hecksagain::Runtime::Registry.new
    Hecksagain.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(File.join(InMemoryDomain::ROOT, "examples/banking/bluebook/banking.bluebook"))
    end
    @banking_registry = registry
  end

  let(:ir) { Hecksagain::Projector::Exporter.call(banking_registry).fetch("Banking") }
  let(:banking_registry) { @banking_registry }

  def all_value_objects
    ir[:aggregates].flat_map { |a| a[:value_objects] } +
      ir[:aggregates].flat_map { |a| a[:entities] }.flat_map { |e| e[:value_objects] || [] }
  end

  def all_attributes
    ir[:aggregates].flat_map { |a| a[:attributes] } +
      ir[:aggregates].flat_map { |a| a[:entities] }.flat_map { |e| e[:attributes] } +
      all_value_objects.flat_map { |vo| vo[:attributes] }
  end

  def all_commands
    ir[:aggregates].flat_map { |a| a[:commands] } +
      ir[:aggregates].flat_map { |a| a[:entities] }.flat_map { |e| e[:commands] }
  end

  it "declares a composite identity (more than one identified_by component)" do
    expect(ir[:aggregates].any? { |a| a[:identified_by].to_a.size > 1 }).to be(true)
  end

  it "declares a composite identity with a BARE component that IS a declared attribute" do
    # The shape Statement.account_id is — not dotted into a value object,
    # resolved the same way Runtime::Identity.from resolves any identity
    # head that's a real attribute: read directly, no walk. The OTHER bare
    # shape (a component that ISN'T a declared attribute at all —
    # `owner_id`, language/bluebook/behavior.bluebook's own polymorphic
    # parent-tracking) is real but deliberately NOT required of Banking:
    # nothing in a business domain plausibly needs "this identity
    # component means whichever of two types declared it," the exact
    # reason the self-hosted grammar needed it in the first place.
    bare_declared = ir[:aggregates].any? do |agg|
      agg[:identified_by].to_a.size > 1 && agg[:identified_by].any? do |path|
        !path.include?(".") && agg[:attributes].any? { |a| a[:name].to_s == path }
      end
    end
    expect(bare_declared).to be(true)
  end

  it "declares a closed set with more than one field per member" do
    # Ordinary, public DSL syntax (`one_of do member field: x, ... end` —
    # Vocabulary::Comparison in the self-hosted grammar uses the exact
    # same form), not a self-hosted-grammar exclusive. A generator that
    # only ever saw Size/AccountKind-shaped single-field closed sets has
    # no reason to expect a member to carry more than one field.
    multi_field = all_value_objects.select { |vo| vo[:closed_set] }.any? { |vo| vo[:attributes].size > 1 }
    expect(multi_field).to be(true)
  end

  it "declares an entity (identity and behavior nested inside an aggregate)" do
    expect(ir[:aggregates].flat_map { |a| a[:entities] }).not_to be_empty
  end

  it "declares a lifecycle" do
    expect(ir[:aggregates].map { |a| a[:lifecycle] }.compact).not_to be_empty
  end

  it "declares every then_set op — set, append, increment, decrement" do
    ops = all_commands.flat_map { |c| c[:mutations] }.map { |m| m[:op] }.uniq
    expect(ops).to include(:set, :append, :increment, :decrement)
  end

  it "declares a given and an ensures" do
    expect(all_commands.flat_map { |c| c[:givens] }).not_to be_empty
    expect(all_commands.flat_map { |c| c[:ensures] }).not_to be_empty
  end

  it "declares a command with more than one emits" do
    expect(all_commands.map { |c| c[:emits].size }).to include(a_value > 1)
  end

  it "declares a Reference<X> attribute" do
    expect(all_attributes.map { |a| a[:type] }).to include(a_string_matching(/\AReference</))
  end

  it "declares a list-of-value-object attribute (not an entity list)" do
    entity_type_names = ir[:aggregates].flat_map { |a| a[:entities] }.map { |e| e[:name] }
    list_vo = all_attributes.any? { |a| a[:list] && !entity_type_names.include?(a[:type]) }
    expect(list_vo).to be(true)
  end

  it "declares an optional attribute and a defaulted attribute" do
    expect(all_attributes.map { |a| a[:optional] }).to include(true)
    expect(all_attributes.map { |a| a[:default] }.compact).not_to be_empty
  end

  it "declares a pattern-constrained attribute" do
    expect(all_attributes.map { |a| a[:pattern] }.compact).not_to be_empty
  end

  it "declares a cross-aggregate closed-set reference (admits:)" do
    expect(all_attributes.map { |a| a[:admits] }.compact).not_to be_empty
  end

  it "declares a read model, a policy, and a process manager" do
    expect(ir[:read_models]).not_to be_empty
    expect(ir[:policies]).not_to be_empty
    expect(ir[:process_managers]).not_to be_empty
  end
end
