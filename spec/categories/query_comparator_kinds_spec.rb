require "spec_helper"
require "json"
require "hecks/fuzzing"

# Every query comparator, asked of spec/fixtures/query_comparators: each answers the rows its
# step expects, agrees with the reference engine, and answers the same on Memory and SQLite.
RSpec.describe "every query comparator", :aggregate_failures do
  def self.fixture = File.join(InMemoryDomain::ROOT, "spec/fixtures/query_comparators")

  def self.steps = JSON.parse(File.read(File.join(fixture, "steps.json")))["steps"]

  def self.history = @history ||= Hecks::Fuzzing::Replay.call(fixture, steps)

  # Each comparator mapped to the query steps whose declared `where` uses it.
  def self.queries_by_comparator
    pairs = steps.select { |step| step["query"] }.flat_map { |step| comparators_of(step).map { |op| [op, step] } }
    pairs.group_by(&:first).transform_values { |grouped| grouped.map(&:last) }
  end

  # The comparators the query a step asks declares in its `where`.
  def self.comparators_of(step)
    item = history[:bluebooks]["Comparing"].aggregate("Item")
    item.queries.find { |declared| "Comparing::Item.#{declared.hecks_name}" == step["query"] }.wheres.map { |where| where.op.to_s }
  end

  def answered_codes(step)
    asked = self.class.history[:queries].find { |entry| entry[:query] == step["query"] }
    asked[:rows].map { |row| Hecks::Runtime::Value.materialize(row[:code])[:value] }
  end

  def sqlite_parity(steps) = Hecks::Fuzzing::PersistenceParity.diff(self.class.fixture, steps, left: :memory, right: :sqlite)

  Hecks::Vocabulary.fetch("QueryComparator").each do |comparator|
    it "answers the expected rows for a query comparing by #{comparator}" do
      steps = self.class.queries_by_comparator.fetch(comparator, [])
      expect(steps).not_to be_empty
      steps.each { |step| expect(answered_codes(step)).to match_array(step["expect"]) }
    end
  end

  it "agrees with the reference engine on every comparator's answer" do
    expect(Hecks::Fuzzing::Properties.query_answers_match_reference(self.class.history)).to be(true)
  end

  # `none_in_state` included: SQLite answers it over the aggregate's records, not in SQL.
  it "answers every comparator the same on Memory and SQLite" do
    expect(sqlite_parity(self.class.steps)).to be_empty
  end
end
