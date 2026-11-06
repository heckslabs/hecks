require "hecks"
require "hecks/ports/persistence/plugins/era"
require_relative "../../../support/era_registry_loading"

# What a held era is, read from its record: the storage shape its mint recorded and that shape's
# hash. Held text decides nothing; an era with no stored shape is read from its text only when the
# text hashes to the era's stored hash, and is refused by name otherwise.
RSpec.describe "a held era read from its stored shape" do
  include EraRegistryLoading

  def manager = Hecks::Adapters::PostgresRevision::LineageManager

  def whole_source
    <<~BLUEBOOK
      Hecks.bluebook "Ledger" do
        aggregate "Acct" do
          identified_by :kind

          attribute :kind, Kind

          value_object "Kind" do
            attribute :label, String
          end
        end
      end
    BLUEBOOK
  end

  # The top-level file of the same domain, with its aggregate in a module folder.
  def top_level_source = %(Hecks.bluebook "Ledger" do\nend\n)

  def bluebook = load_registry(whole_source).bluebooks.values.first

  def projection = Hecks::Runtime::StorageShape.project(bluebook)

  def stored_hash = Hecks::Runtime::StorageShape.mint_hash(bluebook)

  def era(text, recorded: projection, hash: stored_hash)
    { ordinal: 3, label: "abc123", held_text: text, projection: recorded, hash: hash }
  end

  it "answers the shape its mint recorded, whatever its held text declares" do
    expect(manager.held_shape(era(top_level_source))).to eq(projection)
  end

  it "reads an era with no stored shape from a held text that hashes to its stored hash" do
    expect(manager.held_shape(era(whole_source, recorded: nil))).to eq(projection)
  end

  it "refuses an era with no stored shape whose held text does not hash to its stored hash, by name" do
    expect { manager.held_shape(era(top_level_source, recorded: nil)) }
      .to raise_error(Hecks::Runtime::WiringError, /era 3 \(abc123\) stores no storage shape.*does not hash/)
  end

  it "refuses an era with no stored shape and no stored hash, by name" do
    expect { manager.held_shape(era(whole_source, recorded: nil, hash: nil)) }
      .to raise_error(Hecks::Runtime::WiringError, /no stored hash to check it against/)
  end

  it "answers the era's aggregates and value-object members from the stored shape alone", :aggregate_failures do
    held = manager.held_bluebook(era(nil))
    expect(held.aggregates.map(&:name)).to eq(["Acct"])
    expect(held.aggregate("Acct").value_object("Kind").attributes.map(&:name)).to eq([:label])
    expect(held.aggregate("Acct").identity_paths).to eq(bluebook.aggregates.first.identity_paths)
  end

  it "hashes an unnamed era's stored shape as the mint hashes the bluebook it came from" do
    expect(manager.held_hash(era(nil, hash: nil))).to eq(stored_hash)
  end
end
