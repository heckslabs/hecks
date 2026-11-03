require "spec_helper"
require "tmpdir"
require "fileutils"
require "hecks/command_names"

# ADR 0163 rule 6: a bang is the only sign of a write, so a read is typed bare. `query` stays as an
# old spelling until 8.0.0: it answers the same, leaves the listing, and a new use of it is flagged.
RSpec.describe "the query word" do
  # The launcher's path and the old word, as methods so this file's text holds no invocation.
  def launcher = "exe/hecks"
  def old_word = "query"

  let(:runner) { Hecks::Adapters::Driving::CliRunner }

  describe "both spellings of one read" do
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
            query "Everything" do
              description "Every loan."
              where({})
            end
          end
        end
      RUBY
    end

    def answers
      Dir.mktmpdir("query-word") do |dir|
        File.write(File.join(dir, "lending.bluebook"), bluebook)
        runtime = Hecks.boot(dir, install_driving: false)
        [[old_word, "Loan.everything"], ["Loan.everything"]].map { |argv| runner.call(runtime: runtime, argv: argv) }
      end
    end

    it "answers the same text and status", :aggregate_failures do
      old, bare = answers
      expect(old).to eq(bare)
      expect(old.last).to eq(0)
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
      expect(found("#{old_word} workspace.status").first).to include("query is the old spelling; write workspace.status bare")
    end

    it "passes the bare spelling" do
      expect(found("workspace.status")).to be_empty
    end

    it "passes the old word where a command shares the name" do
      expect(found("#{old_word} patch.open")).to be_empty
    end
  end
end
