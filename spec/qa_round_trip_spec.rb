require "spec_helper"
require "tmpdir"
require "stringio"
require "hecks/quality_control/cli/qa_round_trip"

# The recovery benchmark: a generated domain, a battery of protocol scripts with Hecks's answers,
# and scores for a program or a recovered domain against them.
RSpec.describe Hecks::QualityControlCli::QaRoundTrip do
  before(:context) do
    @dir = Dir.mktmpdir("round_trip")
    @bench_path = File.join(@dir, "bench")
    run_tool("prepare", "--seed", "46", "--out", @bench_path, "--scripts", "3", "--steps", "25")
  end

  after(:context) { FileUtils.rm_rf(@dir) }

  let(:bench) { Hecks::QualityControlCli::QaRoundTrip::Bench.new(@bench_path) }

  def run_tool(*argv)
    out = StringIO.new
    [described_class.call(argv, root: Dir.pwd, out: out), out.string]
  end

  # A copy of the key with its first `given` deleted: a recovery that dropped a guard.
  def guardless_domain
    copy = File.join(@dir, "guardless")
    FileUtils.rm_rf(copy)
    FileUtils.cp_r(bench.key_domain, copy)
    path = Dir[File.join(copy, "bluebook", "*.bluebook")].first
    File.write(path, File.read(path).sub(/^\s*given\(.*\n/, ""))
    copy
  end

  # A program that answers the protocol by playing each script through the key domain.
  def hecks_program
    script = File.join(@dir, "hecks_program.rb")
    File.write(script, <<~RUBY)
      require "hecks"; require "json"; require "hecks/quality_control/cli/qa_round_trip/player"
      lines = Hecks::QualityControlCli::QaRoundTrip::Player.new(ARGV[0]).play(JSON.parse($stdin.read))
      lines.each { |line| puts JSON.generate(line) }
    RUBY
    "#{RbConfig.ruby} -I#{File.join(Dir.pwd, "lib")} #{script} #{bench.key_domain}"
  end

  it "writes the key, the implementer's brief and a battery with Hecks's answers", :aggregate_failures do
    expect(Dir[File.join(@bench_path, "battery", "*.ref")].size).to eq(3)
    expect(%w[spec.bluebook PROTOCOL.md prompts/implementer.md prompts/analyst.md].map do |f|
      File.exist?(File.join(@bench_path, f))
    end).to all(be(true))
    expect(bench.key_domain).not_to be_nil
  end

  it "scores the key domain against its own answers as agreeing" do
    expect(run_tool("score", "--bench", @bench_path, "--domain", bench.key_domain).first).to eq(described_class::EXIT_AGREED)
  end

  it "scores a program that answers as the key does as agreeing", :process do
    expect(run_tool("score", "--bench", @bench_path, "--program", hecks_program).first).to eq(described_class::EXIT_AGREED)
  end

  it "scores a program that prints nothing as disagreeing", :process do
    expect(run_tool("score", "--bench", @bench_path, "--program",
                    "#{RbConfig.ruby} -e 0").first).to eq(described_class::EXIT_DISAGREED)
  end

  it "fails a domain that dropped a guard and names it, even when no script refused by it", :aggregate_failures do
    status, report = run_tool("score", "--bench", @bench_path, "--domain", guardless_domain)
    expect(status).to eq(described_class::EXIT_DISAGREED)
    expect(report).to match(/-- missing\n\s+given: \w+\.Open: /)
  end

  it "rewrites a fuzzer step in the protocol: no domain, plain values, the record by its reference key" do
    protocol = described_class::Protocol.new(Hecks.boot(bench.key_domain, environment: nil).registry.bluebook("QaGenerated").to_h)
    step = { "verb" => "QaGenerated::Venue.Close", "args" => { "code" => { "value" => "V1" } } }
    expect(protocol.step(step)).to eq("command" => "Venue.Close", "args" => { "venue" => "V1" })
  end

  it "counts a step one run accepted and the other refused" do
    comparison = described_class::Comparison.new
    comparison.add("s", [{ "step" => 0, "ok" => true, "events" => ["A"] }], [{ "step" => 0, "ok" => false, "events" => [] }])
    expect(comparison.report).to include("accepted_vs_refused: 1")
  end

  it "reports which commands the battery never refused or never accepted" do
    expect(bench.coverage_report).to match(/\Acoverage/)
  end

  it "refuses to prepare a domain whose aggregate has a composite identity" do
    out = File.join(@dir, "composite")
    expect(run_tool("prepare", "--seed", "1", "--forms", "composite_id", "--out", out, "--scripts",
                    "1").first).to eq(described_class::EXIT_USAGE)
  end

  it "answers an unknown flag with the usage" do
    expect(run_tool("score", "--nope",
                    "x")).to eq([described_class::EXIT_USAGE, "unknown flag --nope\n#{described_class::USAGE}"])
  end
end
