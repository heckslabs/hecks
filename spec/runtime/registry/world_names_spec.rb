require "hecks"
require_relative "../../support/postgres_probe"
require_relative "../../support/era_registry_loading"

# The physical name of a stored aggregate and the former name of a domain are the world's to say,
# not the bluebook's: `stored_as Revision: "commit"` and `formerly "Old"` in the PostgresRevision block.
# The bluebook's `formerly_known_as` still works as a fallback, warns once naming the replacement,
# and must agree with the world when both are given.
RSpec.describe "the world's names for what is stored" do
  include EraRegistryLoading

  let(:template) do
    <<~BLUEBOOK
      Hecks.bluebook "Ledger" do
        DOMAIN_FORMERLY
        aggregate "Revision" do
          identified_by :tag
          AGGREGATE_FORMERLY
          attribute :tag, Tag

          value_object "Tag" do
            attribute :label, String
          end

          command "Record" do
            attribute :tag, Tag
            emits "Recorded"
          end
        end
      end
    BLUEBOOK
  end

  def source(aggregate: nil, domain: nil)
    template.sub("DOMAIN_FORMERLY", domain ? %(formerly_known_as "#{domain}") : "")
            .sub("AGGREGATE_FORMERLY", aggregate ? %(formerly_known_as "#{aggregate}") : "")
  end

  def registry_with(aggregate: nil, domain: nil, &world)
    load_registry(source(aggregate: aggregate, domain: domain)).tap do |registry|
      Hecks.with_registry(registry) { Hecks.world("Ledger", &world) } if world
    end
  end

  def storage_of(registry) = registry.bluebook("Ledger").aggregate("Revision").storage_name

  def applied(registry)
    registry.apply_world_names!
    storage_of(registry)
  end

  before { Hecks::Deprecation.forget! }

  it "stores an aggregate under the name the world gives it" do
    expect(applied(registry_with { stored_as Revision: "commit" })).to eq("commit")
  end

  it "stores an aggregate under its own name when nothing says otherwise" do
    expect(applied(registry_with)).to eq("revision")
  end

  it "still follows the bluebook's formerly_known_as when the world says nothing" do
    registry = registry_with(aggregate: "Commit")
    expect { registry.apply_world_names! }.to output(/stored_as/).to_stderr
  end

  it "keeps the former table when only the bluebook names it" do
    registry = registry_with(aggregate: "Commit")
    expect(registry.tap { |r| capture_stderr { r.apply_world_names! } }.then { storage_of(registry) }).to eq("commit")
  end

  it "accepts a world and a bluebook that name the same table" do
    registry = registry_with(aggregate: "Commit") { stored_as Revision: "commit" }
    expect(capture_stderr { applied(registry) }).to include("stored_as")
  end

  it "refuses by name a world and a bluebook that name different tables" do
    registry = registry_with(aggregate: "Change") { stored_as Revision: "commit" }
    expect { registry.apply_world_names! }.to raise_error(Hecks::Runtime::WiringError, /Revision.*"commit".*"Change"/m)
  end

  it "refuses by name a stored_as that names an aggregate the domain does not declare" do
    registry = registry_with { stored_as Revisoin: "commit" }
    expect { registry.apply_world_names! }
      .to raise_error(Hecks::Runtime::WiringError, /stored_as names Revisoin.*Ledger declares no such aggregate/m)
  end

  it "warns once, naming the replacement, however often the names are applied" do
    registry = registry_with(aggregate: "Commit")
    expect(capture_stderr { 2.times { registry.apply_world_names! } }.scan("deprecated").size).to eq(1)
  end

  it "names the world line that replaces the word" do
    registry = registry_with(aggregate: "Commit")
    expect(capture_stderr { registry.apply_world_names! }).to include('stored_as Revision: "commit"')
  end

  it "says nothing for an aggregate with no formerly_known_as" do
    registry = registry_with { stored_as Revision: "commit" }
    expect(capture_stderr { registry.apply_world_names! }).to be_empty
  end

  describe "the domain's former name" do
    let(:era_block) { proc { persisted_by("Postgres") { formerly "Old" } } }

    it "is adopted from the PostgresRevision block" do
      registry = registry_with(&era_block).apply_world_names!
      expect(registry.bluebook("Ledger").formerly_known_as).to eq("Old")
    end

    it "is refused by name when the bluebook names a different one" do
      registry = registry_with(domain: "Other", &era_block)
      expect { registry.apply_world_names! }.to raise_error(Hecks::Runtime::WiringError, /"Old".*"Other"/m)
    end
  end

  describe "the names a renamed aggregate may have stored rows under" do
    def renamed_registry
      registry_with(aggregate: "Commit").tap do |registry|
        Hecks.with_registry(registry) do
          Hecks.data_translation("Ledger", from: "aaaaaa", to: "bbbbbb") { aggregate("Revision", was: "Change") { nil } }
        end
      end
    end

    it "lists every name a translation renames it from, besides the one it is stored under" do
      registry = renamed_registry
      capture_stderr { registry.apply_world_names! }
      expect(registry.bluebook("Ledger").aggregate("Revision").prior_storage_names).to eq(["change"])
    end
  end

  def capture_stderr
    original = $stderr
    $stderr = StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = original
  end
end
