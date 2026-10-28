require "spec_helper"
require "yaml"
require "hecks/tools"

# The fuzz sweeps run as shards, one matrix leg each, and still report as the two logical checks
# `checks_fuzz` and `checks_fuzz_sqlite`. These specs hold the legs, the gate checks they run and
# the names that vouch for them to one another, so a leg cannot go missing or a name drift without
# a red spec: a sweep with a leg short would pass over the domains that leg sweeps.
RSpec.describe "the sharded fuzz jobs of ci-checks.yml", :aggregate_failures do
  # The job that sweeps each adapter, and the adapter its shard checks name (none for Memory).
  FUZZ_JOBS = { "checks_fuzz" => nil, "checks_fuzz_sqlite" => "sqlite" }.freeze
  SHARD_COMMAND = %r{fuzz_run\.fuzz(?: adapter=(?<adapter>\w+))?.* shard=(?<number>\d+)/(?<count>\d+) --wait}

  def workflow(name) = YAML.load_file(File.join(File.expand_path("..", __dir__), ".github/workflows/#{name}"))

  def checks_yml = @checks_yml ||= workflow("ci-checks.yml")

  def ci_yml = @ci_yml ||= workflow("ci.yml")

  def ci_checks = Hecks::Tools.fetch("gate").stages.dig("ci", "checks")

  def static_runs = checks_yml.dig("jobs", "checks_static", "steps").filter_map { |step| step["run"] }

  def id_stem(adapter) = adapter ? "fuzz_#{adapter}" : "fuzz"

  # The shard checks of the ci stage for one adapter: [id, number, count] each.
  def shard_checks(adapter)
    ci_checks.filter_map do |check|
      match = SHARD_COMMAND.match(check.fetch("run").join(" "))
      [check.fetch("id"), match[:number].to_i, match[:count].to_i] if match && match[:adapter] == adapter
    end
  end

  # What a job's `only=` names, once for each leg of its matrix.
  def leg_ids(job)
    command = job.fetch("steps").filter_map { |step| step["run"] }.find { |run| run.include?("matrix.shard") }
    job.dig("strategy", "matrix", "shard").map { |leg| command[/only=(.+?) --wait/, 1].gsub("${{ matrix.shard }}", leg.to_s) }
  end

  FUZZ_JOBS.each do |name, adapter|
    describe name do
      it "has a gate check for every shard, named for its adapter, number and count" do
        shards = shard_checks(adapter)
        count = shards.first.last

        expect(shards.map(&:last).uniq).to eq([count])
        expect(shards.map { |_, number, _| number }.sort).to eq((1..count).to_a)
        expect(shards.map(&:first).sort).to eq((1..count).map { |number| "#{id_stem(adapter)}_#{number}_of_#{count}" })
      end

      it "runs a leg for each number from 1 to the shard count, and each leg runs its own check" do
        shards = shard_checks(adapter)
        job = checks_yml.fetch("jobs").fetch(name)

        expect(job.dig("strategy", "matrix", "shard")).to eq((1..shards.first.last).to_a)
        expect(leg_ids(job).sort).to eq(shards.map(&:first).sort)
      end

      it "lets every leg finish and none fail quietly, so the job is red when any shard is" do
        job = checks_yml.fetch("jobs").fetch(name)

        expect(job.dig("strategy", "fail-fast")).to be(false)
        expect(job).not_to have_key("continue-on-error")
        expect(job.fetch("steps").filter_map { |step| step["continue-on-error"] }).to be_empty
      end
    end
  end

  it "keeps no unsharded fuzz sweep in the ci stage, so no check stands for a sweep that no job runs" do
    expect(ci_checks.map { |check| check["id"] }).not_to include("fuzz", "fuzz_sqlite")
  end

  it "sweeps both adapters in the same number of shards, and lists that split in the static job" do
    counts = FUZZ_JOBS.values.map { |adapter| shard_checks(adapter).first.last }
    listing = ci_checks.find { |check| check["id"] == "fuzz_shards" }.fetch("run").join(" ")

    expect(counts.uniq.size).to eq(1)
    expect(listing).to include("fuzz_run.fuzz list_shards=#{counts.first} ")
    expect(static_runs).to include("bundle exec exe/hecks gate_run.gate stage=ci only=fuzz_shards --wait")
  end

  # The names an attestation note vouches for: a leg's own name would let one passing shard vouch
  # for a sweep that two must make.
  describe "the attestation name lists" do
    def checks_of(job, action)
      steps = job.fetch("steps", []).select { |step| step["uses"].to_s.end_with?(action) }
      steps.map { |step| step.dig("with", "checks").split(",") }
    end

    it "name the sweeps as the logical checks, and never a shard of one" do
      jobs = checks_yml.fetch("jobs").values + ci_yml.fetch("jobs").values
      lists = jobs.flat_map { |job| checks_of(job, "check-attestation") + checks_of(job, "write-attestation") }

      expect(lists.flatten).to all(satisfy { |name| !name.match?(/fuzz\w*_\d+(_of_\d+)?\z/) })
      expect(lists.flatten.uniq).to include(*FUZZ_JOBS.keys)
    end

    it "name the sweeps where the sharded jobs are detected and where their note is written" do
      detected = checks_of(checks_yml.dig("jobs", "ci_attestation_checks_heavy"), "check-attestation").flatten
      written = checks_of(ci_yml.dig("jobs", "ci_attest_write"), "write-attestation").flatten

      expect(detected).to include(*FUZZ_JOBS.keys)
      expect(written).to include(*FUZZ_JOBS.keys)
    end

    it "write a note only when the whole checks call succeeded, which every leg's result is part of" do
      expect(ci_yml.dig("jobs", "ci_attest_write", "if")).to include("needs.checks_impl.result == 'success'")
      expect(ci_yml.dig("jobs", "checks", "if")).to eq("always() && needs.checks_impl.result != 'success'")
    end
  end
end
