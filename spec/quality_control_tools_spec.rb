require "spec_helper"
require "hecks/quality_control/adapters/sweep_tools"

# The `qa_*` scripts as queries of the QualityControl chapter: each is answered by a `*Tools`
# port whose adapter runs the script's own command in a child process and hands back what it
# printed. What needs the ledger's Postgres is proven by the `:io` specs that run the scripts.
RSpec.describe "the QualityControl tool queries" do
  NOVELTY_FIXTURES_DIR = File.join(InMemoryDomain::ROOT, "spec/fixtures/qa_domain_novelty").freeze

  before(:all) do
    @hecks = Hecks.boot(File.join(InMemoryDomain::ROOT, "lib/hecks/hecks"), install_doors: false)
    @chapter = @hecks.registry.bluebook("QualityControl")
  end

  def launch(*argv) = Hecks::Doors::CliRunner.call(runtime: @hecks, argv: argv, program: "hecks")

  # Every query the chapter answers by a port, with the port's name and the aggregate it belongs to.
  def tool_queries
    @chapter.aggregates.flat_map do |aggregate|
      aggregate.queries.filter_map do |query|
        port = aggregate.query_binding(query.name)
        [aggregate, query, port.name] if port
      end
    end
  end

  it "answers twelve scripts by four ports" do
    expect(tool_queries.map { |_, _, port| port }.uniq.sort)
      .to eq(%w[AngleTools ClearanceTools SweepTools TargetTools])
    expect(tool_queries.size).to eq(12)
  end

  it "binds one adapter to each port, and the adapter has a method for every query it answers" do
    tool_queries.each do |aggregate, query, port|
      adapters = @hecks.registry.adapters.values.select { |adapter| adapter.port == port }

      expect(adapters.size).to eq(1), "#{port} is bound to #{adapters.map(&:name)}"
      klass = Hecks::Adapters.const_get(adapters.first.name)
      answered = "#{klass} answers #{aggregate.hecks_name}.#{query.name}"
      expect(klass.method_defined?(Hecks::Naming.snake(query.name))).to be(true), answered
    end
  end

  it "runs the novelty gate through the launcher and answers its report" do
    out, status = launch("quality_control", "judge_novelty", "domain=#{File.join(NOVELTY_FIXTURES_DIR, 'hopper')}",
                         "arguments=--against #{File.join(NOVELTY_FIXTURES_DIR, 'baseline')}")

    expect(status).to eq(0), out
    expect(out).to include("earns its place", "Hopper::Proposal")
  end

  it "answers a judgment that is not a pass, as the command does: no new pair is still an answer" do
    out, status = launch("quality_control", "judge_novelty", "domain=#{File.join(NOVELTY_FIXTURES_DIR, 'baseline')}",
                         "arguments=--against #{File.join(NOVELTY_FIXTURES_DIR, 'hopper')}")

    expect(status).to eq(0), out
    expect(out).to include("no new pair")
  end

  it "refuses with the command's own report when it ends in an error" do
    out, status = launch("quality_control", "judge_novelty", "domain=#{File.join(NOVELTY_FIXTURES_DIR, 'flat.bluebook')}",
                         "arguments=--against #{File.join(NOVELTY_FIXTURES_DIR, 'baseline')}")

    expect(status).to eq(1)
    expect(out).to include("not shaped like a stress domain", "ended with status 2")
  end

  it "answers help for the sweep by asking for it: bare `run` is the CI port's" do
    out, status = launch("quality_control", "ask", "run", "--help")

    expect(status).to eq(0)
    expect(out).to include("reads QualityControl::Sweep.Run", "arguments.value")
  end

  describe Hecks::Adapters::QaTool do
    let(:tool) { Hecks::Adapters::SweepTools.new(root: "/repo") }

    def ended_with(status, output = "report\n")
      allow(Open3).to receive(:capture2e).and_return([output, instance_double(Process::Status, exitstatus: status)])
    end

    it "answers what the command printed when it ends with an answering status" do
      ended_with(2, "FOUND SOMETHING\n")

      expect(tool.tick).to eq(text: "FOUND SOMETHING\n")
    end

    it "refuses with the report and the status when it ends with any other" do
      ended_with(1, "the ledger did not boot\n")

      expect { tool.tick }.to raise_error(Hecks::Adapters::QaTool::ToolRefused, /the ledger did not boot.*status 1/m)
    end

    it "refuses as a GivenNotMet, so the launcher reports it, though no guard description quotes it" do
      ended_with(1, "the ledger did not boot\n")

      expect { tool.tick }.to raise_error(Hecks::Runtime::GivenNotMet)
    end

    it "hands the command its arguments, a value object's text and a flag string split as a shell would" do
      expect(Open3).to receive(:capture2e) do |*argv, **|
        expect(argv[(argv.index("--") + 1)..]).to eq(["banking", "--seeds", "5", "--notes", "two words"])
        expect(argv[argv.index("-e") + 1]).to include("qa_sweep")
        ["", instance_double(Process::Status, exitstatus: 0)]
      end

      tool.run(target: { value: "banking" }, arguments: { value: "--seeds 5 --notes 'two words'" })
    end

    it "starts each command in the checkout it was given" do
      expect(Open3).to receive(:capture2e) do |*_argv, **options|
        expect(options).to eq(chdir: "/repo")
        ["", instance_double(Process::Status, exitstatus: 0)]
      end

      tool.tick
    end
  end
end
