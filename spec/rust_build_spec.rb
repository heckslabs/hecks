require "spec_helper"
require "tmpdir"
require "fileutils"
require "hecks/rust_build"

# The build tools the gem carries, reached in this process through `Hecks::RustBuild.run`.
RSpec.describe Hecks::RustBuild do
  let(:root) { File.expand_path("..", __dir__) }

  describe ".capture" do
    it "answers what a tool printed and how it ended" do
      result = described_class.capture("rust_coverage", ["--codegen=nonsense", "pizzas"])

      expect(result.status).to eq(1)
      expect(result.err).to include("--codegen must be `ruby` or `rust`")
      expect(result.ok?).to be(false)
    end

    it "turns a tool's usage complaint into a status and a message, never an exception" do
      result = described_class.capture("project_wasm", [])

      expect([result.status, result.err]).to eq([1, "usage: bin/project_wasm <domain>\n"])
    end

    it "refuses a domain name that cannot be a Rust module before it writes anything" do
      Dir.mktmpdir("rust_build") do |dir|
        result = described_class.capture("project_rust", ["examples/Not-A-Module"], env: { "HECKS_RUST_DIR" => dir })

        expect(result.status).to eq(1)
        expect(result.err).to include("can't be used as-is")
        expect(Dir.children(dir)).to be_empty
      end
    end

    it "sets the environment it was given for the call and restores it after" do
      before = ENV.fetch("HECKS_RUST_DIR", nil)

      Dir.mktmpdir("rust_build") do |dir|
        result = described_class.capture("rust_coverage", ["--check-allowlist"], env: { "HECKS_RUST_DIR" => dir })
        expect(result.ok?).to be(true)
        expect(result.out).to include("all 0 rules still excuse a real gap")
      end

      expect(ENV.fetch("HECKS_RUST_DIR", nil)).to eq(before)
    end

    it "puts the process's own streams back" do
      out = $stdout
      err = $stderr

      described_class.capture("project_wasm", [])

      expect([$stdout, $stderr]).to eq([out, err])
    end

    it "refuses a missing generated module with the reason" do
      Dir.mktmpdir("rust_build") do |dir|
        result = described_class.capture("rust_coverage", ["nothing"], env: { "HECKS_RUST_DIR" => dir })

        expect(result.status).to eq(1)
        expect(result.err).to include("no such generated module")
      end
    end
  end

  describe "the conformance tool" do
    it "prints Ruby's result as JSON when no artifact is named" do
      Dir.mktmpdir("rust_build") do |dir|
        script = File.join(dir, "steps.json")
        File.write(script, JSON.generate("steps" => []))

        result = described_class.capture("rust_conformance", [File.join(root, "examples/pizzas"), script])

        expect(JSON.parse(result.out)).to include("instances" => {}, "events" => [], "refusals" => [])
      end
    end

    it "matches Ruby's own output against itself, and says a differing file does not" do
      Dir.mktmpdir("rust_build") do |dir|
        script = File.join(dir, "steps.json")
        File.write(script, JSON.generate("steps" => []))
        pizzas = File.join(root, "examples/pizzas")
        same = File.join(dir, "same.json")
        File.write(same, described_class.capture("rust_conformance", [pizzas, script]).out)
        other = File.join(dir, "other.json")
        File.write(other, JSON.generate("instances" => { "Pizza" => {} }, "events" => [], "refusals" => []))

        expect(described_class.capture("rust_conformance", [pizzas, script, same]).out).to include("matches.")
        expect(described_class.capture("rust_conformance", [pizzas, script, other]).status).to eq(1)
      end
    end
  end

  describe "the packaged tools" do
    let(:files) do
      names = %w[rust_build.rb rust_build/**/*.rb persistence_legacy_fixture.rb persistence_legacy_fixture/**/*.rb]
      names.flat_map { |name| Dir.glob(File.join(root, "lib/hecks", name)) }
    end

    it "read nothing from spec/ and start no bin/ script, so an installed gem carries them whole" do
      code = files.to_h { |file| [file, File.readlines(file).reject { |line| line.strip.start_with?("#") }.join] }

      offenders = code.select { |_, text| text.match?(%r{spec/support|"bin"|RbConfig\.ruby}) }
      expect(files).not_to be_empty
      expect(offenders.keys.map { |file| file.delete_prefix("#{root}/") }).to be_empty
    end

    it "build the native binary through the gem's own helper, which the spec helper delegates to" do
      require_relative "support/rust_conformance_helpers"

      expect(RustConformanceHelpers::BuildFailed).to eq(Hecks::RustBuild::NativeBuild::BuildFailed)
      helper = Object.new.extend(RustConformanceHelpers)
      Dir.mktmpdir("rust_build") do |dir|
        File.write(File.join(dir, "Cargo.toml"), "[features]\ndefault = []\n")
        expect(helper.build_rust_for("undeclared", dir)).to be_nil
      end
    end
  end
end
