require "spec_helper"

# A `member` cell is stored as text, so a quoted `"true"` and a bare `true` need different
# spellings. `mark` writes one and `unmark` reads it back; together they keep a String a String.
RSpec.describe Hecks::Bluebook::Assembly::Scalars do
  let(:strings) { ["true", "false", "1", "-3", "1.5", "nil", "", "word", "\"quoted\"", "a \"b\" c", "back\\slash", ":sym"] }
  let(:natives) { [true, false, 7, -2, 2.5] }
  let(:ambiguous) { %w[true false 1 -3 1.5] }

  def stored(cell) = described_class.mark(cell).to_s

  def round_trip(cell) = described_class.unmark(stored(cell))

  it "reads a String back as a String, whatever it spells", :aggregate_failures do
    strings.each { |cell| expect(round_trip(cell)).to eq(cell), "#{cell.inspect} came back as #{round_trip(cell).inspect}" }
  end

  it "reads a boolean or number back as itself", :aggregate_failures do
    natives.each { |cell| expect(round_trip(cell)).to eq(cell) }
  end

  it "quotes a String that would read back as a boolean or a number" do
    expect(ambiguous.map { |cell| stored(cell) }).to eq(ambiguous.map { |cell| "\"#{cell}\"" })
  end

  it "leaves every other String, and every boolean and number, as its own spelling", :aggregate_failures do
    expect(["word", "", ":sym"].map { |cell| stored(cell) }).to eq(["word", "", ":sym"])
    expect(natives.map { |cell| stored(cell) }).to eq(%w[true false 7 -2 2.5])
  end
end
