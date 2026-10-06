require "spec_helper"
require "hecks/cli"
require "open3"
require "rbconfig"
require "tmpdir"
require "fileutils"

# The ten names the gem shipped go to Hecks::CLI before the launcher sees them, so the launcher's
# generic flags and its name=value forms are honoured there too.
RSpec.describe "the legacy names under the launcher's words" do
  let(:root) { File.expand_path("..", __dir__) }
  let(:dir) { Dir.mktmpdir("legacy_wait") }

  after { FileUtils.rm_rf(dir) }

  def hecks(*argv)
    Open3.capture3(RbConfig.ruby, "exe/hecks", *argv, chdir: root)
  end

  # A domain whose lifecycle has a transition no command reaches.
  FLAGGED_SHELF_BLUEBOOK = <<~RUBY.freeze
    Hecks.bluebook "Shelf" do
      vision "Books on a shelf."
      aggregate "Book" do
        description "A book."
        attribute :title, Title
        identified_by :title
        value_object "Title" do
          attribute :value, String
        end
        lifecycle :status, default: "shelved" do
          transition "Lend" => "lent", from: "shelved"
        end
        command "Shelve" do
          attribute :title, Title
          sets :title
          emits Shelved
        end
      end
    end
  RUBY

  FLAGGED_SHELF_HECKSAGON = "Hecks.hecksagon \"Shelf\" do\n  persisted_by \"Memory\"\nend\n".freeze

  def write_flagged_shelf(dir)
    FileUtils.mkdir_p(File.join(dir, "bluebook"))
    File.write(File.join(dir, "bluebook/shelf.bluebook"), FLAGGED_SHELF_BLUEBOOK)
    File.write(File.join(dir, "bluebook/shelf.hecksagon"), FLAGGED_SHELF_HECKSAGON)
  end

  describe "Hecks::CLI.launcher_words" do
    def words(name, *rest) = Hecks::CLI.launcher_words(name, rest)

    it "drops --wait and --confirm, with or without a Boolean word", :aggregate_failures do
      expect(words("model_check", "--wait", "a", "--confirm=yes")).to eq([["a"], nil])
      expect(words("smoke_test", "--wait", "no", "a")).to eq([["a"], nil])
    end

    it "refuses a --wait that is not Boolean" do
      expect(words("smoke_test", "--wait=maybe").last).to include("not Boolean")
    end

    it "turns name=value into the subcommand's positionals and flags", :aggregate_failures do
      expect(words("narrate", "domain=examples/banking", "aggregate=Account"))
        .to eq([%w[examples/banking Account], nil])
      expect(words("model_check", "domains=a,b", "strict=true", "profile=client", "run=r1"))
        .to eq([%w[--strict --profile client a b], nil])
      expect(words("smoke_test", "domain=examples/banking")).to eq([%w[examples/banking], nil])
    end

    it "refuses a name the verb does not take, and a domain that is not there", :aggregate_failures do
      expect(words("stores", "nope=1").last).to include('no argument "nope" — this verb takes domain')
      expect(words("stores", "domain=examples/nowhere").last).to eq('no such domain "examples/nowhere"')
    end

    it "leaves run and mcp words alone, and project_diagrams' name=value to the launcher", :aggregate_failures do
      expect(words("run", "--wait", "a=b")).to eq([["--wait", "a=b"], nil])
      expect(Hecks::CLI.launcher_form?(%w[project_diagrams domain=x chapter=Y])).to be(true)
      expect(Hecks::CLI.launcher_form?(%w[project_diagrams x Y])).to be(false)
      expect(Hecks::CLI.launcher_form?(%w[run a=b])).to be(false)
    end
  end

  it "answers narrate with aggregate= as it does positionally", :aggregate_failures, :io do
    out, err, status = hecks("narrate", "examples/banking", "aggregate=Account")

    expect(status.exitstatus).to eq(0), err
    expect(out).to eq(hecks("narrate", "examples/banking", "Account").first)
  end

  it "answers stores with domain=", :aggregate_failures, :io do
    out, err, status = hecks("stores", "domain=examples/banking")

    expect(status.exitstatus).to eq(0), err
    expect(out).to start_with("{")
  end

  it "does not take --wait for a domain path in smoke_test, and refuses a missing directory", :aggregate_failures, :io do
    _, err, status = hecks("smoke_test", "--wait", "examples/nowhere")

    expect(status.exitstatus).to eq(1)
    expect(err).to include('no such domain "examples/nowhere"')
  end

  it "exits 1 for model_check --wait when the model is flagged", :aggregate_failures, :io do
    write_flagged_shelf(dir)

    out, _, status = hecks("model_check", "--wait", dir)

    expect(status.exitstatus).to eq(1)
    expect(out).to include("THE MODEL HAS FINDINGS")
    expect(out).not_to include("0 chapter")
  end

  it "answers project_diagrams for an unknown chapter as the launcher does", :aggregate_failures, :io do
    _, err, status = hecks("project_diagrams", "examples/banking", "Nope")

    expect(status.exitstatus).to eq(1)
    expect(err).to include("no chapter named Nope")
  end

  it "returns a subcommand's own Integer status from start" do
    allow(Hecks::CLI).to receive(:dispatch).and_return(3)

    expect(Hecks::CLI.start(%w[stores], out: StringIO.new, err: StringIO.new)).to eq(3)
  end
end
