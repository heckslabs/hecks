require "spec_helper"
require "tmpdir"
require "json"
require "fileutils"
require "hecks/command_names"

# ADR 0163 rule 6: a bang is the only sign of a write, so a read is typed bare. `query` is taken
# only before a query whose name a command shares; before any other query the launcher refuses
# it, and `check_command_names` flags it.
RSpec.describe "the query word" do
  # The launcher's path and the old word, as methods so this file's text holds no invocation.
  def launcher = "exe/hecks"
  def old_word = "query"

  let(:runner) { Hecks::Adapters::Driving::CliRunner }

  describe "a read written with it" do
    let(:bluebook) do
      <<~RUBY
        Hecks.bluebook "Lending" do
          vision "Lend something and take it back."
          supporting
          aggregate "Loan" do
            description "A thing lent out."
            attribute :name, LoanName
            identified_by :name
            value_object "LoanName" do
              attribute :value, String, matches: :present
              invariant("a loan is named") { !value.to_s.empty? }
            end
            command "OpenLoan" do
              goal "Lend something out"
              attribute :name, LoanName
              sets :name
              emits "LoanOpened"
            end
            command "Overdue" do
              goal "Mark a loan overdue"
              attribute :name, LoanName
            end
            query "Everything" do
              description "Every loan."
              where({})
            end
            query "Overdue" do
              description "The loans past their day."
              where({})
            end
          end
        end
      RUBY
    end

    def answer(*argv)
      Dir.mktmpdir("query-word") do |dir|
        File.write(File.join(dir, "lending.bluebook"), bluebook)
        runner.call(runtime: Hecks.boot(dir, install_driving: false), argv: argv, program: "hecks")
      end
    end

    it "is refused before a query no command shares a name with, naming the bare spelling" do
      expect(answer(old_word, "Loan.everything"))
        .to eq(["hecks: query is needed only where a command shares the name; write Loan.everything bare", 2])
    end

    it "is not needed for that query, which answers by its bare name" do
      expect(answer("Loan.everything").last).to eq(0)
    end

    it "reaches the query where a command shares its name", :aggregate_failures do
      text, status = answer(old_word, "Loan.overdue")
      expect(status).to eq(0)
      expect(JSON.parse(text)).to eq([])
    end

    it "leaves the bare shared name to the command, which wants its bang" do
      expect(answer("Loan.overdue").first).to eq("hecks: Loan.overdue is a command and writes; write it as Loan.overdue!")
    end
  end

  describe "the help listing" do
    let(:runtime) { Hecks.describe(File.expand_path("../lib/hecks/hecks", __dir__), environment: nil) }
    let(:listing) { runner.usage(runtime: runtime, argv: [], program: "hecks").first }

    it "omits the old line" do
      expect(listing).not_to include("hecks #{old_word} <query>")
    end

    it "says reads are written bare" do
      expect(listing).to include("hecks <query> [name=value …]          read something, written bare")
    end
  end

  describe "check_command_names" do
    let(:root) { Dir.mktmpdir("query-word-check") }
    let(:scopes) do
      { "" => { "command" => { "ticket.file" => "Ticket.file", "patch.open" => "Patch.open" },
                "question" => { "workspace.status" => "Workspace.status", "patch.open" => "Patch.open" }, "modules" => [] } }
    end

    after { FileUtils.remove_entry(root) }

    def found(line)
      FileUtils.mkdir_p(File.join(root, "qa"))
      File.write(File.join(root, "qa", "note.md"), "Run `#{launcher} #{line}` to read it.\n")
      Hecks::CommandNames::Check.findings(root: root, scopes: scopes).map(&:to_s)
    end

    it "fires on a new use of the old word" do
      expect(found("#{old_word} workspace.status").first)
        .to include("query is needed only where a command shares the name; write workspace.status bare")
    end

    it "passes the bare spelling" do
      expect(found("workspace.status")).to be_empty
    end

    it "passes the old word where a command shares the name" do
      expect(found("#{old_word} patch.open")).to be_empty
    end
  end
end
