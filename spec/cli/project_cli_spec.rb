require "spec_helper"
require "hecks/hecks/adapters/local_files/project_cli"
require "tmpdir"
require "fileutils"

# `hecks project_cli` checks and writes the launchers; a domain it cannot read must fail the
# check, and nothing a domain or its world names may end a string literal in the launcher.
RSpec.describe Hecks::Adapters::LocalFiles::ProjectCli do
  let(:root) { Dir.mktmpdir("project_cli") }

  after { FileUtils.rm_rf(root) }

  def call(*paths, check: false)
    described_class.call(paths, program: "hecks project_cli", root: root, check: check, remove_stale_bin: false)
  end

  def write_domain(path, name: "Shelf")
    FileUtils.mkdir_p(File.join(root, path))
    File.write(File.join(root, path, "#{name.downcase}.bluebook"), "Hecks.bluebook #{name.inspect} do\n  vision \"x\"\nend\n")
    File.write(File.join(root, path, "#{name.downcase}.hecksagon"),
               "Hecks.hecksagon #{name.inspect} do\n  persisted_by \"Memory\"\nend\n")
  end

  describe "a check" do
    it "fails a path that is not a domain, instead of passing" do
      expect(call("nowhere", check: true).failed).to eq(["nowhere"])
    end

    it "fails a launcher that is missing, and passes once it is written", :aggregate_failures do
      write_domain("shelf")

      expect(call("shelf", check: true).drifted).to eq(["shelf"])
      call("shelf")
      expect(call("shelf", check: true)).to be_ok
    end

    it "refuses a domain path that leaves the root" do
      expect { call("../elsewhere", check: true) }.to raise_error(described_class::Error, /is outside/)
    end
  end

  describe ".launcher" do
    def source(path = "shelf", name = "Shelf", **options) = described_class.launcher(path, name, "hecks project_cli", **options)

    it "writes a launcher that never hands a name to Hecks::CLI", :aggregate_failures do
      expect(source("shelf", "Shelf", executable: "bin/x")).not_to include("Hecks::CLI")
      expect(source("shelf", "Shelf")).not_to include("Hecks::CLI")
    end

    it "writes the boot path, program and name as Ruby literals", :aggregate_failures do
      text = source("a/b", "Shelf")

      expect(text).to include("Hecks.boot(__dir__, install_driving: false)", %(program: "a/b/shelf"))
      expect(RubyVM::InstructionSequence.compile(text)).to be_a(RubyVM::InstructionSequence)
    end

    it "refuses a name, path or executable that could end its string", :aggregate_failures do
      expect { source('x"; system("id"); "', "Shelf") }.to raise_error(ArgumentError, /domain path/)
      expect { source("shelf", "Sh\"elf") }.to raise_error(ArgumentError, /bluebook name/)
      expect { source("shelf", "Shelf", executable: "../out") }.to raise_error(ArgumentError, /launcher executable/)
    end

    it "climbs one directory out of lib for an executable at the top of the root", :aggregate_failures do
      top    = source("dom", "Shelf", executable: "hecks")
      nested = source("dom", "Shelf", executable: "exe/hecks")

      expect(top).to include('File.expand_path("dom", __dir__)', 'File.expand_path("lib", __dir__)')
      expect(nested).to include('File.expand_path("../dom", __dir__)', 'File.expand_path("../lib", __dir__)')
    end

    it "sets UTF-8 and prints a failed --wait run's record on stdout, for a bluebook that opted in", :aggregate_failures do
      text = source(opted: true)

      expect(text).to include("Encoding.default_external = Encoding::UTF_8", "puts text", "warn reason", "exit status")
      expect(RubyVM::InstructionSequence.compile(text)).to be_a(RubyVM::InstructionSequence)
    end

    it "leaves the launcher of a bluebook that did not opt in as every earlier generator wrote it", :aggregate_failures do
      text = source

      expect(text).not_to include("Encoding.default_external", "reason")
      expect(text).to end_with("status.zero? ? puts(text) : abort(text)\n")
    end
  end
end
