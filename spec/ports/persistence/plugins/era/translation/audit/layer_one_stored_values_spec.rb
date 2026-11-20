require "hecks"
require "hecks/ports/persistence/plugins/era"
require "hecks/adapters/driven/postgres_era/lineage_manager"

# Layer 1 holds a stored value to dispatch's own checks, as the Rust mint audit
# (`rust/host/core/src/reference_validate.rs`) does: a required field stored nil is refused, a
# slot the record does not hold and an optional one stored nil are not.
RSpec.describe "Layer 1's stored-value check on a required field stored nil" do
  PAINT_BLUEBOOK = <<~RUBY.freeze
    Hecks.bluebook "Paint" do
      aggregate "Can" do
        identified_by :kind
        attribute :kind, Kind
        attribute :color, Color
        attribute :shade, Color, optional: true
        value_object "Color" do
          attribute :value, String
        end
        value_object "Kind" do
          attribute :label, String
        end
      end
    end
  RUBY

  let(:can) { Hecks::Adapters::PostgresEra::LineageManager.shadow(PAINT_BLUEBOOK).aggregates.first }

  def violations_for(state)
    violations = []
    Hecks::Translation::Audit.layer_one!(violations, can, { "c1" => { "kind" => { "label" => "a" } }.merge(state) })
    violations
  end

  it "refuses a required value object stored nil" do
    expect(violations_for("color" => nil)).to eq(["Can#c1: Color.value expects String, got nil"])
  end

  it "refuses a required value object whose field is stored nil" do
    expect(violations_for("color" => { "value" => nil })).to eq(["Can#c1: Color.value expects String, got nil"])
  end

  it "refuses a value object field stored with the wrong type" do
    expect(violations_for("color" => { "value" => 3 })).to eq(["Can#c1: Color.value expects String, got 3"])
  end

  it "accepts a record that does not hold the slot at all" do
    expect(violations_for({})).to eq([])
  end

  it "accepts an optional value object stored nil" do
    expect(violations_for("color" => { "value" => "red" }, "shade" => nil)).to eq([])
  end
end
