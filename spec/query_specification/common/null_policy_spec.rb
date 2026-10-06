require "spec_helper"

# Pins M3 (docs/audits/2026-08-10-main-bug-audit.md): an undeclared policy must order nulls
# the same way in SQL as in Memory/Heki, or row order depends on which store answered.
RSpec.describe Hecks::QuerySpecification::Common::NullPolicy do
  describe ".sql_order" do
    it "renders NULLS FIRST on ascending when no policy is declared, matching #order's own default" do
      expect(described_class.sql_order("price", "asc", nil)).to eq("price ASC NULLS FIRST, id ASC")
    end

    it "renders NULLS LAST on descending when no policy is declared, matching #order's own default" do
      expect(described_class.sql_order("price", "desc", nil)).to eq("price DESC NULLS LAST, id DESC")
    end

    it "still honors an explicit :first policy regardless of direction", :aggregate_failures do
      policy = Hecks::QuerySpecification::Common::NullSemantics.new(mode: :first)
      expect(described_class.sql_order("price", "asc", policy)).to eq("price ASC NULLS FIRST, id ASC")
      expect(described_class.sql_order("price", "desc", policy)).to eq("price DESC NULLS FIRST, id DESC")
    end

    it "still honors an explicit :last policy regardless of direction", :aggregate_failures do
      policy = Hecks::QuerySpecification::Common::NullSemantics.new(mode: :last)
      expect(described_class.sql_order("price", "asc", policy)).to eq("price ASC NULLS LAST, id ASC")
      expect(described_class.sql_order("price", "desc", policy)).to eq("price DESC NULLS LAST, id DESC")
    end

    it "an explicitly-declared :native policy renders the same as no policy at all" do
      native = Hecks::QuerySpecification::Common::NullSemantics.default
      expect(described_class.sql_order("price", "asc", native)).to eq(described_class.sql_order("price", "asc", nil))
    end
  end

  # The undeclared/native default that .sql_order must agree with.
  describe ".order" do
    it "puts nulls first ascending by default, the SQLite convention #sql_order now matches" do
      rows = [{ v: 2 }, { v: nil }, { v: 1 }]
      ordered = described_class.order(rows, direction: :asc) { |row| row[:v] }
      expect(ordered).to eq([{ v: nil }, { v: 1 }, { v: 2 }])
    end

    it "puts nulls last descending by default" do
      rows = [{ v: 2 }, { v: nil }, { v: 1 }]
      ordered = described_class.order(rows, direction: :desc) { |row| row[:v] }
      expect(ordered).to eq([{ v: 2 }, { v: 1 }, { v: nil }])
    end

    it "treats an upper- or mixed-case direction the same as lowercase, matching #sql_order", :aggregate_failures do
      rows = [{ v: 2 }, { v: nil }, { v: 1 }]
      expect(described_class.order(rows, direction: "DESC") { |row| row[:v] })
        .to eq(described_class.order(rows, direction: "desc") { |row| row[:v] })
      expect(described_class.order(rows, direction: "Desc") { |row| row[:v] })
        .to eq([{ v: 2 }, { v: 1 }, { v: nil }])
    end
  end
end
