require "spec_helper"

# M3 (docs/audits/2026-08-10-main-bug-audit.md) — an UNDECLARED
# (`NullSemantics.default`, mode `:native`) null policy used to leave
# `sql_order` rendering no `NULLS ...` clause at all, deferring to
# whichever dialect happened to run the query: Postgres's own native
# default is NULLS LAST on ASC (and FIRST on DESC), while `NullPolicy#order`
# — this SAME "native" default, for Memory/Heki — puts nulls FIRST on ASC
# (and LAST on DESC), the SQLite convention. Same declared query, same
# data, a different row order depending only on which store answered it.
RSpec.describe Hecks::QuerySpecification::Common::NullPolicy do
  describe ".sql_order" do
    it "renders NULLS FIRST on ascending when no policy is declared, matching #order's own default" do
      expect(described_class.sql_order("price", "asc", nil)).to eq("price ASC NULLS FIRST, id ASC")
    end

    it "renders NULLS LAST on descending when no policy is declared, matching #order's own default" do
      expect(described_class.sql_order("price", "desc", nil)).to eq("price DESC NULLS LAST, id DESC")
    end

    it "still honors an explicit :first policy regardless of direction" do
      policy = Hecks::QuerySpecification::Common::NullSemantics.new(mode: :first)
      expect(described_class.sql_order("price", "asc", policy)).to eq("price ASC NULLS FIRST, id ASC")
      expect(described_class.sql_order("price", "desc", policy)).to eq("price DESC NULLS FIRST, id DESC")
    end

    it "still honors an explicit :last policy regardless of direction" do
      policy = Hecks::QuerySpecification::Common::NullSemantics.new(mode: :last)
      expect(described_class.sql_order("price", "asc", policy)).to eq("price ASC NULLS LAST, id ASC")
      expect(described_class.sql_order("price", "desc", policy)).to eq("price DESC NULLS LAST, id DESC")
    end

    it "an explicitly-declared :native policy renders the same as no policy at all" do
      native = Hecks::QuerySpecification::Common::NullSemantics.default
      expect(described_class.sql_order("price", "asc", native)).to eq(described_class.sql_order("price", "asc", nil))
    end
  end

  # #order's own default (undeclared/native policy) — the side this fix
  # brought `sql_order` INTO agreement with, not the side that changed.
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
  end
end
