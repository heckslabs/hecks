require "spec_helper"
require "json"

# A red run of main becomes one Work row per failing spec file, and a later settled run closes the
# rows it did not fail. `gh` is stubbed with a fake run payload, so nothing is read from GitHub,
# and the Hecks domain boots in Memory, so no ledger is touched.
RSpec.describe "red specs on main" do
  let(:hecks) { Hecks.boot(File.join(InMemoryDomain::ROOT, "lib/hecks/hecks"), install_driving: false) }
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
  def fake_run(jobs:, failed: [])
    log = failed.map { |path, text| "rspec ./#{path}:12 # #{text}" }.join("\n")
    allow(Open3).to receive(:capture3) do |*argv, **|
      [argv.include?("--log-failed") ? log : { headSha: sha, conclusion: "x", jobs: jobs }.to_json, "", ok_status]
    end
  end

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

  it "files one Work row per failing spec file", :aggregate_failures do
    fake_run(jobs: red_jobs, failed: [%w[spec/lineage_spec.rb a], %w[spec/lineage_spec.rb b], %w[spec/dsl_coverage_spec.rb c]])
    read_run("1")

    expect(work_keys).to contain_exactly("red-spec-lineage_spec", "red-spec-dsl_coverage_spec")
    expect(rows("tickets", "work.undone").find { |row| row["work"] == "red-spec-lineage_spec" })
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

    expect(work_keys).to eq(["red-spec-lineage_spec"])
    expect(rows("quality_control", "red_spec.on_main").first).to include("last_run" => "2")
  end

  it "closes the row of a spec that a later settled run no longer fails", :aggregate_failures do
    red_then(red_jobs, [%w[spec/lineage_spec.rb a]], green_jobs, [])

    expect(work_keys).to be_empty
    expect(red_keys).to be_empty
  end

  it "leaves a spec that is still red open while another one closes", :aggregate_failures do
    red_then(red_jobs, [%w[spec/lineage_spec.rb a], %w[spec/dsl_coverage_spec.rb c]], red_jobs, [%w[spec/lineage_spec.rb a]])

    expect(work_keys).to eq(["red-spec-lineage_spec"])
    expect(red_keys).to eq(["red-spec-lineage_spec"])
  end

  it "closes nothing when the spec jobs did not run to the end" do
    fake_run(jobs: red_jobs, failed: [["spec/lineage_spec.rb", "a"]])
    read_run("1")
    fake_run(jobs: [{ name: "rspec shard 1", conclusion: "cancelled" }])
    read_run("2")

    expect(red_keys).to eq(["red-spec-lineage_spec"])
  end
end
