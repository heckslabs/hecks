require "spec_helper"
require "json"
require "open3"

# The lessons triaged on 2026-11-02 and 2026-11-03, as committed data. Each kind has a signature, a
# cause, a check and a fix, and each sighting names the CI run and the red commit it was seen in.
RSpec.describe "the seeded lessons" do
  let(:seed) { JSON.parse(File.read(File.join(InMemoryDomain::ROOT, "lib/hecks/tickets/lessons/seed.json"))) }
  let(:lessons) { seed.fetch("lessons") }
  let(:sightings) { lessons.flat_map { |lesson| lesson.fetch("sightings") } }

  # Whether the checkout holds only part of its history, as the CI shards' depth-1 clone does.
  def shallow?
    out, = Open3.capture2("git", "-C", InMemoryDomain::ROOT, "rev-parse", "--is-shallow-repository")
    out.strip == "true"
  end

  # Whether the checkout's git knows the commit. A shallow checkout holds only its tip, so there the
  # sha's form is all that can be read; the landing's own checkout holds the history and reads git.
  def commit?(sha)
    return sha.match?(/\A\h{9,40}\z/) if shallow?

    _, status = Open3.capture2e("git", "-C", InMemoryDomain::ROOT, "cat-file", "-e", "#{sha}^{commit}")
    status.success?
  end

  it "seeds the triaged kinds, the attribution trailer and the kinds seen on 2026-11-03" do
    expect(lessons.map { |lesson| lesson["kind"] }).to eq(
      %w[new-word-without-repo-specs generated-output-not-regenerated dsl-word-without-coverage
         spec-green-alone-red-in-shard spec-writes-owner-state timing-budget-on-slow-runner
         claude-attribution-trailer push-carried-unverified-commits attached-member-conflicting-persistence]
    )
  end

  it "gives every kind a signature, a cause, a check and a fix", :aggregate_failures do
    lessons.each do |lesson|
      expect(lesson.values_at("signature", "cause", "check", "fix").map { |value| value.to_s.empty? }).to all(be false)
    end
  end

  it "names the run and the commit of every sighting" do
    expect(sightings).to all(include("run", "commit"))
  end

  it "names a sighting's run by its CI run id, or says it is unknown" do
    expect(sightings.map { |sighting| sighting["run"] }).to all(match(/\A(\d+|unknown)\z/))
  end

  it "never names a commit as its own run" do
    expect(sightings.select { |sighting| sighting["run"] == sighting["commit"] }).to be_empty
  end

  it "names a red commit git holds for every sighting" do
    expect(sightings.map { |sighting| sighting["commit"] }.reject { |sha| commit?(sha) }).to be_empty
  end
end
