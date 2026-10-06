require "spec_helper"
require "tmpdir"
require "fileutils"
require_relative "../../../lib/hecks/hecks/adapters/rust_toolchain"

# The RustToolchain port's adapter asks the Hecks::RustBuild tools that generate, compile and
# check a build, in the workspace RustWorkspace names. A fake runner stands in for every tool, so
# what is asked of the toolchain is tested without one.
RSpec.describe Hecks::Adapters::RustToolchain do
  # Records each tool it is asked to run, and answers a queued result.
  class FakeRunner
    Result = Struct.new(:out, :err, :status) do
      def ok? = status.zero?
    end

    attr_reader :calls

    def initialize
      @calls = []
      @answers = []
    end

    def answer(out: "", err: "", passed: true)
      @answers << Result.new(out, err, passed ? 0 : 1)
    end

    def capture(tool, argv, env: {})
      @calls << { tool: tool, argv: argv, env: env }
      @answers.shift || Result.new("", "", 0)
    end
  end

  let(:dir) { Dir.mktmpdir("rust_toolchain") }
  let(:runner) { FakeRunner.new }
  let(:workspace) { Hecks::Adapters::RustWorkspace.new(gem_root: File.join(dir, "gem"), project_root: File.join(dir, "app"), version: "9.9.9") }
  let(:toolchain) { described_class.new }

  before do
    described_class.runner = runner
    described_class.workspace = workspace
    FileUtils.mkdir_p(File.join(dir, "gem/lib"))
    FileUtils.mkdir_p(File.join(dir, "gem/rust/src/generated/pizzas"))
    FileUtils.mkdir_p(File.join(dir, "gem/rust/src/parser"))
    FileUtils.mkdir_p(File.join(dir, "gem/rust/target/debug"))
    FileUtils.mkdir_p(File.join(dir, "gem/rust/tests"))
    FileUtils.mkdir_p(File.join(dir, "gem/rust/host/target"))
    File.write(File.join(dir, "gem/rust/Cargo.toml"), "[package]\n")
    File.write(File.join(dir, "gem/rust/src/lib.rs"), "// kernel\n")
    File.write(File.join(dir, "gem/rust/src/generated/pizzas/mod.rs"), "// a corpus domain\n")
    File.write(File.join(dir, "gem/rust/target/debug/rust"), "binary")
    File.write(File.join(dir, "gem/rust/tests/corpus.rs"), "// tests\n")
    File.write(File.join(dir, "gem/rust/host/Cargo.toml"), "[package]\n")
    File.write(File.join(dir, "gem/rust/host/target/big"), "build output")
  end

  after do
    described_class.runner = nil
    described_class.workspace = nil
    FileUtils.rm_rf(dir)
  end

  RUST_TOOLCHAIN_FEATURE_MANIFEST = <<~TOML.freeze
    [features]
    default = ["pizzas"]
    pizzas = []

    [package]
    name = "rust"
  TOML

  describe "in an installed gem" do
    def copy = File.join(dir, "app/.hecks/rust/9.9.9")

    it "copies the packaged workspace into the project, keyed by the gem version", :aggregate_failures do
      toolchain.generate(domain: { value: "domains/pizzas" })

      expect(File.read(File.join(copy, "src/lib.rs"))).to eq("// kernel\n")
      expect(File.exist?(File.join(copy, "host/Cargo.toml"))).to be(true)
    end

    it "leaves generated sources, build output and tests out of the copy" do
      toolchain.generate(domain: { value: "domains/pizzas" })

      expect(%w[src/generated target host/target tests].map { |path| File.exist?(File.join(copy, path)) }).to all(be(false))
    end

    it "writes the copy's Cargo feature list clean, keeping the rest of the manifest" do
      File.write(File.join(dir, "gem/rust/Cargo.toml"), RUST_TOOLCHAIN_FEATURE_MANIFEST)

      toolchain.generate(domain: { value: "domains/pizzas" })

      expect(File.read(File.join(copy, "Cargo.toml"))).to eq("[features]\ndefault = []\n\n[package]\nname = \"rust\"\n")
    end

    it "points the child at the copy and its own target directory, never at the gem", :aggregate_failures do
      toolchain.generate(domain: { value: "domains/pizzas" })

      env = runner.calls.first.fetch(:env)
      expect(env).to include("HECKS_RUST_DIR" => copy, "CARGO_TARGET_DIR" => File.join(copy, "target"))
      expect(env.values.join).not_to include(File.join(dir, "gem"))
    end

    it "keeps a copy that is already there, so a generated domain and its build survive" do
      toolchain.generate(domain: { value: "domains/pizzas" })
      FileUtils.mkdir_p(File.join(copy, "src/generated"))
      File.write(File.join(copy, "src/generated/mine.rs"), "// mine\n")

      toolchain.wasm(domain: { value: "domains/pizzas" })

      expect(File.exist?(File.join(copy, "src/generated/mine.rs"))).to be(true)
    end

    def leave_an_interrupted_copy
      FileUtils.mkdir_p(copy)
      File.write(File.join(copy, "half"), "")
    end

    it "redoes a copy that was interrupted before it was complete", :aggregate_failures do
      leave_an_interrupted_copy

      toolchain.generate(domain: { value: "domains/pizzas" })

      expect(File.exist?(File.join(copy, "half"))).to be(false)
      expect(File.exist?(File.join(copy, "Cargo.toml"))).to be(true)
    end

    def newer_workspace
      Hecks::Adapters::RustWorkspace.new(gem_root: File.join(dir, "gem"), project_root: File.join(dir, "app"),
                                         version: "10.0.0")
    end

    it "keeps a copy per gem version" do
      toolchain.generate(domain: { value: "domains/pizzas" })
      described_class.workspace = newer_workspace
      toolchain.generate(domain: { value: "domains/pizzas" })

      expect(Dir.children(File.join(dir, "app/.hecks/rust")).sort).to eq(%w[10.0.0 9.9.9])
    end

    it "refuses, with a reason, when the install carries no Rust workspace", :aggregate_failures do
      FileUtils.rm_rf(File.join(dir, "gem/rust"))

      expect { toolchain.generate(domain: { value: "domains/pizzas" }) }
        .to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /no Rust workspace/)
      expect(runner.calls).to be_empty
    end
  end

  describe "in a hecks checkout" do
    before { File.write(File.join(dir, "gem/hecks.gemspec"), "") }

    it "builds in the checkout's own rust/ and copies nothing", :aggregate_failures do
      toolchain.generate(domain: { value: "domains/pizzas" })

      expect(runner.calls.first.fetch(:env)).to eq({})
      expect(File.exist?(File.join(dir, "app"))).to be(false)
      expect(workspace.directory).to eq(File.join(dir, "gem/rust"))
    end
  end

  describe "what each ask runs" do
    before { File.write(File.join(dir, "gem/hecks.gemspec"), "") }

    def script_of(call) = call.fetch(:tool)

    def arguments_of(call) = call.fetch(:argv)

    it "generates a domain through project_rust" do
      toolchain.generate(domain: { value: "domains/pizzas" })

      expect([script_of(runner.calls.first), arguments_of(runner.calls.first)]).to eq(["project_rust", ["domains/pizzas"]])
    end

    it "builds a WASI module and a browser module through their scripts" do
      toolchain.wasm(domain: { value: "domains/pizzas" })
      toolchain.browser_wasm(domain: { value: "domains/pizzas" })

      expect(runner.calls.map { |call| script_of(call) }).to eq(%w[project_wasm project_wasm_browser])
    end

    it "builds the host with no target or stage unless it is given them" do
      toolchain.host(domain: { value: "domains/pizzas" })

      expect([script_of(runner.calls.first), arguments_of(runner.calls.first)]).to eq(["project_host", %w[domains/pizzas]])
    end

    it "builds the host with the target and stage it is given, and only those" do
      toolchain.host(domain: { value: "domains/pizzas" }, target: { value: "aarch64-unknown-linux-gnu" },
                     stage_dir: { value: "out/host" })

      expect(arguments_of(runner.calls.first)).to eq(%w[domains/pizzas --target=aarch64-unknown-linux-gnu --stage=out/host])
    end

    it "replays a script against an artifact, or against Ruby alone when none is named", :aggregate_failures do
      toolchain.conform(domain: { value: "d/pizzas" }, script: { value: "steps.json" }, artifact: { value: "native" })
      toolchain.conform(domain: { value: "d/pizzas" }, script: { value: "steps.json" })

      expect(arguments_of(runner.calls[0])).to eq(%w[d/pizzas steps.json native])
      expect(arguments_of(runner.calls[1])).to eq(%w[d/pizzas steps.json])
    end

    it "replays generated sequences ten seeds of twenty-five steps unless told otherwise", :aggregate_failures do
      toolchain.replay(domain: { value: "d/pizzas" }, artifact: { value: "native" })
      toolchain.replay(domain: { value: "d/pizzas" }, artifact: { value: "native" }, seeds: { value: 3 }, steps: { value: 7 })

      expect(script_of(runner.calls[0])).to eq("rust_conformance_fuzz")
      expect(arguments_of(runner.calls[0])).to eq(%w[d/pizzas native 10 25])
      expect(arguments_of(runner.calls[1])).to eq(%w[d/pizzas native 3 7])
    end

    it "checks the coverage allowlist through rust_coverage" do
      toolchain.audit

      expect([script_of(runner.calls.first), arguments_of(runner.calls.first)]).to eq(["rust_coverage", ["--check-allowlist"]])
    end

    it "answers a tool's output as the answer" do
      runner.answer(out: "wrote rust/dist/pizzas.wasm\n")

      expect(toolchain.wasm(domain: { value: "d/pizzas" })).to eq(output: { value: "wrote rust/dist/pizzas.wasm\n" })
    end

    it "refuses with what a failed tool printed, its own stderr first" do
      runner.answer(out: "partial\n", err: "the domain name is not a module name\n", passed: false)

      expect { toolchain.generate(domain: { value: "d/pizzas" }) }
        .to raise_error(Hecks::Adapters::ConsoleCapture::Failure, "the domain name is not a module name\npartial")
    end
  end

  describe "#measure" do
    # A pool that notes each command and environment it is asked to run, and answers a report.
    def recording_pool(log)
      Object.new.tap do |recorder|
        recorder.define_singleton_method(:run) do |command, env: {}, **|
          log << { command: command, env: env }
          Struct.new(:output, :ok?).new("| ruby:memory | 1000 |\n", true)
        end
      end
    end

    before do
      File.write(File.join(dir, "gem/hecks.gemspec"), "")
      @started = []
      described_class.pool = recording_pool(@started)
    end

    after { described_class.pool = nil }

    context "with every flag held" do
      let(:answer) do
        toolchain.measure(domains: { value: "pizzas,banking" }, targets: { value: "ruby:memory" },
                          iterations: { value: 50 }, warmup: { value: 0 }, runs: { value: 1 },
                          format: { value: "json" }, output: { value: "tmp/bench.json" })
      end

      before { answer }

      def command = @started.first.fetch(:command)

      it "starts the benchmark through the pool" do
        expect(command[command.index("-e") + 1]).to include("Hecks::Bench::CLI.run(ARGV)")
      end

      it "passes the flags the record holds" do
        flags = %w[--domain pizzas,banking --targets ruby:memory --iterations 50 --warmup 0
                   --runs 1 --format json --output tmp/bench.json]

        expect(command.drop(command.index("--") + 1)).to eq(flags)
      end

      it "answers its report" do
        expect(answer).to eq(report: { value: "| ruby:memory | 1000 |\n" })
      end
    end

    it "builds in the copy of the packaged workspace when it is not in a checkout" do
      FileUtils.rm_f(File.join(dir, "gem/hecks.gemspec"))

      toolchain.measure

      expect(@started.first.fetch(:env)).to include("HECKS_RUST_DIR" => File.join(dir, "app/.hecks/rust/9.9.9"))
    end

    it "refuses with what the benchmark printed when it could not run" do
      described_class.pool = Object.new.tap do |failing|
        failing.define_singleton_method(:run) { |*, **| Struct.new(:output, :ok?).new("hecks bench: no such target\n", false) }
      end

      expect { toolchain.measure }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure, "hecks bench: no such target")
    end
  end

  # The real generator, in a copy of a packaged workspace. It builds `hecks-codegen` with Cargo,
  # into the copy's own target directory, so nothing is written into the gem.
  describe "generating for real", :io do
    def write_real_gem_tree
      gem_rust = File.join(dir, "real_gem/rust")
      FileUtils.mkdir_p(File.join(gem_rust, "src"))
      FileUtils.cp(File.join(InMemoryDomain::ROOT, "rust/Cargo.toml"), gem_rust)
      File.write(File.join(gem_rust, "src/lib.rs"), "")
      FileUtils.mkdir_p(File.join(dir, "real_gem/lib"))
    end

    def prepare_real_gem
      write_real_gem_tree
      described_class.runner = nil
      described_class.workspace = Hecks::Adapters::RustWorkspace.new(
        gem_root: File.join(dir, "real_gem"), project_root: File.join(dir, "app"), version: "9.9.9"
      )
    end

    before do
      prepare_real_gem
      @checkout_manifest = File.read(File.join(InMemoryDomain::ROOT, "rust/Cargo.toml"))
      described_class.new.generate(domain: { value: File.join(InMemoryDomain::ROOT, "examples/pizzas") })
    end

    it "writes the domain into the copy", :aggregate_failures do
      copy = File.join(dir, "app/.hecks/rust/9.9.9")

      expect(File.exist?(File.join(copy, "src/generated/pizzas/mod.rs"))).to be(true)
      expect(File.read(File.join(copy, "Cargo.toml"))).to include("pizzas")
    end

    it "leaves the gem's own workspace untouched", :aggregate_failures do
      expect(File.exist?(File.join(dir, "real_gem/rust/src/generated"))).to be(false)
      expect(File.read(File.join(InMemoryDomain::ROOT, "rust/Cargo.toml"))).to eq(@checkout_manifest)
    end
  end

  describe "#rust_coverage" do
    before { File.write(File.join(dir, "gem/hecks.gemspec"), "") }

    it "answers the report as text, and passes the generator it was asked to read", :aggregate_failures do
      runner.answer(out: "#{"=" * 72}\nPizzas - 3 constructs\n")

      answer = toolchain.rust_coverage(module_name: { value: "pizzas" }, codegen: { value: "rust" })

      expect(answer.fetch(:text)).to start_with("=" * 72)
      expect(runner.calls.first.fetch(:argv).last(2)).to eq(%w[pizzas --codegen=rust])
    end

    it "answers a report that found gaps, since the gaps are what it reports" do
      runner.answer(out: "#{"=" * 72}\nGAP (2)\n", passed: false)

      expect(toolchain.rust_coverage(module_name: { value: "pizzas" }).fetch(:text)).to include("GAP (2)")
    end

    it "refuses when the script stopped before it could report at all" do
      runner.answer(err: "rust/src/generated/none: no such generated module\n", passed: false)

      expect { toolchain.rust_coverage(module_name: { value: "none" }) }
        .to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /no such generated module/)
    end
  end
end
