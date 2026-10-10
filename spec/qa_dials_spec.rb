require "spec_helper"
require "hecks/fuzzing"

# The dials of the hecks_qa loop are declared once, as `QaDial` rows of the Vocabulary chapter:
# the loader's type table and the QualityControl chapter's constants are read from them.
RSpec.describe "the QaDial rows" do
  let(:rows)     { Hecks::Vocabulary.rows("QaDial") }
  let(:names)    { rows.map { |row| row.fetch("name") } }
  let(:settings) { YAML.safe_load_file(Hecks::Fuzzing::QaSettings::DEFAULT_PATH, symbolize_names: true) }

  it "name each dial once, with a type the loader knows and a meaning", :aggregate_failures do
    expect(names.tally.select { |_, count| count > 1 }.keys).to eq([])
    expect(rows.map { |row| row.fetch("type") } - Hecks::Fuzzing::QaSettings::TYPE_CLASSES.keys).to eq([])
    expect(rows.select { |row| row.fetch("meaning").strip.empty? }.map { |row| row["name"] }).to eq([])
  end

  it "are exactly the keys of qa/settings.yml" do
    expect(names.map(&:to_sym).sort).to eq(settings.keys.sort)
  end

  it "give the loader its type table", :aggregate_failures do
    expect(Hecks::Fuzzing::QaSettings::EXPECTED_TYPES.keys).to eq(names.map(&:to_sym))
    expect(Hecks::Fuzzing::QaSettings::EXPECTED_TYPES.fetch(:draft_only)).to eq([TrueClass, FalseClass])
    expect(Hecks::Fuzzing::QaSettings::EXPECTED_TYPES.fetch(:adversarial_fraction)).to eq([Numeric])
  end

  def quality_control_dials_loaded
    return if defined?(QualityControlDials)

    Hecks.boot(File.join(InMemoryDomain::ROOT, "lib/hecks/quality_control"), install_driving: false)
  end

  def expect_dial_defined(name)
    expect(QualityControlDials.const_defined?(name.upcase)).to be(true), "no QualityControlDials::#{name.upcase}"
  end

  it "become one constant each on QualityControlDials, holding the file's value", :aggregate_failures do
    quality_control_dials_loaded

    names.each { |name| expect_dial_defined(name) }
    expect(QualityControlDials::PR_CAP_PER_DAY).to eq(settings.fetch(:pr_cap_per_day))
    expect(QualityControlDials::AUTOMATED_ENGINEER).to eq("qa_sweep")
  end
end
