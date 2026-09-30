require "spec_helper"
require "tmpdir"
require_relative "../../../lib/hecks/hecks/adapters/process_pool"

# The ProcessPool port's adapter starts a long-running child and stays with it until it ends.
RSpec.describe Hecks::Adapters::ProcessPool do
  let(:pool) { described_class.new }

  after { described_class.starter = nil }

  it "answers what a child wrote, stdout and stderr together, and how it ended" do
    finished = pool.run(["sh", "-c", "echo out; echo err >&2; exit 3"])

    expect(finished.output).to include("out").and include("err")
    expect(finished).not_to be_ok
    expect(finished.status.exitstatus).to eq(3)
  end

  it "runs a child in the directory and with the variables it is given" do
    Dir.mktmpdir("pool") do |dir|
      finished = pool.run(["sh", "-c", "echo $POOL_SPEC-$(basename $PWD)"], env: { "POOL_SPEC" => "x" }, chdir: dir)

      expect(finished.output.strip).to eq("x-#{File.basename(File.realpath(dir))}")
    end
  end

  it "answers a program that is not installed as a failure with a reason, not a raise" do
    finished = pool.run(["no-such-program-anywhere"])

    expect(finished).not_to be_ok
    expect(finished.output).to include("no-such-program-anywhere")
  end

  it "does not block on a child that writes more than a pipe holds" do
    finished = pool.run(["sh", "-c", "head -c 300000 /dev/zero | tr '\\0' x"])

    expect(finished.output.size).to eq(300_000)
  end

  it "passes an interrupt on to the child, so stopping the launcher stops its workers", :io do
    started = Queue.new
    runner = Thread.new do
      started << true
      pool.run(["sh", "-c", "sleep 30"])
    end
    started.pop
    sleep 0.5
    Process.kill("TERM", Process.pid)

    finished = runner.value
    expect(finished).not_to be_ok
    expect(finished.status.signaled?).to be(true)
  end

  describe "#sweep" do
    def start_with(finished)
      asked = []
      described_class.starter = lambda do |command, env, chdir|
        asked << { command: command, env: env, chdir: chdir }
        finished
      end
      asked
    end

    let(:clean) { described_class::Finished.new("CLEAN\n", Struct.new(:success?, :exitstatus).new(true, 0)) }

    it "runs the fuzz tool with the flags the record holds, and answers its report" do
      asked = start_with(clean)

      answer = pool.sweep(domain: { value: "domains/pizzas" }, seeds: { value: 5 }, steps: { value: 7 },
                          workers: { value: 2 }, adapter: { value: "sqlite" })

      command = asked.first.fetch(:command)
      expect(command[1..3]).to eq(["-I", described_class::LIB, "-e"])
      expect(command[4]).to include('Hecks::Tools.script("fuzz", ARGV)')
      expect(command.drop(6)).to eq(%w[domains/pizzas --seeds 5 --steps 7 --workers 2 --adapter sqlite])
      expect(answer).to eq(report: { value: "CLEAN\n" })
    end

    it "leaves out a flag the record does not hold" do
      asked = start_with(clean)

      pool.sweep(domain: { value: "domains/pizzas" })

      expect(asked.first.fetch(:command).drop(6)).to eq(["domains/pizzas"])
    end

    it "refuses with what the sweep printed when it found something" do
      start_with(described_class::Finished.new("FUZZ FOUND SOMETHING.\n", Struct.new(:success?, :exitstatus).new(false, 1)))

      expect { pool.sweep(domain: { value: "domains/pizzas" }) }
        .to raise_error(Hecks::Adapters::ConsoleCapture::Failure, "FUZZ FOUND SOMETHING.")
    end

    it "refuses to sweep every domain outside a hecks checkout, and names how to sweep one" do
      # rubocop:disable-next RSpec/AnyInstance
      allow_any_instance_of(Hecks::Adapters::RustWorkspace).to receive(:checkout?).and_return(false)
      asked = start_with(clean)

      expect { pool.sweep }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /name a domain/)
      expect(asked).to be_empty
    end
  end
end
