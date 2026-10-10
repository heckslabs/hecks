require "spec_helper"
require "tmpdir"
require_relative "../../../lib/hecks/hecks/adapters/process_pool"
require_relative "../../support/thread_parking"

# The ProcessPool port's adapter starts a long-running child and stays with it until it ends.
RSpec.describe Hecks::Adapters::ProcessPool do
  let(:pool) { described_class.new }

  after { described_class.starter = nil }

  it "answers what a child wrote, stdout and stderr together, and how it ended", :aggregate_failures do
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

  it "answers a program that is not installed as a failure with a reason, not a raise", :aggregate_failures do
    finished = pool.run(["no-such-program-anywhere"])

    expect(finished).not_to be_ok
    expect(finished.output).to include("no-such-program-anywhere")
  end

  it "does not block on a child that writes more than a pipe holds" do
    finished = pool.run(["sh", "-c", "head -c 300000 /dev/zero | tr '\\0' x"])

    expect(finished.output.size).to eq(300_000)
  end

  # Whether this process has spawned the long child; the pool installs its signal handlers first.
  def long_child_spawned?
    system("pgrep", "-P", Process.pid.to_s, "-f", "sleep 30", out: File::NULL)
  end

  # Starts a long child, then interrupts this process as its launcher would be; answers how it
  # ended.
  def run_child_then_interrupt
    runner = Thread.new { pool.run(["sh", "-c", "sleep 30"]) }
    ThreadParking.wait_for { long_child_spawned? }
    Process.kill("TERM", Process.pid)
    runner.value
  end

  it "passes an interrupt on to the child, so stopping the launcher stops its workers", :aggregate_failures, :io do
    finished = run_child_then_interrupt

    expect(finished).not_to be_ok
    expect(finished.status.signaled?).to be(true)
  end

  # Raises `name` against this process just before the child is spawned.
  def signal_before_spawn(name)
    real = Process.method(:spawn)
    allow(pool).to receive(:spawn) do |*args, **opts|
      Process.kill(name, Process.pid)
      ThreadParking.elapse(0.05)
      real.call(*args, **opts)
    end
  end

  %w[INT TERM HUP QUIT].each do |name|
    it "forwards a #{name} that arrives while the child is still being spawned", :aggregate_failures do
      signal_before_spawn(name)

      finished = pool.run(["sh", "-c", "sleep 30"])

      expect(finished.status.signaled?).to be(true)
      expect(finished.status.termsig).to eq(Signal.list.fetch(name))
    end
  end

  def trapped_handlers = %w[INT TERM HUP QUIT].to_h { |name| [name, trap(name, "DEFAULT")] }

  it "restores the previous signal handlers afterwards" do
    before = trapped_handlers
    pool.run(["true"])
    expect(trapped_handlers.values).to all(eq("DEFAULT"))
  ensure
    before&.each { |name, handler| trap(name, handler) }
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
    let!(:asked) { start_with(clean) }

    context "with every flag held" do
      let(:answer) do
        pool.sweep(domain: { value: "domains/pizzas" }, seeds: { value: 5 }, steps: { value: 7 },
                   workers: { value: 2 }, adapter: { value: "sqlite" })
      end
      let(:command) { answer && asked.first.fetch(:command) }

      it "runs the fuzz tool as a script over this checkout's lib", :aggregate_failures do
        expect(command[1..3]).to eq(["-I", described_class::LIB, "-e"])
        expect(command[4]).to include('Hecks::Tools.script("fuzz", ARGV)')
      end

      it "passes the flags the record holds, and the domain first" do
        expect(command.drop(6)).to eq(%w[domains/pizzas --seeds 5 --steps 7 --workers 2 --adapter sqlite])
      end

      it "answers its report" do
        expect(answer).to eq(report: { value: "CLEAN\n" })
      end
    end

    it "leaves out a flag the record does not hold" do
      pool.sweep(domain: { value: "domains/pizzas" })

      expect(asked.first.fetch(:command).drop(6)).to eq(["domains/pizzas"])
    end

    it "refuses with what the sweep printed when it found something" do
      start_with(described_class::Finished.new("FUZZ FOUND SOMETHING.\n", Struct.new(:success?, :exitstatus).new(false, 1)))

      expect { pool.sweep(domain: { value: "domains/pizzas" }) }
        .to raise_error(Hecks::Adapters::ConsoleCapture::Failure, "FUZZ FOUND SOMETHING.")
    end

    it "refuses to sweep every domain outside a hecks checkout, and names how to sweep one", :aggregate_failures do
      outside = instance_double(Hecks::Adapters::RustWorkspace, checkout?: false)
      allow(Hecks::Adapters::RustWorkspace).to receive(:new).and_return(outside)

      expect { pool.sweep }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /name a domain/)
      expect(asked).to be_empty
    end
  end
end
