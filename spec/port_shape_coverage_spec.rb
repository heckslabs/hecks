require "spec_helper"

# Banking's exported IR must exercise every structural shape a port generator branches on.
# A shape Banking stops exercising is a regression; add a missing one to Banking.
RSpec.describe "the shapes a port generator needs Banking to exercise" do
  # Booted once per file: examples only read the exported IR, so a shared registry is safe.
  before(:context) do
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      load_bluebook_files(InMemoryDomain::BANKING_BLUEBOOK_DIR)
    end
    @banking_registry = registry
  end

  let(:ir) { Hecks::Projector::Exporter.call(banking_registry).fetch("Banking") }
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

  # The shape of Statement.account_id: read directly, no walk. The other bare shape
  # (a component that is no declared attribute, like `owner_id`) is not required of Banking.
  def bare_declared_component?(agg)
    agg[:identified_by].to_a.size > 1 && agg[:identified_by].any? do |path|
      !path.include?(".") && agg[:attributes].any? { |a| a[:name].to_s == path }
    end
  end

  it "declares a composite identity with a BARE component that IS a declared attribute" do
    expect(ir[:aggregates].any? { |agg| bare_declared_component?(agg) }).to be(true)
  end

  it "declares a closed set with more than one field per member" do
    # A generator that only saw single-field closed sets has no reason to expect more.
    multi_field = all_value_objects.select { |vo| vo[:closed_set] }.any? { |vo| vo[:attributes].size > 1 }
    expect(multi_field).to be(true)
  end

  it "declares an entity (identity and behavior nested inside an aggregate)" do
    expect(ir[:aggregates].flat_map { |a| a[:entities] }).not_to be_empty
  end

  it "declares a lifecycle" do
    expect(ir[:aggregates].map { |a| a[:lifecycle] }.compact).not_to be_empty
  end

  it "declares every sets op — set, append, increment, decrement" do
    ops = all_commands.flat_map { |c| c[:mutations] }.map { |m| m[:op] }.uniq
    expect(ops).to include(:set, :append, :increment, :decrement)
  end

  it "declares a given and an ensures", :aggregate_failures do
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

  it "declares an optional attribute and a defaulted attribute", :aggregate_failures do
    expect(all_attributes.map { |a| a[:optional] }).to include(true)
    expect(all_attributes.map { |a| a[:default] }.compact).not_to be_empty
  end

  it "declares a pattern-constrained attribute" do
    expect(all_attributes.map { |a| a[:pattern] }.compact).not_to be_empty
  end

  it "declares a cross-aggregate closed-set reference (admits:)" do
    expect(all_attributes.map { |a| a[:admits] }.compact).not_to be_empty
  end

  it "declares a read model, a policy, and a process manager", :aggregate_failures do
    expect(ir[:read_models]).not_to be_empty
    expect(ir[:policies]).not_to be_empty
    expect(ir[:process_managers]).not_to be_empty
  end
end
