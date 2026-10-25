require "spec_helper"
require "hecks/projections"
require_relative "../support/doors"

# Every closed set a category test can loop over is placed: each vocabulary table, door, store,
# projection kind and example domain is either exercised by the category spec named for it, or
# left out with the reason. A new member, or a category spec that stops naming one, fails here.
RSpec.describe "the category tests, covering every closed set", :aggregate_failures do
  # Vocabularies whose members a domain's behavior exhibits, each with the spec looping them.
  VOCABULARY_SPECS = {
    "DomainRefusal"          => "spec/categories/refusal_kinds_spec.rb",
    "MutationOp"             => "spec/categories/mutation_ops_spec.rb",
    "QueryComparator"        => "spec/categories/query_comparator_kinds_spec.rb",
    "AggregateDispatchOrder" => "spec/vocabulary_conformance_spec.rb",
    "EntityDispatchOrder"    => "spec/vocabulary_conformance_spec.rb"
  }.freeze

  # Vocabularies that name the language's own grammar or the repository's tooling, not a
  # behavior a domain shows; each is held where its table is projected and checked.
  VOCABULARIES_ELSEWHERE = {
    "CargoReservedName"     => "names the Rust build refuses; spec/rust_vocabulary_spec.rb",
    "CiGate"                => "CI jobs, held by spec/tools_ci_gates_spec.rb",
    "Comparison"            => "expression operators, held by spec/operator_conformance_spec.rb",
    "DispatchStage"         => "the stages a refusal comes from, held by spec/runtime/refusal_classification_spec.rb",
    "FieldHint"             => "form field hints, held by spec/field_hint_conformance_spec.rb",
    "IncludeHaystack"       => "grammar table, held by spec/vocabulary_conformance_spec.rb",
    "Lane"                  => "release lanes, held by spec/tools_lanes_spec.rb",
    "LoadOrder"             => "grammar table, held by spec/vocabulary_conformance_spec.rb",
    "NormalisationStrategy" => "grammar table, held by spec/vocabulary_conformance_spec.rb",
    "PrebuiltBinary"        => "release artifacts, held by spec/rust_build_prebuilt_binary_spec.rb",
    "Primitive"             => "attribute types, held by spec/vocabulary_conformance_spec.rb",
    "QaDial"                => "QA settings, held by spec/qa_dials_spec.rb",
    "RefusalClass"          => "kind and stage of each refusal, held by spec/runtime/refusal_classification_spec.rb",
    "RefusalKind"           => "the sorts of refusal, held by spec/runtime/refusal_classification_spec.rb",
    "RefusalSiteArgument"   => "refusal wording rows, pinned by the IR golden",
    "RefusalTemplate"       => "refusal wording rows, pinned by the IR golden",
    "ReleaseFile"           => "release bookkeeping, held by spec/release/",
    "RequiredCheck"         => "release checks, held by spec/tools_lanes_spec.rb",
    "RetiredScript"         => "retired tooling, held by spec/bin_holds_no_script_spec.rb",
    "RustReservedWord"      => "names the Rust build refuses; spec/rust_vocabulary_spec.rb",
    "SignTest"              => "grammar table, held by spec/vocabulary_conformance_spec.rb",
    "SizedType"             => "grammar table, held by spec/vocabulary_conformance_spec.rb",
    "StepStage"             => "the stage each dispatch step belongs to, held by spec/runtime/validate_spec.rb",
    "ToStringType"          => "grammar table, held by spec/vocabulary_conformance_spec.rb",
    "Trigger"               => "grammar table, held by spec/vocabulary_conformance_spec.rb",
    "VocabularyName"        => "the list of these tables itself, held by spec/vocabulary_table_spec.rb"
  }.freeze

  # The doors, by driving adapter name, with the door name spec/support/doors.rb sends through.
  DOOR_NAMES = { "Ruby" => "ruby", "Cli" => "cli", "Json" => "json", "Mcp" => "mcp" }.freeze

  DOORS_ELSEWHERE = { "Web" => "the Composer's live editor, a development tool no domain is served through" }.freeze

  # Each persistence adapter with the spec holding it to the others.
  STORE_SPECS = {
    "Memory"            => "spec/fuzzing/properties/every_domain_spec.rb",
    "SqlitePersistence" => "spec/fuzzing/properties/every_domain_spec.rb",
    "Postgres"          => "spec/fuzzing/properties/every_domain_spec.rb",
    "PostgresEra"       => "spec/categories/era_read_through_spec.rb",
    "Heki"              => "spec/ports/persistence_contract_spec.rb",
    "D1"                => "spec/ports/persistence_contract_spec.rb"
  }.freeze

  STORES_ELSEWHERE = {
    "Lambda"       => "a deployed runtime's store reached over the network, not booted in-process",
    "LocalStorage" => "the browser's storage under the wasm build, held by spec/adapters/driven/local_storage_spec.rb"
  }.freeze

  # The projection categories no per-domain loop covers, and why.
  PROJECTIONS_ELSEWHERE = {
    meta:   "projects the language itself, not a domain; each is held by its own table spec",
    export: "projects a deployment and needs a world; held by the deploy golden specs"
  }.freeze

  # Committed projection output, each with the drift spec comparing it to a fresh projection.
  DRIFT_SPECS = { "glossary" => "spec/glossary_spec.rb", "docs/generated/diagrams" => "spec/diagrams_spec.rb" }.freeze

  # The category specs that loop every example domain.
  EXAMPLE_DOMAIN_SPECS = %w[
    spec/categories/completeness_spec.rb spec/categories/projection_kinds_spec.rb
    spec/doors/role_enforcement_spec.rb spec/fuzzing/properties/every_domain_spec.rb
  ].freeze

  def source(path) = File.read(File.join(InMemoryDomain::ROOT, path))

  def persistence_adapters
    Dir[File.join(InMemoryDomain::ROOT, "lib/hecks/adapters/driven/*.adapter")].flat_map do |path|
      File.read(path).split(/^(?=Hecks\.adapter )/).grep(/port\s+"persistence"/)
          .map { |block| block[/Hecks\.adapter "([^"]+)"/, 1] }
    end.compact
  end

  it "places every vocabulary table" do
    unplaced = Hecks::Vocabulary.names - VOCABULARY_SPECS.keys - VOCABULARIES_ELSEWHERE.keys
    expect(unplaced).to be_empty
  end

  it "loops each behavior vocabulary in the spec named for it" do
    VOCABULARY_SPECS.each { |name, path| expect(source(path)).to include(%("#{name}")), "#{path} never names #{name}" }
  end

  it "sends through every door, or says why a door is left out" do
    expect(Hecks::Bluebook::Hecksagon::DRIVING_ADAPTERS - DOOR_NAMES.keys - DOORS_ELSEWHERE.keys).to be_empty
    expect(DOOR_NAMES.values.map(&:to_sym)).to match_array(Doors::NAMES)
  end

  it "holds every persistence adapter to the others, or says why it is left out" do
    expect(persistence_adapters - STORE_SPECS.keys - STORES_ELSEWHERE.keys).to be_empty
    STORE_SPECS.each_value { |path| expect(File).to exist(File.join(InMemoryDomain::ROOT, path)) }
  end

  it "loops every projection category, or says why one is left out" do
    expect(Hecks::Projector.registered_by_category.keys - [:projection] - PROJECTIONS_ELSEWHERE.keys).to be_empty
  end

  it "compares every example domain's committed glossary with a fresh projection" do
    committed = Dir[File.join(InMemoryDomain::ROOT, "examples/*/glossary")].map { |dir| File.basename(File.dirname(dir)) }
    expect(committed.reject { |domain| source(DRIFT_SPECS.fetch("glossary")).include?("examples/#{domain}") }).to be_empty
  end

  it "compares every committed diagram set with a fresh projection" do
    committed = Dir[File.join(InMemoryDomain::ROOT, "docs/generated/diagrams/*")].map { |dir| File.basename(dir) }
    expect(committed.reject { |domain| source(DRIFT_SPECS.fetch("docs/generated/diagrams")).include?(domain) }).to be_empty
  end

  it "loops every example domain in each spec that claims to" do
    EXAMPLE_DOMAIN_SPECS.each { |path| expect(source(path)).to include("Corpus.members(:example)"), path }
  end

  it "names only spec files that exist as where a set is held" do
    reasons = [VOCABULARIES_ELSEWHERE, STORES_ELSEWHERE].flat_map(&:values)
    named = reasons.flat_map { |reason| reason.scan(%r{spec/[\w/]+\.rb}) }
    expect(named.reject { |path| File.exist?(File.join(InMemoryDomain::ROOT, path)) }).to be_empty
  end

  it "knows every directory under examples/ as an example domain" do
    on_disk = Dir[File.join(InMemoryDomain::ROOT, "examples/*/")].map { |dir| File.basename(dir) }
    expect(Hecks::Corpus.members(:example).map { |member| File.basename(member.path) }).to match_array(on_disk)
  end
end
