require "spec_helper"
require "tmpdir"
require "fileutils"
require "hecks/rust_build"
require_relative "support/rust_conformance_helpers"

# The build tools the gem carries, reached in this process through `Hecks::RustBuild.run`.
RSpec.describe Hecks::RustBuild do
  let(:root) { File.expand_path("..", __dir__) }

  # Runs a tool with HECKS_RUST_DIR set to a scratch directory; answers the result and what the
  # tool left in that directory.
  def capture_with_rust_dir(tool, args)
    Dir.mktmpdir("rust_build") do |dir|
      [described_class.capture(tool, args, env: { "HECKS_RUST_DIR" => dir }), Dir.children(dir)]
    end
  end

  # Yields a scratch directory holding a conformance script of no steps, and that script's path.
  def with_empty_steps
    Dir.mktmpdir("rust_build") do |dir|
      script = File.join(dir, "steps.json")
      File.write(script, JSON.generate("steps" => []))
      yield dir, script
    end
  end

  def pizzas = File.join(root, "examples/pizzas")

  describe ".capture" do
    it "answers what a tool printed and how it ended", :aggregate_failures do
      result = described_class.capture("rust_coverage", ["--codegen=nonsense", "pizzas"])

      expect(result.status).to eq(1)
      expect(result.err).to include("--codegen must be `ruby` or `rust`")
      expect(result.ok?).to be(false)
    end

    it "turns a tool's usage complaint into a status and a message, never an exception" do
      result = described_class.capture("project_wasm", [])

      expect([result.status, result.err]).to eq([1, "usage: hecks build_wasm <domain>\n"])
    end

    it "refuses a domain name that cannot be a Rust module before it writes anything", :aggregate_failures do
      result, written = capture_with_rust_dir("project_rust", ["examples/Not-A-Module"])

      expect(result.status).to eq(1)
      expect(result.err).to include("can't be used as-is")
      expect(written).to be_empty
    end

    it "sets the environment it was given for the call and restores it after", :aggregate_failures do
      before = ENV.fetch("HECKS_RUST_DIR", nil)
      result, = capture_with_rust_dir("rust_coverage", ["--check-allowlist"])

      expect(result.ok?).to be(true)
      expect(result.out).to include("all 0 rules still excuse a real gap")
      expect(ENV.fetch("HECKS_RUST_DIR", nil)).to eq(before)
    end

    it "puts the process's own streams back" do
      out = $stdout
      err = $stderr

      described_class.capture("project_wasm", [])

      expect([$stdout, $stderr]).to eq([out, err])
    end

    it "refuses a missing generated module with the reason", :aggregate_failures do
      result, = capture_with_rust_dir("rust_coverage", ["nothing"])

      expect(result.status).to eq(1)
      expect(result.err).to include("no such generated module")
    end
  end

  describe "the conformance tool" do
    it "prints Ruby's result as JSON when no artifact is named" do
      with_empty_steps do |_dir, script|
        result = described_class.capture("rust_conformance", [pizzas, script])

        expect(JSON.parse(result.out)).to include("instances" => {}, "events" => [], "refusals" => [])
      end
    end

    it "matches Ruby's own output against itself" do
      with_empty_steps do |dir, script|
        same = File.join(dir, "same.json")
        File.write(same, described_class.capture("rust_conformance", [pizzas, script]).out)

        expect(described_class.capture("rust_conformance", [pizzas, script, same]).out).to include("matches.")
      end
    end

    it "says a differing file does not match" do
      with_empty_steps do |dir, script|
        other = File.join(dir, "other.json")
        File.write(other, JSON.generate("instances" => { "Pizza" => {} }, "events" => [], "refusals" => []))

        expect(described_class.capture("rust_conformance", [pizzas, script, other]).status).to eq(1)
      end
    end
  end

  describe "the packaged tools" do
    let(:files) do
      names = %w[rust_build.rb rust_build/**/*.rb persistence_legacy_fixture.rb persistence_legacy_fixture/**/*.rb]
      names.flat_map { |name| Dir.glob(File.join(root, "lib/hecks", name)) }
    end

    it "read nothing from spec/ and start no child Ruby, so an installed gem carries them whole", :aggregate_failures do
      code = files.to_h { |file| [file, File.readlines(file).reject { |line| line.strip.start_with?("#") }.join] }

      offenders = code.select { |_, text| text.match?(%r{spec/support|"bin"|RbConfig\.ruby}) }
      expect(files).not_to be_empty
      expect(offenders.keys.map { |file| file.delete_prefix("#{root}/") }).to be_empty
    end

    it "share the gem's own build failure with the spec helper" do
      expect(RustConformanceHelpers::BuildFailed).to eq(Hecks::RustBuild::NativeBuild::BuildFailed)
    end

    it "build the native binary through the gem's own helper, which the spec helper delegates to" do
      helper = Object.new.extend(RustConformanceHelpers)
      Dir.mktmpdir("rust_build") do |dir|
        File.write(File.join(dir, "Cargo.toml"), "[features]\ndefault = []\n")
        expect(helper.build_rust_for("undeclared", dir)).to be_nil
      end
    end
  end
end
