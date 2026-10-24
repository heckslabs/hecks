require "spec_helper"
require "hecks/grammar"

# "Can this expression compile for dialect D?" is answered from the operator admission ledger: true
# exactly when every operator the expression evaluates through has a D rendering.
RSpec.describe "whether an expression compiles for a dialect" do
  def compiles?(canonical, dialect) = Hecks::Grammar.compiles_for?(canonical, dialect)

  it "compiles comparisons and logic for both SQL dialects", :aggregate_failures do
    expect(compiles?("balance > 0 && status != \"closed\"", "postgres")).to be(true)
    expect(compiles?("balance > 0 && status != \"closed\"", :sqlite)).to be(true)
  end

  it "keeps a regular expression match out of either SQL dialect, but not out of Ruby", :aggregate_failures do
    expect(compiles?("name.match?(/\\A[a-z]+\\z/)", "postgres")).to be(false)
    expect(compiles?("name.match?(/\\A[a-z]+\\z/)", "sqlite")).to be(false)
    expect(compiles?("name.match?(/\\A[a-z]+\\z/)", "ruby")).to be(true)
  end

  it "tells the dialects apart where only one renders an operator", :aggregate_failures do
    expect(compiles?("tags.split(\",\").size > 1", "postgres")).to be(true)
    expect(compiles?("tags.split(\",\").size > 1", "sqlite")).to be(false)
  end

  it "compiles a bare leaf, which uses no operator, everywhere" do
    expect(compiles?("active", "sqlite")).to be(true)
  end

  it "does not compile text the grammar does not recognise", :aggregate_failures do
    expect(compiles?("balance >", "postgres")).to be(false)
    expect(compiles?("owner.frobnicate(1)", "postgres")).to be(false)
  end

  it "does not compile for a dialect nothing renders in" do
    expect(compiles?("balance > 0", "cobol")).to be(false)
  end

  it "gives every admitted operator a Ruby rendering, the reference every dialect is held to" do
    expect(Hecks::Grammar.operators_rendered_in("ruby")).to match_array(Hecks::Grammar.renderings_by_operator.keys)
  end
end
