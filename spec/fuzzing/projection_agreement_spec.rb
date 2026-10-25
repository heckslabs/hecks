require "spec_helper"
require "hecks/fuzzing"
require_relative "../support/postgres_probe"

# ADR 0122: a rooted read model over a projected aggregate answers the same through its
# projection (the adapter's own read-model path, or the loop over the projection's rows for a
# reducing model) as through the loop over the authoritative records. Banking holds rooted
# read models of every shape: plain, `where`-scoped and each reduction.
RSpec.describe Hecks::Fuzzing::ProjectionAgreement do
  def self.banking = File.join(InMemoryDomain::ROOT, "examples/banking")

  def self.seeds = 1..Integer(ENV.fetch("PROPERTY_SEEDS", "2"))

  def steps(seed) = Hecks::Fuzzing::SequenceGenerator.generate(self.class.banking, seed: seed, steps: 150)

  def outcomes(projection)
    self.class.seeds.map { |seed| described_class.run(self.class.banking, steps(seed), projection: projection) }
  end

  # Swaps in a projection interpreter whose answer differs from the loop's, leaving the loop's
  # own interpreter, built over the authoritative view, untouched.
  def tamper_with_projection_answers
    allow(Hecks::Runtime::ReadModelInterpreter).to receive(:new).and_wrap_original do |original, registry|
      interpreter = original.call(registry)
      next interpreter if registry.is_a?(described_class::Comparison::Authoritative)

      instance_double(Hecks::Runtime::ReadModelInterpreter, call: [{ "tampered" => true }])
    end
  end

  it "agrees on SqliteProjection, over records it actually compared", :aggregate_failures do
    found = outcomes(:sqlite)
    expect(found.flat_map(&:offenders)).to be_empty
    expect(found.sum(&:compared)).to be_positive
  end

  it "names an ask whose projection answer differs from the loop's" do
    tamper_with_projection_answers
    expect(outcomes(:sqlite).flat_map(&:offenders)).to include(/the projection answered \[\{"tampered":true\}\]/)
  end

  # One chapter of the language, whose `WholeBluebook` includes entities (`Handler`, `Dispatch`)
  # beside its aggregates.
  def one_chapter
    args = { strategy: { value: "" }, source_token: "", replacement: { value: "" }, boundary: { value: "" },
             position: { value: "" }, name: { value: "g" } }
    [{ "verb" => "Bluebook::Bluebook.Normalise", "args" => JSON.parse(JSON.generate(args)) }]
  end

  it "agrees on a read model that includes an entity, which holds no rows of its own" do
    language = File.join(InMemoryDomain::ROOT, "lib/hecks/language")
    expect(described_class.check(language, one_chapter, projection: :sqlite)).to be_empty
  end

  it "reports a projection adapter it does not know" do
    expect { described_class.check(self.class.banking, [], projection: :heki) }.to raise_error(ArgumentError, /:heki/)
  end

  it "agrees on PostgresProjection, over records it actually compared", :aggregate_failures, :io do
    skip "no reachable Postgres" unless PostgresProbe.available?

    found = outcomes(:postgres)
    expect(found.flat_map(&:offenders)).to be_empty
    expect(found.sum(&:compared)).to be_positive
  end
end
