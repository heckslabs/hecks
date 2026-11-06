require "spec_helper"
require "hecks/bench"
require "tmpdir"

# The gate of ADR 0188 step 5 reads a ratio of `rust:client` to `ruby:memory`; nothing here
# asserts a speed. What is held is the rule (pass and fail), the report that prints it, the
# `rust:client` target's path through the dispatcher, and that no default moved.
RSpec.describe Hecks::Bench do
  def entry(domain, target, p50, p99, by_verb: {})
    { domain: domain, target: target, median: { p50_us: p50, p99_us: p99, by_verb: by_verb } }
  end

  def verdict_for(client, memory)
    results = [entry("pizzas", "ruby:memory", *memory), entry("pizzas", "rust:client", *client)]
    Hecks::Bench::Gate.verdicts(results).first
  end

  # An executable that answers the kernel's hello, then every dispatch with one event.
  def fake_kernel(dir)
    path = File.join(dir, "fake-kernel")
    File.write(path, <<~RUBY)
      #!/usr/bin/env ruby
      $stdout.sync = true
      $stdin.each_line do |line|
        puts(line.include?("hello") ? '{"ok":true,"protocol":1}' :
          '{"ok":true,"events":[{"name":"Done","aggregate":"A","id":"1","payload":{}}]}')
      end
    RUBY
    File.chmod(0o755, path)
    path
  end

  def acquire_entries(client_figures)
    verb = "LeaseClock::Lease.Acquire"
    [entry("needs-fact", "ruby:memory", 10.0, 20.0, by_verb: { verb => { p50_us: 100.0, p99_us: 200.0 } }),
     entry("needs-fact", "rust:client", 500.0, 900.0, by_verb: { verb => client_figures })]
  end

  describe Hecks::Bench::Gate do
    it "passes a client no slower than in-process at p50 and within 1.5 times at p99", :aggregate_failures do
      verdict = verdict_for([180.0, 600.0], [186.0, 450.0])

      expect(verdict.pass).to be(true)
      expect(verdict.p50_ratio).to be < 1.0
      expect(verdict.p99_ratio).to eq(1.33)
    end

    it "fails a client whose p50 is above in-process" do
      expect(verdict_for([200.0, 300.0], [186.0, 450.0]).pass).to be(false)
    end

    it "fails a client whose p99 is above 1.5 times in-process" do
      expect(verdict_for([100.0, 700.0], [186.0, 450.0]).pass).to be(false)
    end

    it "reads an extra workload's named verb, not every step", :aggregate_failures do
      verdict = described_class.verdicts(acquire_entries({ p50_us: 90.0, p99_us: 250.0 })).first

      expect(verdict.p50_ratio).to eq(0.9)
      expect(verdict.pass).to be(true)
    end

    it "gives no verdict for a workload measured on one side only" do
      expect(described_class.verdicts([entry("pizzas", "rust:client", 1.0, 1.0)])).to be_empty
    end

    it "does not pass a gate with nothing measured" do
      expect(described_class.pass?([])).to be(false)
    end

    it "states the boot cost in floors against the room the budget leaves", :aggregate_failures do
      expect(described_class.boot_cost(70_000.0, 0.14)).to include(added_ratio: 0.5, room_ratio: 5.6, fits: true)
      expect(described_class.boot_cost(900_000.0, 0.14)[:fits]).to be(false)
    end

    it "keeps the port-policy workload out of the measuring, blocked by slice 6" do
      expect(Hecks::Bench::GateWorkloads::BLOCKED.fetch("port-policy")).to include("slice 6")
    end
  end

  describe Hecks::Bench::GateReport do
    def reading
      { verdicts:  [{ domain: "pizzas", p50_ratio: 0.9, p99_ratio: 1.2, pass: true }],
        boot_cost: { "pizzas" => Hecks::Bench::Gate.boot_cost(70_000.0, 0.14) },
        blocked:   Hecks::Bench::GateWorkloads::BLOCKED }
    end

    it "prints each ratio, the verdict, the blocked workload and the boot cost", :aggregate_failures do
      text = described_class.markdown(reading)

      expect(text).to include("| pizzas | 0.9 | 1.2 | pass |", "Gate PASS", "port-policy: blocked", "| pizzas | 70.0 |")
    end

    it "prints nothing when the client was not measured" do
      expect(described_class.markdown(nil)).to be_nil
    end
  end

  describe Hecks::Bench::Suite do
    it "knows rust:client, but does not run it by default", :aggregate_failures do
      expect(described_class::TARGETS).to include("rust:client")
      expect(described_class::DEFAULT_TARGETS).not_to include("rust:client")
      expect(Hecks::Bench::CLI::DEFAULTS[:targets]).to eq(described_class::DEFAULT_TARGETS)
    end

    it "knows the gate's extra workloads as domains, and leaves the core two alone", :aggregate_failures do
      expect(Hecks::Bench::Workload.fetch("needs-fact").feature).to eq("lease_clock")
      expect(Hecks::Bench::Workload.fetch("cascade").commands_per_cycle).to eq(11)
      expect(Hecks::Bench::Workload.all.keys).to eq(%w[pizzas banking])
    end
  end

  describe Hecks::Bench::KernelRunner do
    def run_through_dispatcher
      Dir.mktmpdir("bench_gate") do |dir|
        described_class.call(Hecks::Bench::Workload.pizzas, binary: fake_kernel(dir), warmup: 1, iterations: 2)
      end
    end

    it "times each command through the dispatcher and reports the boot", :aggregate_failures, :process do
      run = run_through_dispatcher

      expect(run.samples.size).to eq(8)
      expect(run.summary[:boot_us]).to be_positive
    end

    # The events each step of the first cascade cycle announces, from a real banking kernel.
    def cascade_event_counts
      workload = Hecks::Bench::Workload.fetch("cascade")
      dispatcher = described_class.connect(workload, Hecks::Bench::RustRunner.build("banking"))
      announced(dispatcher, workload.setup)
      announced(dispatcher, workload.cycle(0))
    ensure
      dispatcher&.close
    end

    def announced(dispatcher, steps)
      steps.map { |step| dispatcher.dispatch_flat(step.verb, step.args).events.size }
    end

    it "announces ten events from the cascade's one close, through a real kernel", :io do
      expect(cascade_event_counts.last).to eq(10)
    end

    it "answers the clock for a needed fact, as the attribute's type wants it", :aggregate_failures do
      expect(described_class.answer("now", "Integer", "V")).to be_a(Integer)
      expect(described_class.answer("now", "LeaseInstant", "V")).to include("value")
      expect(described_class.answer("other", "Integer", "V")).to be_nil
    end
  end
end
