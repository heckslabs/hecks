require "spec_helper"
require "tmpdir"
require "hecks/tools"
require "hecks/hecks/adapters/codebase/source_tree"

# The repository tools whose bodies live in `lib/hecks/tools/`: the library carries each one, and
# an adapter runs it in this process.
RSpec.describe Hecks::Tools do
  let(:root) { InMemoryDomain::ROOT }

  it "names a tool for every script it replaced, each answering `main` and defined in the library" do
    described_class::REGISTRY.each_key do |name|
      tool = described_class.fetch(name)

      expect(tool).to respond_to(:main), "#{name} has no main"
      expect(tool.name).to start_with("Hecks::Tools::")
    end
  end

  it "is not loaded by `require \"hecks\"`" do
    out = IO.popen(["ruby", "-I", File.join(root, "lib"), "-e",
                    'require "hecks"; puts $LOADED_FEATURES.grep(%r{/lib/hecks/tools}).size'], &:read)

    expect(out.strip).to eq("0")
  end

  describe ".run" do
    it "answers the exit status of a tool that refuses, without raising" do
      status = nil
      expect { status = described_class.run("standardize_comments", ["--only", "no_such_category", "lib"]) }
        .to output(/unknown categories: no_such_category/).to_stderr
      expect(status).to eq(1)
    end

    it "runs a tool from the root it is given, so relative paths are read there" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "a.rb"), "# Says what it is.\nclass A\nend\n")

        expect { expect(described_class.run("standardize_comments", ["--check", "a.rb"], root: dir)).to eq(0) }
          .not_to output.to_stdout
      end
    end
  end

  describe "a tool that crashes" do
    let(:crashing) { Module.new { def self.main(*, **) = raise(ArgumentError, "bad flag") } }

    before { allow(described_class).to receive(:fetch).with("crashing").and_return(crashing) }

    it "answers status 1 with the error on stderr, without raising" do
      status = nil

      expect { status = described_class.run("crashing", []) }.to output("crashing: ArgumentError: bad flag\n").to_stderr
      expect(status).to eq(1)
    end

    it "reads through `RubyChild` as a failure carrying the message" do
      stub_const("Hecks::Tools::REGISTRY", described_class::REGISTRY.merge("crashing" => ["x", "X"]))
      child = Hecks::Adapters::Codebase::RubyChild.new(Hecks::Adapters::Codebase::Tree.new(root: root))

      expect { child.read("crashing") }
        .to raise_error(Hecks::Adapters::ConsoleCapture::Failure, "crashing: ArgumentError: bad flag")
    end
  end

  describe "run through the Codebase adapters' `RubyChild`" do
    let(:child) { Hecks::Adapters::Codebase::RubyChild.new(Hecks::Adapters::Codebase::Tree.new(root: root)) }

    it "captures a tool's report and status in this process, with no child started" do
      expect(Process).not_to receive(:spawn)

      result = child.capture("standardize_comments", "--check", "lib/hecks/tools.rb")

      expect(result.ok?).to be(true)
      expect(result.out).to eq("")
    end

    it "answers a tool's refusal as the failure it printed" do
      expect { child.answer("standardize_comments", "--only", "nonsense", "lib") }
        .to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /unknown categories: nonsense/)
    end
  end

  describe "the scripts the codebase adapters name" do
    before { require "hecks/hecks/adapters/deploy_toolchain" }

    let(:shell) { instance_double(Hecks::Adapters::Shell) }
    let(:child) { Hecks::Adapters::Codebase::RubyChild.new(Hecks::Adapters::Codebase::Tree.new(root: root), shell: shell) }
    let(:named) do
      [Hecks::Adapters::Codebase::Style, Hecks::Adapters::Codebase::Codemods, Hecks::Adapters::DeployToolchain]
        .flat_map { |adapter| adapter::SCRIPTS.values }
        .grep(String)
        .select { |name| described_class.tool?(name) }
    end

    it "runs every one that lives in Hecks::Tools in this process, so it survives `bin/` going away" do
      expect(named).not_to be_empty
      allow(described_class).to receive(:run).and_return(0)
      expect(shell).not_to receive(:capture)

      named.each { |name| expect(child.capture(name).ok?).to be(true) }
    end
  end

  describe "the `project_*` generators over `ProjectionFiles`" do
    it "prints what a projection wrote, and aborts with the reason when it is refused" do
      allow(Hecks::ProjectionFiles).to receive(:write).with(:vocabulary, root: Hecks::ProjectionFiles::ROOT)
                                                      .and_return(["wrote a"])
      expect { Hecks::ProjectionFiles.run(:vocabulary) }.to output("wrote a\n").to_stdout

      allow(Hecks::ProjectionFiles).to receive(:write).and_raise(Hecks::ProjectionFiles::Refused, "cannot boot")
      expect { Hecks::ProjectionFiles.run(:vocabulary) }
        .to raise_error(SystemExit).and output("cannot boot\n").to_stderr
    end
  end
end
