require "hecks"
require "hecks/ports/persistence/plugins/era"
require_relative "../../../support/era_registry_loading"

# What a held era holds, read from its record alone: the shape its mint recorded, and the
# declaration its held text parses to, which a field-by-field diff needs. An era whose held text is
# the top-level file of a domain split into module folders declares none of the folders'
# aggregates, so its declaration is refused by name and the mint decision asks for an edge.
RSpec.describe "a held era's shape and declaration" do
  include EraRegistryLoading

  def manager = Hecks::Adapters::PostgresEra::LineageManager

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

  def projection = Hecks::Runtime::StorageShape.project(load_registry(whole_source).bluebooks.values.first)

  def era(text, recorded = projection)
    { ordinal: 3, label: "abc123", held_text: text, projection: recorded }
  end

  # The domain grown by one aggregate the held era does not have.
  def grown
    load_registry(whole_source.sub(/^end\n\z/, <<~NOTE)).bluebooks.values.first
        aggregate "Note" do
          identified_by :body

          attribute :body, Body

          value_object "Body" do
            attribute :text, String
          end
        end
      end
    NOTE
  end

  def decision(held_era)
    manager::MintDecision.decide(held: [manager::MintDecision.held_for_decision(held_era)], bluebook: grown,
                                 watermark: 0, rows: [], edge_source: { translations: [], recorded: [%w[abc123 x]] })
  end

  it "answers the shape a top-level-only era's mint recorded, not the shape its text declares" do
    expect(manager.held_shape(era(top_level_source))).to eq(projection)
  end

  it "answers the shape a whole era's text declares when its mint recorded none" do
    expect(manager.held_shape(era(whole_source, nil))).to eq(projection)
  end

  it "answers the declaration of an era whose text declares the recorded shape" do
    expect(manager.held_declaration(era(whole_source)).aggregates.map(&:name)).to eq(["Acct"])
  end

  it "refuses the declaration of a top-level-only era, naming the era" do
    expect { manager.held_declaration(era(top_level_source)) }
      .to raise_error(Hecks::Runtime::WiringError, /era 3 \(abc123\) holds part of its domain's source/)
  end

  it "asks for an edge, by name, for a move from a top-level-only era with no edge file" do
    expect(decision(era(top_level_source)).reason).to eq(:partial_held_text)
  end

  it "decides a move from a whole era by its diff" do
    expect(decision(era(whole_source)).reason).not_to eq(:partial_held_text)
  end
end
