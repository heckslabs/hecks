require "spec_helper"
require "json"
require "open3"

# The lessons triaged on 2026-11-02, as committed data. Each kind has a signature, a cause, a check
# and a fix, and each sighting names the run and commit it was seen in.
RSpec.describe "the seeded lessons" do
  let(:seed) { JSON.parse(File.read(File.join(InMemoryDomain::ROOT, "lib/hecks/tickets/lessons/seed.json"))) }
  let(:lessons) { seed.fetch("lessons") }

  it "seeds the triaged kinds, the attribution trailer and the unverified push" do
    expect(lessons.map { |lesson| lesson["kind"] }).to eq(
      %w[new-word-without-repo-specs generated-output-not-regenerated dsl-word-without-coverage
         spec-green-alone-red-in-shard spec-writes-owner-state timing-budget-on-slow-runner
         claude-attribution-trailer push-carried-unverified-commits]
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

  it "gives every sighting a run that is a number or unknown" do
    runs = lessons.flat_map { |lesson| lesson.fetch("sightings").map { |sighting| sighting["run"] } }
    expect(runs).to all(match(/\A(\d+|unknown)\z/))
  end

  it "gives every sighting a commit that exists in git" do
    commits = lessons.flat_map { |lesson| lesson.fetch("sightings").map { |sighting| sighting["commit"] } }
    expect(commits.reject { |commit| commit_exists?(commit) }).to be_empty
  end

  def commit_exists?(commit)
    _out, status = Open3.capture2e("git", "cat-file", "-e", "#{commit}^{commit}", chdir: InMemoryDomain::ROOT)
    status.success?
  end
end
