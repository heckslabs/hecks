require "spec_helper"
require "open3"
require "rbconfig"
require "tmpdir"
require "fileutils"
require "hecks/cli/interview_draft"

# The generator from an interview's accepted findings to a first domain (ADR 0088): what reaches
# the bluebook, what is only recorded, and that the result boots and runs.
RSpec.describe Hecks::CLI::InterviewDraft do
  def interview(**overrides)
    { reference: "INT-1", subject: "Lending", expert: "Maria",
      exchanges: [{ question: "What do you keep?", answer: "Books, each with an ISBN.", topic: "catalogue" },
                  { question: "What happens?", answer: "We put it on the shelf.", topic: nil },
                  { question: "And at home?", answer: "We lend it to one person.", topic: nil }],
      things: [{ number: 1, name: "Book", identifier: "isbn", source: 1, status: "accepted" }],
      actions: [{ number: 2, name: "Shelve", thing: "Book", event: "BookShelved", creates: true, source: 2, status: "accepted" },
                { number: 3, name: "Lend a book", thing: "Book", event: "BookLent", creates: nil, source: 3,
status: "accepted" }],
      rules: [{ number: 4, statement: "A book cannot be lent twice at once", source: 3, status: "accepted" },
              { number: 5, statement: "Reference books never leave", source: 1, status: "rejected" }] }.merge(overrides)
  end

  let(:bluebook) { described_class.files(interview).fetch("bluebook/lending.bluebook") }

  it "writes an aggregate for an accepted thing, identified by the field the expert named" do
    expect(bluebook).to include('aggregate "Book" do', "identified_by :isbn", "attribute :isbn, Isbn", 'value_object "Isbn" do')
  end

  it "writes a creating action with the identifier, and any other action on the thing it names" do
    expect(bluebook).to include('command "Shelve" do', 'emits "BookShelved"')
    expect(bluebook[/command "Shelve".*?^    end/m]).to include("attribute :isbn, Isbn")
    expect(bluebook[/command "LendABook".*?^    end/m]).to include("reference_to Book", 'emits "BookLent"')
  end

  it "cites the exchange every name came from, with a short quotation of the answer" do
    expect(bluebook).to include('# from INT-1 #1: "Books, each with an ISBN."', '# from INT-1 #2: "We put it on the shelf."')
  end

  it "keeps an accepted rule as a comment, never as code, and leaves a rejected one out" do
    expect(bluebook).to include("#   - INT-1 #3: A book cannot be lent twice at once")
    expect(bluebook).not_to include("Reference books never leave")
    expect(bluebook).not_to match(/^\s+given\b/)
  end

  it "stubs the creating command when no accepted action creates, and says so" do
    stubbed = interview(actions: [interview[:actions].last])
    text = described_class.files(stubbed).fetch("bluebook/lending.bluebook")

    expect(text).to include('command "Create" do', 'emits "BookCreated"', "TODO: no action that creates was accepted")
  end

  it "keeps an accepted action whose thing was not accepted, as a comment, not lost" do
    orphan = interview(actions: [{ number: 6, name: "Renew", thing: "Loan", event: "LoanRenewed", source: 3,
status: "accepted" }])
    text = described_class.files(orphan).fetch("bluebook/lending.bluebook")

    expect(text).to include("UNPLACED", "INT-1 #3: Renew on Loan, announcing LoanRenewed")
    expect(text).not_to include('command "Renew"')
  end

  it "reads free-text names as safe Ruby words" do
    messy = interview(things:  [{ number: 1, name: "library card!", identifier: "card number", source: 1, status: "accepted" }],
                      actions: [])
    text = described_class.files(messy).fetch("bluebook/lending.bluebook")

    expect(text).to include('aggregate "LibraryCard" do', "identified_by :card_number", 'emits "LibraryCardCreated"')
  end

  it "refuses an interview with no accepted thing" do
    none = interview(things: [{ number: 1, name: "Book", identifier: "isbn", source: 1, status: "rejected" }])

    expect { described_class.files(none) }.to raise_error(ArgumentError, /at least one thing/)
  end

  it "writes the files around the bluebook that hecks init writes, for the chosen adapter" do
    files = described_class.files(interview, adapter: "Postgres")

    expect(files.keys).to include("bluebook/lending.world", "bluebook/environments/memory.world", "interviews/INT-1.md")
    expect(files.fetch("bluebook/lending.world")).to eq(Hecks::CLI::DomainStub.support_files(name: "Lending", adapter: "Postgres")
                                                          .fetch("bluebook/lending.world"))
  end

  it "records every exchange in order and every finding with how it was decided" do
    record = described_class.record(interview)

    expect(record).to include("# Interview INT-1: Lending", "Expert: Maria", "_Topic: catalogue_")
    expect(record.index("What do you keep?")).to be < record.index("And at home?")
    expect(record).to include("- Thing 1, accepted: **Book**, identified by `isbn` (exchange 1)",
                              "- Rule 5, rejected: Reference books never leave (exchange 1)")
  end

  it "offers a later interview's findings as proposed additions and writes no bluebook" do
    files = described_class.additions(interview)

    expect(files.keys).to eq(["interviews/INT-1.md"])
    expect(files.fetch("interviews/INT-1.md")).to include("## Proposed additions", "```ruby", 'aggregate "Book" do')
  end

  it "keeps the record's file name safe" do
    expect(described_class.files(interview(reference: "INT 1/a")).keys).to include("interviews/INT_1_a.md")
  end

  # The whole path, in a child process: a real SME interview, its record, the draft written to disk,
  # and the draft booted and run. The aggregate constants each boot installs stay out of this process.
  DRAFT_TRIP = <<~RUBY.freeze
    require "hecks"
    require "hecks/cli/interview_draft"
    require "fileutils"
    rt = Hecks.boot("lib/hecks/sme")
    i = Interview.plan!(reference: "INT-1", subject: "Lending", expert: "Maria")
    i.begin!
    i.record!(question: "What do you keep?", answer: "Books, each with an ISBN.")
    i.record!(question: "What happens?", answer: "We put it on the shelf.")
    i.record!(question: "And at home?", answer: "We lend it to one person.")
    i.propose_thing!(number: 1, name: "Book", identifier: "isbn", source: 1)
    i.propose_action!(number: 2, name: "Shelve", thing: "Book", event: "BookShelved", creates: true, source: 2)
    i.propose_action!(number: 3, name: "Lend a book", thing: "Book", event: "BookLent", source: 3)
    i.propose_rule!(number: 4, statement: "A book cannot be lent twice at once", source: 3)
    decide = ->(entity, verb, n) { rt.dispatch_flat("SME::Interview.\#{entity}.\#{verb}", reference: { value: "INT-1" }, number: { value: n }) }
    decide.("ThingFinding", "AcceptThing", 1)
    decide.("ActionFinding", "AcceptAction", 2)
    decide.("ActionFinding", "AcceptAction", 3)
    decide.("RuleFinding", "AcceptRule", 4)
    Interview.find("INT-1").conclude!
    draft = Hecks::CLI::InterviewDraft.files(Hecks::CLI::InterviewDraft.from_record(Interview.find("INT-1")), adapter: "Memory")
    draft.each do |path, text|
      full = File.join(ARGV.first, path)
      FileUtils.mkdir_p(File.dirname(full))
      File.write(full, text)
    end
  RUBY

  DRAFT_BOOT = <<~RUBY.freeze
    require "hecks"
    Hecks.boot(ARGV.first)
    book = Book.shelve!(isbn: "978-0")
    book.lend_a_book!
    puts "EVENTS=" + book.events.map(&:name).join(",")
  RUBY

  it "turns a real interview into a domain that boots and runs" do
    Dir.mktmpdir do |dir|
      _out, err, status = Open3.capture3(RbConfig.ruby, "-Ilib", "-e", DRAFT_TRIP, dir, chdir: InMemoryDomain::ROOT)
      expect(status).to be_success, err

      out, err, status = Open3.capture3(RbConfig.ruby, "-Ilib", "-e", DRAFT_BOOT, dir, chdir: InMemoryDomain::ROOT)
      expect(status).to be_success, err
      expect(out).to include("EVENTS=BookShelved,BookLent")
      expect(File.read(File.join(dir, "interviews/INT-1.md"))).to include("Rule 4, accepted: A book cannot be lent twice at once")
    end
  end
end
