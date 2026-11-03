require "spec_helper"
require "json"

# A red run of main becomes one Work item per failing spec file, and a later settled run closes the
# rows it did not fail. `gh` is stubbed with a fake run payload, so nothing is read from GitHub,
# and the Hecks domain boots in Memory, so no ledger is touched.
RSpec.describe "red specs on main" do
  let(:hecks) { boot_hecks_in_memory }
  let(:sha) { "a" * 40 }
  let(:red_jobs) { [{ name: "rspec shard 1", conclusion: "failure" }] }
  let(:green_jobs) { [{ name: "rspec shard 1", conclusion: "success" }] }

  def cli(context, *argv)
    out, = Hecks::Adapters::Driving::CliRunner.call(runtime: hecks, program: "hecks", argv: [context, *argv])
    out
  end

  def rows(context, query) = JSON.parse(cli(context, query))

  def ok_status = instance_double(Process::Status, success?: true)

  # Answers `gh run view <id> --json ...` with the jobs, and `--log-failed` with the RSpec summary.
  def fake_run(jobs:, failed: [], branch: "main", event: "push", log: nil)
    log ||= failed.map { |path, text| "rspec ./#{path}:12 # #{text}" }.join("\n")
    view = { headSha: sha, headBranch: branch, event: event, conclusion: "x", jobs: jobs }.to_json
    allow(Open3).to receive(:capture3) do |*argv, **|
      [argv.include?("--log-failed") ? log : view, "", ok_status]
    end
  end

  def key(path) = Hecks::Adapters::RunReader.key_for(path)

  def lineage_key = key("spec/lineage_spec.rb")

  # Reads run 1 as given, then run 2 as given.
  def red_then(jobs_one, failed_one, jobs_two, failed_two)
    fake_run(jobs: jobs_one, failed: failed_one)
    read_run("1")
    fake_run(jobs: jobs_two, failed: failed_two)
    read_run("2")
  end

  def read_run(id) = cli("quality_control", "main_run.request!", "run.value=#{id}", "repo=heckslabs/hecks")

  def red_keys = rows("quality_control", "red_spec.on_main").map { |row| row["spec"] }

  def work_keys = rows("tickets", "work.undone").map { |row| row["work"] }

  it "files one Work item per failing spec file", :aggregate_failures do
    fake_run(jobs: red_jobs, failed: [%w[spec/lineage_spec.rb a], %w[spec/lineage_spec.rb b], %w[spec/dsl_coverage_spec.rb c]])
    read_run("1")

    expect(work_keys).to contain_exactly(lineage_key, key("spec/dsl_coverage_spec.rb"))
    expect(rows("tickets", "work.undone").find { |row| row["work"] == lineage_key })
      .to include("title" => "spec/lineage_spec.rb is red on main")
  end

  it "keeps the failure count, first failure, run and sha in the detail" do
    fake_run(jobs: red_jobs, failed: [["spec/lineage_spec.rb", "a"], ["spec/lineage_spec.rb", "b"]])
    read_run("1")

    expect(rows("tickets", "work.undone").first["detail"]).to eq("2 failing examples; first: a; run 1; sha #{sha}")
  end

  it "does not file a spec twice when a second red run sees it again", :aggregate_failures do
    fake_run(jobs: red_jobs, failed: [["spec/lineage_spec.rb", "a"]])
    read_run("1")
    read_run("2")

    expect(work_keys).to eq([lineage_key])
    expect(rows("quality_control", "red_spec.on_main").first).to include("last_run" => "2")
  end

  it "closes the row of a spec that a later settled run no longer fails", :aggregate_failures do
    red_then(red_jobs, [%w[spec/lineage_spec.rb a]], green_jobs, [])

    expect(work_keys).to be_empty
    expect(red_keys).to be_empty
  end

  it "clears nothing from a run whose spec jobs failed, even for a file it no longer fails", :aggregate_failures do
    red_then(red_jobs, [%w[spec/lineage_spec.rb a], %w[spec/dsl_coverage_spec.rb c]], red_jobs, [%w[spec/lineage_spec.rb a]])

    expect(red_keys).to contain_exactly(lineage_key, key("spec/dsl_coverage_spec.rb"))
    expect(work_keys).to contain_exactly(lineage_key, key("spec/dsl_coverage_spec.rb"))
  end

  it "closes nothing when the spec jobs did not run to the end" do
    fake_run(jobs: red_jobs, failed: [["spec/lineage_spec.rb", "a"]])
    read_run("1")
    fake_run(jobs: [{ name: "rspec shard 1", conclusion: "cancelled" }])
    read_run("2")

    expect(red_keys).to eq([lineage_key])
  end

  describe "a run that cannot be trusted to clear" do
    let(:infra_jobs) { [{ name: "rspec_impl", conclusion: "failure" }] }

    def open_lineage = red_then(red_jobs, [%w[spec/lineage_spec.rb a]], infra_jobs, [])

    it "keeps every row open when a spec job failed with no failing example parsed", :aggregate_failures do
      open_lineage

      expect(red_keys).to include(lineage_key)
      expect(work_keys).to include(lineage_key)
    end

    it "reports the unparsed failing job as a row of its own" do
      open_lineage

      expect(rows("tickets", "work.undone").map { |row| row["title"] }).to include(/rspec_impl failed on main/)
    end

    it "clears a failed job's row once a later run passes every spec job", :aggregate_failures do
      open_lineage
      fake_run(jobs: [{ name: "rspec_impl", conclusion: "success" }])
      read_run("3")

      expect(red_keys).to be_empty
      expect(work_keys).to be_empty
    end

    it "does not clear a row when one of two spec jobs passed and the other failed unread" do
      red_then(red_jobs, [%w[spec/lineage_spec.rb a]], [{ name: "rspec a", conclusion: "success" }, *infra_jobs], [])

      expect(red_keys).to include(lineage_key)
    end

    it "does not read a run of another branch" do
      fake_run(jobs: red_jobs, failed: [%w[spec/lineage_spec.rb a]], branch: "feature")
      read_run("1")

      expect(red_keys).to be_empty
    end

    it "does not read a pull request's run on main" do
      fake_run(jobs: red_jobs, failed: [%w[spec/lineage_spec.rb a]], event: "pull_request")
      read_run("1")

      expect(red_keys).to be_empty
    end

    it "does not let a run older than the one that last saw the file fail clear it" do
      fake_run(jobs: red_jobs, failed: [%w[spec/lineage_spec.rb a]])
      read_run("20")
      fake_run(jobs: green_jobs)
      read_run("10")

      expect(red_keys).to eq([lineage_key])
    end

    it "does not let an older red run overwrite what a newer one saw" do
      fake_run(jobs: red_jobs, failed: [%w[spec/lineage_spec.rb a]])
      read_run("20")
      read_run("10")

      expect(rows("quality_control", "red_spec.on_main").first).to include("last_run" => "20")
    end
  end

  describe "reading the log" do
    it "files a spec whose path holds a space" do
      fake_run(jobs: red_jobs, failed: [["spec/my spec_spec.rb", "a"]])
      read_run("1")

      expect(rows("quality_control", "red_spec.on_main").first).to include("path" => "spec/my spec_spec.rb")
    end

    it "reads RSpec's quoted and escaped paths" do
      fake_run(jobs: red_jobs, log: "rspec './spec/q s_spec.rb[1:2]' # a\nrspec ./spec/e\\ s_spec.rb:3 # b")
      read_run("1")

      expect(rows("quality_control", "red_spec.on_main").map { |row| row["path"] })
        .to contain_exactly("spec/q s_spec.rb", "spec/e s_spec.rb")
    end

    it "gives paths that differ by separator or case different keys" do
      paths = %w[spec/a/b_spec.rb spec/a-b_spec.rb spec/Foo_spec.rb spec/foo_spec.rb]

      expect(paths.map { |path| key(path) }.uniq.size).to eq(paths.size)
    end

    it "files each of those paths as its own row" do
      fake_run(jobs: red_jobs, failed: %w[spec/a/b_spec.rb spec/a-b_spec.rb].map { |path| [path, "x"] })
      read_run("1")

      expect(red_keys.size).to eq(2)
    end
  end

  describe "a spec that goes red, green and red again" do
    def cycle
      red_then(red_jobs, [%w[spec/lineage_spec.rb a]], green_jobs, [])
      fake_run(jobs: red_jobs, failed: [%w[spec/lineage_spec.rb b]])
      read_run("3")
    end

    it "reopens the row", :aggregate_failures do
      cycle

      expect(red_keys).to eq([lineage_key])
      expect(rows("quality_control", "red_spec.on_main").first).to include("last_run" => "3")
    end

    it "files the Work item again" do
      cycle

      expect(work_keys).to eq([lineage_key])
    end
  end
end
