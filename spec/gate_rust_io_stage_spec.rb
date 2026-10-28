require "spec_helper"
require "yaml"
require "hecks/tools"

# The `rust_io` stage of the Vocabulary gate rows runs the specs ci-rust-io.yml's `rspec_rust_io`
# job runs, so a person can ask before a push. These specs hold the stage to the workflow's matrix,
# so a spec file cannot be added to one and not the other.
RSpec.describe "the rust_io gate stage" do
  let(:root) { File.expand_path("..", __dir__) }
  let(:stages) { Hecks::Tools.fetch("gate").stages }
  let(:workflow) { YAML.load_file(File.join(root, ".github/workflows/ci-rust-io.yml")) }
  let(:script) { stages.dig("rust_io", "checks").flat_map { |check| check["run"] }.join("\n") }
  let(:legs) { workflow.dig("jobs", "rspec_rust_io", "strategy", "matrix", "include").map { |leg| leg["specs"] } }

  it "sets CI as the job does, so a skipped example fails here as it fails there" do
    expect(stages.dig("rust_io", "env", "CI")).to eq("true")
  end

  it "materializes the generated Rust, then builds the banking crate, before any spec, as the job does" do
    steps = ["regeneration_run.regenerate_corpus --confirm --wait",
             "exe/hecks build.project_rust domain=examples/banking --wait", "rspec"]

    expect(steps.map { |step| script.index(step) }).to eq(steps.map { |step| script.index(step) }.sort)
  end

  it "restores the tracked files the crate build rewrites, and refuses to start over edits to them", :aggregate_failures do
    expect(script).to include("rewritten=\"rust/Cargo.toml rust/src/generated/mod.rs\"")
    expect(script).to include("trap 'git checkout -q -- $rewritten' EXIT")
    expect(script.index("git status --porcelain -- $rewritten")).to be < script.index("trap ")
  end

  it "runs each leg's spec files in order, one rspec process per leg", :aggregate_failures do
    expect(legs).not_to be_empty
    legs.each { |specs| expect(script).to include("rspec --tag io --profile 8 #{specs}\n") }
    expect(legs.map { |specs| script.index(specs) }).to eq(legs.map { |specs| script.index(specs) }.sort)
  end

  it "has the regeneration leg skip every step that waits for or fetches feature binaries", :aggregate_failures do
    steps = workflow.dig("jobs", "rspec_rust_io", "steps")
    heavy = ["Remove pinned feature", "Restore the built feature", "Wait for the feature",
             "Fetch the feature", "Build the Rust conformance"]
    feature_steps = steps.select { |step| heavy.any? { |start| step["name"].to_s.start_with?(start) } }

    expect(feature_steps).not_to be_empty
    feature_steps.each { |step| expect(step["if"].to_s).to include("matrix.leg != 'c'"), step["name"] }
  end

  it "names no spec file the workflow's matrix does not" do
    expect(script.scan(%r{spec/\S+_spec\.rb}).sort).to eq(legs.flat_map(&:split).sort)
  end
end
