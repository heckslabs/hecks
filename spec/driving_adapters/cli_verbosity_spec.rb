require "spec_helper"
require_relative "../support/memory_ports"

# The launcher's `-q` and `-v` levels: `-q` keeps the result and any refusal; `-v` adds the
# command, its checkout and stores, and the time it took, on standard error.
RSpec.describe Hecks::Adapters::Driving::CliRunner do
  let(:runtime) { boot_in_memory }
  let(:err) { StringIO.new }

  def run_at(*argv) = described_class.call(runtime: runtime, argv: argv, program: "hecks run", err: err)
  def status(*argv) = run_at(*argv).last
  def pizza = %w[order.create_pizza! name=Margherita pizza.price_cents.cents=1200 pizza.size.value=large]

  it "refuses -q with -v as a usage line" do
    expect(status("-q", "-v", "order.create_pizza!")).to eq(Hecks::Adapters::Driving::ExitStatus::USAGE)
  end

  it "keeps a refusal under -q" do
    expect(run_at("-q", "order.create_pizza!").first).to include("was not given name")
  end

  it "adds the command and its duration on standard error under -v" do
    run_at("-v", *pizza)
    expect(err.string).to include("command order.create_pizza")
  end

  it "prints the duration under -v" do
    run_at("-v", *pizza)
    expect(err.string).to match(/took \d+\.\d\ds/)
  end

  it "leaves the default level as it was" do
    run_at(*pizza)
    expect(err.string).not_to include("took ")
  end

  it "silences stage progress only while -q runs" do
    seen = described_class.with_verbosity(:quiet) { Hecks::Tools::StageProgress.quiet }
    expect([seen, Hecks::Tools::StageProgress.quiet]).to eq([true, false])
  end

  it "writes no stage line when progress is quiet" do
    expect(quiet_stage_line).to be_empty
  end

  def quiet_stage_line
    io = StringIO.new
    Hecks::Tools::StageProgress.quiet = true
    Hecks::Tools::StageProgress.new(io).start("rubocop")
    io.string
  ensure
    Hecks::Tools::StageProgress.quiet = false
  end
end
