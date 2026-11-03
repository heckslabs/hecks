require "spec_helper"
require "json"

# The lessons triaged on 2026-11-02, as committed data. Each kind has a signature, a cause, a check
# and a fix, and each sighting names the run and commit it was seen in.
RSpec.describe "the seeded lessons" do
  let(:seed) { JSON.parse(File.read(File.join(InMemoryDomain::ROOT, "lib/hecks/tickets/lessons/seed.json"))) }
  let(:lessons) { seed.fetch("lessons") }

  it "seeds the six triaged kinds and the attribution trailer" do
    expect(lessons.map { |lesson| lesson["kind"] }).to eq(
      %w[new-word-without-repo-specs generated-output-not-regenerated dsl-word-without-coverage
         spec-green-alone-red-in-shard spec-writes-owner-state timing-budget-on-slow-runner
         claude-attribution-trailer]
    )
  end

  it "gives every kind a signature, a cause, a check and a fix", :aggregate_failures do
    lessons.each do |lesson|
      expect(lesson.values_at("signature", "cause", "check", "fix").map { |value| value.to_s.empty? }).to all(be false)
    end
  end

  it "names the run and the commit of every sighting" do
    sightings = lessons.flat_map { |lesson| lesson.fetch("sightings") }
    expect(sightings).to all(include("run", "commit"))
  end
end
