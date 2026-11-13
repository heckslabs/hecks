require "spec_helper"
require_relative "support/parallel_default"

# A bare `rspec` hands over to `parallel_rspec`; nothing else that loads the specs does.
RSpec.describe ParallelDefault do
  let(:quiet) { {} }

  it "hands over a bare rspec run" do
    expect(described_class.applies?(argv: [], env: quiet, program: "/usr/bin/rspec")).to be(true)
  end

  it "keeps a run with arguments, a worker or CI serial", :aggregate_failures do
    expect(described_class.applies?(argv: ["spec/a_spec.rb"], env: quiet, program: "rspec")).to be(false)
    expect(described_class.applies?(argv: [], env: { "TEST_ENV_NUMBER" => "" }, program: "rspec")).to be(false)
    expect(described_class.applies?(argv: [], env: { "CI" => "1" }, program: "rspec")).to be(false)
  end

  it "hands over at the world's worker count, not one worker per core" do
    expect(described_class.command(workers: 6).each_cons(2)).to include(["-n", "6"])
  end

  it "takes its worker count from the spec workers cap" do
    expect(described_class.command.each_cons(2).to_a).to include(["-n", Hecks::Adapters::Codebase::SpecWorkers.count(Dir.pwd).to_s])
  end

  it "leaves another program alone even with an empty argv, such as an MCP server running one example" do
    expect(described_class.applies?(argv: [], env: quiet, program: "-e")).to be(false)
  end
end
