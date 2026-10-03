require "spec_helper"
require "hecks/cli/project_cli"
require "tmpdir"
require "fileutils"

# `hecks project_cli` checks and writes the launchers; a domain it cannot read must fail the
# check, and nothing a domain or its world names may end a string literal in the launcher.
RSpec.describe Hecks::CLI::ProjectCli do
  let(:root) { Dir.mktmpdir("project_cli") }

  after { FileUtils.rm_rf(root) }

  def call(*argv) = described_class.call(argv, program: "hecks project_cli", root: root, remove_stale_bin: false)

  def write_domain(path, name: "Shelf")
    FileUtils.mkdir_p(File.join(root, path))
    File.write(File.join(root, path, "#{name.downcase}.bluebook"), "Hecks.bluebook #{name.inspect} do\n  vision \"x\"\nend\n")
    File.write(File.join(root, path, "#{name.downcase}.hecksagon"),
               "Hecks.hecksagon #{name.inspect} do\n  persisted_by \"Memory\"\nend\n")
  end

  def quietly
    $stdout = StringIO.new
    $stderr = StringIO.new
    yield
    [$stdout.string, $stderr.string]
  ensure
    $stdout = STDOUT
    $stderr = STDERR
  end

  describe "--check" do
    it "exits 1 for a path that is not a domain, instead of passing" do
      expect { quietly { call("--check", "nowhere") } }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
    end

    it "exits 1 for a launcher that is missing, and 0 once it is written" do
      write_domain("shelf")

      expect { quietly { call("--check", "shelf") } }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      quietly { call("shelf") }
      expect { quietly { call("--check", "shelf") } }.not_to raise_error
    end

    it "does not take a mistyped flag for a domain path" do
      _, err = quietly { expect { call("--chek", "shelf") }.to raise_error(SystemExit) }

      expect(err).to include("unknown option --chek")
    end

    it "refuses a domain path that leaves the root" do
      _, err = quietly { expect { call("--check", "../elsewhere") }.to raise_error(SystemExit) }

      expect(err).to include("is outside")
    end
  end

  describe ".launcher" do
    def source(path = "shelf", name = "Shelf", **options) = described_class.launcher(path, name, "hecks project_cli", **options)

    it "writes the boot path, program and name as Ruby literals" do
      text = source("a/b", "Shelf")

      expect(text).to include("Hecks.boot(__dir__, install_doors: false)", %(program: "a/b/shelf"))
      expect(RubyVM::InstructionSequence.compile(text)).to be_a(RubyVM::InstructionSequence)
    end

    it "refuses a name, path, executable or legacy command that could end its string" do
      expect { source('x"; system("id"); "', "Shelf") }.to raise_error(ArgumentError, /domain path/)
      expect { source("shelf", "Sh\"elf") }.to raise_error(ArgumentError, /chapter name/)
      expect { source("shelf", "Shelf", executable: "../out") }.to raise_error(ArgumentError, /launcher executable/)
      expect { source("shelf", "Shelf", executable: "bin/x", legacy: ["run]; exit"]) }
        .to raise_error(ArgumentError, /legacy command/)
    end

    it "climbs one directory out of lib for an executable at the top of the root" do
      top    = source("dom", "Shelf", executable: "hecks")
      nested = source("dom", "Shelf", executable: "exe/hecks")

      expect(top).to include('File.expand_path("dom", __dir__)', 'File.expand_path("lib", __dir__)')
      expect(nested).to include('File.expand_path("../dom", __dir__)', 'File.expand_path("../lib", __dir__)')
    end

    it "sets UTF-8 and prints a failed --wait run's record on stdout, for a chapter that opted in" do
      text = source(opted: true)

      expect(text).to include("Encoding.default_external = Encoding::UTF_8", "puts text", "warn reason", "exit status")
      expect(RubyVM::InstructionSequence.compile(text)).to be_a(RubyVM::InstructionSequence)
    end

    it "leaves the launcher of a chapter that did not opt in as every earlier generator wrote it" do
      text = source

      expect(text).not_to include("Encoding.default_external", "reason")
      expect(text).to end_with("status.zero? ? puts(text) : abort(text)\n")
    end
  end
end
