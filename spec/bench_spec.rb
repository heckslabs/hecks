require "spec_helper"
require "hecks/bench"
require "json"
require "stringio"
require "tmpdir"
require_relative "support/postgres_probe"
require_relative "support/rust_conformance_helpers"

# `bin/bench` is a measurement tool, not a gate, so nothing here asserts a speed. What is
# held is that the harness still runs end to end in a tiny configuration, refuses what it
# should, reports what it measured, and skips an unavailable target instead of failing.
RSpec.describe Hecks::Bench do
  def tiny(**overrides)
    Hecks::Bench::Suite::Config.new(domains: %w[pizzas], targets: %w[ruby:memory], warmup: 1,
                                    iterations: 3, runs: 1, rust_binary: nil, **overrides)
  end

  def quiet = StringIO.new

  # Writes an executable that answers `rust --serve` the way the real binary frames it:
  # one line in, one line out.
  def fake_serve_binary(dir, answer)
    path = File.join(dir, "fake-rust")
    File.write(path, <<~RUBY)
      #!/usr/bin/env ruby
      $stdout.sync = true
      $stdin.each_line { |_line| puts '#{answer}' }
    RUBY
    File.chmod(0o755, path)
    path
  end

  describe Hecks::Bench::Stats do
    it "takes nearest-rank percentiles, so every figure is a latency that happened" do
      samples = (1..100).map(&:to_f).shuffle

      expect(described_class.percentile(samples, 0.5)).to eq(50.0)
      expect(described_class.percentile(samples, 0.99)).to eq(99.0)
      expect(described_class.percentile([0.4, 0.2], 0.99)).to eq(0.4)
      expect(described_class.percentile([], 0.5)).to be_nil
    end

    it "averages the two middle values of an even list for the median" do
      expect(described_class.median([3, 1, 2])).to eq(2.0)
      expect(described_class.median([4, 1, 3, 2])).to eq(2.5)
    end

    it "reports latency in microseconds" do
      summary = described_class.latency([0.001, 0.002, 0.003])

      expect(summary).to include(count: 3, p50_us: 2000.0, max_us: 3000.0, mean_us: 2000.0)
    end

    it "measures drift as the last tenth's p50 over the first tenth's" do
      seconds = Array.new(10, 1.0) + Array.new(80, 1.5) + Array.new(10, 3.0)

      expect(described_class.drift(seconds)).to eq(3.0)
      expect(described_class.drift([1.0] * 5)).to be_nil
    end
  end

  describe Hecks::Bench::Workload do
    it "gives every cycle its own record names, so no command is ever refused for a duplicate" do
      described_class.all.each_value do |workload|
        firsts = (0...5).map { |n| workload.cycle(n).first.args }

        expect(firsts.map { |args| args.fetch("name") { args.fetch("number") } }.uniq.size).to eq(5)
      end
    end

    it "renders a step as one JSON line and symbolizes only the top-level argument keys" do
      step = described_class.pizzas.cycle(0).first

      expect(JSON.parse(step.to_json_line)).to eq("verb" => step.verb, "args" => step.args)
      expect(step.ruby_args.keys).to all(be_a(Symbol))
      expect(step.ruby_args[:pizza]).to include("price_cents")
    end

    it "refuses a domain it has no workload for" do
      expect { described_class.fetch("chess") }.to raise_error(ArgumentError, /unknown domain "chess"/)
    end
  end

  describe Hecks::Bench::Suite do
    it "refuses a configuration that cannot be measured before booting anything" do
      expect { described_class.call(tiny(targets: %w[ruby:heki]), log: quiet) }
        .to raise_error(ArgumentError, /unknown target "ruby:heki"/)
      expect { described_class.call(tiny(iterations: 0), log: quiet) }.to raise_error(ArgumentError, /at least 1/)
      expect { described_class.call(tiny(domains: %w[pizzas banking], rust_binary: "/x"), log: quiet) }
        .to raise_error(ArgumentError, /exactly one --domain/)
    end

    it "measures the Ruby runtime on Memory and Sqlite for both domains" do
      config = tiny(domains: %w[pizzas banking], targets: %w[ruby:memory ruby:sqlite])
      result = described_class.call(config, log: quiet)

      expect(result[:results].map { |entry| [entry[:domain], entry[:target]] }).to contain_exactly(
        %w[pizzas ruby:memory], %w[pizzas ruby:sqlite], %w[banking ruby:memory], %w[banking ruby:sqlite]
      )
      result[:results].each do |entry|
        run = entry[:runs].first
        expect(run[:commands]).to eq(3 * Hecks::Bench::Workload.fetch(entry[:domain]).commands_per_cycle)
        expect(entry[:median][:throughput_per_s]).to be_positive
        expect(entry[:median][:p99_us]).to be >= entry[:median][:p50_us]
        expect(entry[:median][:by_verb].keys).to eq(Hecks::Bench::Workload.fetch(entry[:domain]).cycle(0).map(&:verb).uniq)
      end
    end

    it "skips a Postgres target with the reason instead of failing when no server answers" do
      reason = "no Postgres server is reachable (connection refused); start one"
      allow(Hecks::Bench::PostgresProbe).to receive(:unavailable_reason).and_return(reason)
      log = quiet

      result = described_class.call(tiny(targets: %w[ruby:memory ruby:postgres ruby:postgres_era]), log: log)

      expect(result[:results].map { |entry| entry[:target] }).to eq(%w[ruby:memory])
      expect(result[:skipped]).to eq([{ target: "ruby:postgres", reason: reason },
                                      { target: "ruby:postgres_era", reason: reason }])
      expect(log.string).to include("skip ruby:postgres: #{reason}")
      expect(Hecks::Bench::Report.markdown(result)).to include("Skipped:", "- ruby:postgres_era: #{reason}")
    end

    it "measures Postgres when a server answers", :io do
      skip "no local Postgres" unless PostgresProbe.available?

      result = described_class.call(tiny(targets: %w[ruby:postgres ruby:postgres_era]), log: quiet)

      expect(result[:skipped]).to be_empty
      expect(result[:results].map { |entry| entry[:median][:throughput_per_s] }).to all(be_positive)
    end
  end

  describe Hecks::Bench::RustRunner do
    it "times a round trip per step against a binary that speaks the serve protocol" do
      Dir.mktmpdir("bench_spec") do |dir|
        binary = fake_serve_binary(dir, '{"ok":true,"events":[]}')
        workload = Hecks::Bench::Workload.pizzas

        run = described_class.call(workload, binary: binary, warmup: 1, iterations: 2)

        expect(run.samples.map(&:first)).to eq(workload.cycle(0).map(&:verb) * 2)
        expect(run.summary).to include(:roundtrip_floor_p50_us)
      end
    end

    it "refuses to time a workload the binary does not accept" do
      Dir.mktmpdir("bench_spec") do |dir|
        binary = fake_serve_binary(dir, '{"ok":false,"error":"no such verb"}')

        expect { described_class.call(Hecks::Bench::Workload.pizzas, binary: binary, warmup: 0, iterations: 1) }
          .to raise_error(described_class::StepRefused, /no such verb/)
      end
    end

    it "says why it cannot run when there is neither a toolchain nor a binary" do
      expect(described_class.unavailable_reason(binary: "/nonexistent/rust")).to include("does not exist")
      allow(Hecks::Bench::Environment).to receive(:capture).with("cargo", "-V").and_return("unknown")

      expect(described_class.unavailable_reason).to match(/cargo. is not on PATH/)
    end

    it "measures a real generated binary end to end", :io do
      rust_dir = File.join(InMemoryDomain::ROOT, "rust")
      binary = Object.new.extend(RustConformanceHelpers).build_rust_for("pizzas", rust_dir)

      result = Hecks::Bench::Suite.call(tiny(targets: %w[rust], rust_binary: binary), log: quiet)

      expect(result[:results].first[:median][:throughput_per_s]).to be_positive
    end
  end

  describe Hecks::Bench::CLI do
    it "prints a Markdown report and writes the full JSON result" do
      Dir.mktmpdir("bench_spec") do |dir|
        out = quiet
        path = File.join(dir, "bench.json")

        status = described_class.run(%w[--domain pizzas --targets ruby:memory --iterations 2 --warmup 1 --runs 1
                                        --output] + [path], out: out, err: quiet)

        expect(status).to eq(0)
        expect(out.string).to include("| pizzas | ruby:memory |", "CPU:", "Ruby: ruby")
        expect(JSON.parse(File.read(path))).to include("environment", "config", "results", "skipped")
      end
    end

    it "answers a usage error with status 2 and a sentence, not a stack trace" do
      err = quiet

      expect(described_class.run(%w[--targets ruby:heki], out: quiet, err: err)).to eq(2)
      expect(err.string).to include("bin/bench: unknown target")
      expect(described_class.run(%w[--nonsense], out: quiet, err: err)).to eq(2)
    end
  end
end
