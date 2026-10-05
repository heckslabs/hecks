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
  # A Book with fields, commands that take some of them, and the steps of its lifecycle.
  let(:shaped) do
    interview(
      fields:      [accepted(number: 2, thing: "Book", name: "title"),
                    accepted(number: 3, thing: "Book", name: "condition", values: "good, worn or new"),
                    accepted(number: 4, thing: "Book", name: "status", values: "shelved, lent")],
      actions:     [accepted(number: 5, name: "Shelve", thing: "Book", event: "BookShelved", creates: true, takes: "title"),
                    accepted(number: 6, name: "Lend a book", thing: "Book", event: "BookLent",
                             takes: "condition, colour", by: "a librarian")],
      transitions: [accepted(number: 7, thing: "Book", action: "Shelve", to: "Shelved"),
                    accepted(number: 8, thing: "Book", action: "Lend a book", from: "shelved", to: "lent"),
                    accepted(number: 9, thing: "Book", action: "Archive", from: "lent", to: "archived")]
    )
  end
  let(:shaped_bluebook) { described_class.files(shaped).fetch("bluebook/lending.bluebook") }

  def accepted(**finding) = { status: "accepted", source: 1 }.merge(finding)

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

  it "writes a field as an attribute, required when the creating action takes it and optional otherwise" do
    expect(shaped_bluebook).to include("attribute :title, Title\n", "attribute :condition, Condition, optional: true")
    expect(shaped_bluebook).not_to include("attribute :title, Title, optional")
  end

  it "writes a closed set when the expert listed values, and free text when they did not" do
    expect(shaped_bluebook).to include('attribute :value, String, one_of: ["good", "worn", "new"]')
    expect(shaped_bluebook[/value_object "Title".*?^    end/m]).not_to include("one_of")
  end

  it "gives a command the fields it takes and sets them, and notes who may do it without declaring a role" do
    lend = shaped_bluebook[/command "LendABook".*?^    end/m]

    expect(lend).to include("attribute :condition, Condition", "sets :condition", "# Who: a librarian")
    expect(lend).to include("# TODO: takes colour, but no accepted field of that name.")
    expect(shaped_bluebook).not_to match(/^\s+role\b/)
    expect(shaped_bluebook[/command "Shelve".*?^    end/m]).to include("attribute :title, Title")
  end

  it "starts the lifecycle where the creating action leaves the thing, and leaves a status field out" do
    expect(shaped_bluebook).to include('lifecycle :status, default: "shelved" do',
                                       'transition "LendABook" => "lent", from: "shelved"')
    expect(shaped_bluebook).not_to include("attribute :status")
  end

  it "keeps a transition for an action nobody accepted as a comment, not lost" do
    expect(shaped_bluebook).to include("# UNPLACED transition: Archive to archived")
    expect(shaped_bluebook).not_to include('transition "Archive"')
  end

  it "writes one command for an action accepted more than once, joining what it takes and who does it" do
    twice = shaped.merge(
      actions: [accepted(number: 5, name: "Shelve", thing: "Book", event: "BookShelved", creates: true, takes: "title"),
                accepted(number: 6, name: "Lend a book", thing: "Book", event: "BookLent", takes: "condition", by: "people"),
                accepted(number: 7, name: "Lend a book", thing: "Book", event: "BookLent", takes: "condition, title",
                         by: "members")]
    )
    text = described_class.files(twice).fetch("bluebook/lending.bluebook")
    lend = text[/command "LendABook".*?^    end/m]

    expect(text.scan('command "LendABook"').size).to eq(1)
    expect(lend).to include("attribute :condition, Condition", "attribute :title, Title", "# Who: people or members")
  end

  it "keeps a creating action creating when only one of its acceptances said it creates" do
    twice = shaped.merge(
      actions: [accepted(number: 5, name: "Shelve", thing: "Book", event: "BookShelved"),
                accepted(number: 6, name: "Shelve", thing: "Book", event: "BookShelved", creates: true)]
    )
    text = described_class.files(twice).fetch("bluebook/lending.bluebook")

    expect(text).not_to include("no action that creates was accepted")
    expect(text[/command "Shelve".*?^    end/m]).to include("attribute :isbn, Isbn")
  end

  it "writes an aggregate once when the same thing was accepted twice" do
    twice = shaped.merge(things: [accepted(number: 1, name: "Book", identifier: "isbn"),
                                  accepted(number: 8, name: "Book", identifier: "isbn")])

    expect(described_class.files(twice).fetch("bluebook/lending.bluebook").scan('aggregate "Book"').size).to eq(1)
  end

  it "does not count the identifier among what an action takes" do
    takes_it = shaped.merge(actions: [accepted(number: 5, name: "Shelve", thing: "Book", event: "BookShelved",
                                               creates: true, takes: "isbn, title")])
    text = described_class.files(takes_it).fetch("bluebook/lending.bluebook")

    expect(text).not_to include("TODO: takes isbn")
    expect(text[/command "Shelve".*?^    end/m]).to include("attribute :title, Title")
  end

  it "starts the lifecycle at the first state a change names when no action creates the thing" do
    unnamed = shaped.merge(actions:     [accepted(number: 5, name: "Lend a book", thing: "Book", event: "BookLent")],
                           transitions: [accepted(number: 6, thing: "Book", action: "Lend a book", from: "shelved",
                                                  to: "lent")])
    text = described_class.files(unnamed).fetch("bluebook/lending.bluebook")

    expect(text).to include('lifecycle :status, default: "shelved" do', 'transition "LendABook" => "lent", from: "shelved"')
  end

  it "writes no lifecycle when no transition was accepted" do
    expect(bluebook).not_to include("lifecycle")
  end

  it "joins steps that lead an action to the same state from different ones" do
    twice = shaped.merge(transitions: [accepted(number: 7, thing: "Book", action: "Shelve", to: "shelved"),
                                       accepted(number: 8, thing: "Book", action: "Lend a book", from: "shelved", to: "lent"),
                                       accepted(number: 9, thing: "Book", action: "Lend a book", from: "returned", to: "lent")])
    text = described_class.files(twice).fetch("bluebook/lending.bluebook")

    expect(text.scan('transition "LendABook"').size).to eq(1)
    expect(text).to include('transition "LendABook" => "lent", from: %w[shelved returned]')
  end

  it "allows a transition from several states" do
    several = shaped.merge(transitions: [accepted(number: 7, thing: "Book", action: "Shelve", to: "shelved"),
                                         accepted(number: 8, thing: "Book", action: "Lend a book", from: "shelved, returned",
                                                  to: "lent")])

    expect(described_class.files(several).fetch("bluebook/lending.bluebook")).to include("from: %w[shelved returned]")
  end

  it "records fields, transitions and what an action takes in the record, and offers them as additions" do
    record = described_class.record(shaped)

    expect(record).to include("- Field 3, accepted: **condition** on Book, one of good, worn or new (exchange 1)",
                              "- Transition 8, accepted: **Lend a book** on Book to lent from shelved (exchange 1)",
                              "takes condition, colour, by a librarian")
    expect(described_class.additions(shaped).fetch("interviews/INT-1.md")).to include("lifecycle :status")
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
    i.propose_action!(number: 8, name: "Lend a book", thing: "Book", event: "BookLent", takes: "condition", source: 3)
    i.propose_field!(number: 5, thing: "Book", name: "condition", values: "good, worn", source: 1)
    i.propose_transition!(number: 6, thing: "Book", action: "Shelve", to: "shelved", source: 2)
    i.propose_transition!(number: 7, thing: "Book", action: "Lend a book", from: "shelved", to: "lent", source: 3)
    decide = ->(entity, verb, n) { rt.dispatch_flat("SME::Interview.\#{entity}.\#{verb}", reference: { value: "INT-1" }, number: { value: n }) }
    decide.("ThingFinding", "AcceptThing", 1)
    decide.("ActionFinding", "AcceptAction", 2)
    decide.("ActionFinding", "AcceptAction", 3)
    decide.("RuleFinding", "AcceptRule", 4)
    decide.("ActionFinding", "AcceptAction", 8)
    decide.("FieldFinding", "AcceptField", 5)
    decide.("TransitionFinding", "AcceptTransition", 6)
    decide.("TransitionFinding", "AcceptTransition", 7)
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
    book.lend_a_book!(condition: "good")
    puts "EVENTS=" + book.events.map(&:name).join(",")
    puts "STATUS=" + book.status.to_s
  RUBY

  it "turns a real interview into a domain that boots and runs" do
    Dir.mktmpdir do |dir|
      _out, err, status = Open3.capture3(RbConfig.ruby, "-Ilib", "-e", DRAFT_TRIP, dir, chdir: InMemoryDomain::ROOT)
      expect(status).to be_success, err

      out, err, status = Open3.capture3(RbConfig.ruby, "-Ilib", "-e", DRAFT_BOOT, dir, chdir: InMemoryDomain::ROOT)
      expect(status).to be_success, err
      expect(out).to include("EVENTS=BookShelved,BookLent", "STATUS=lent")
      expect(File.read(File.join(dir, "interviews/INT-1.md"))).to include("Rule 4, accepted: A book cannot be lent twice at once")
    end
  end
end
