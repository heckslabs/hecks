require "spec_helper"
require "hecks/hecks/adapters/codebase/cargo_tests"
require "hecks/hecks/adapters/codebase/tree"
require_relative "../../support/fake_codebase_shell"

# `test_suite_run.run_cargo_tests`: cargo test for a crate, with the seed counts its fuzzers read.
RSpec.describe Hecks::Adapters::Codebase::CargoTests do
  let(:tree) { Hecks::Adapters::Codebase::Tree.new }
  let(:shell) { FakeCodebaseShell.new(["1 test passed", 0]) }

  def run_for(**args) = described_class.run(args, tree, shell)

  it "gives the host's fuzzer its seed count in the variable it reads" do
    run_for(crate: "host", seeds: 2000)

    expect(shell.env).to eq("HOST_FUZZ_SEEDS" => "2000")
  end

  it "gives the parser's fuzzer an iteration count and a first seed", :aggregate_failures do
    run_for(crate: "parser", seeds: 500, seed_start: 7)

    expect(shell.env).to eq("HECKS_PARSE_FUZZ_ITERATIONS" => "500", "HECKS_PARSE_FUZZ_SEED" => "7")
  end

  it "runs the JSON fuzzer's own test target from the root crate", :aggregate_failures do
    run_for(crate: "json", seeds: 30)

    expect(shell.command).to eq(%w[test --test json_parse_fuzz])
    expect(shell.env).to eq("JSON_FUZZ_SEEDS" => "30")
  end

  it "sets nothing when no count is named", :aggregate_failures do
    run_for(crate: "host")

    expect(shell.env).to eq({})
    expect(shell.asked.first[:chdir]).to end_with("rust/host")
  end

  it "answers what cargo printed" do
    expect(run_for(crate: "host")).to eq("1 test passed")
  end

  it "refuses with cargo's output when a test fails" do
    failing = FakeCodebaseShell.new(["test fuzz ... FAILED", 101])

    expect { described_class.run({ crate: "host" }, tree, failing) }
      .to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /FAILED/)
  end
end
