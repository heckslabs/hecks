require "spec_helper"
require "tmpdir"
require "fileutils"
require_relative "../../../lib/hecks/hecks/adapters/in_process_boot"

# What the DomainRuntime port's adapter does when a journaled Custodian command asks it to run
# something: the answer is the text an existing `Hecks::CLI::*` entry point printed, and anything
# that would have exited non-zero is a raise, which the runtime records as a refusal.
RSpec.describe Hecks::Adapters::InProcessOperations do
  OPERATIONS_BLUEBOOK = <<~RUBY.freeze
    Hecks.bluebook "Shelf" do
      vision "Books on a shelf."

      aggregate "Book" do
        description "A book."

        attribute :title, Title
        identified_by :title

        value_object "Title" do
          attribute :value, String, pattern: '[^ \\t\\n\\r]'
          invariant("a book is titled") { !value.to_s.empty? }
        end

        command "Shelve" do
          attribute :title, Title
          sets :title
          emits Shelved
        end
      end
    end
  RUBY

  around do |example|
    @dir = Dir.mktmpdir("operations")
    FileUtils.mkdir_p(File.join(@dir, "bluebook"))
    File.write(File.join(@dir, "bluebook/shelf.bluebook"), OPERATIONS_BLUEBOOK)
    File.write(File.join(@dir, "bluebook/shelf.hecksagon"), %(Hecks.hecksagon "Shelf" do\n  persisted_by "Memory"\nend\n))
    example.run
  ensure
    FileUtils.rm_rf(@dir)
  end

  let(:adapter) { Hecks::Adapters::InProcessBoot.new }

  def held(**fields) = fields.transform_values { |value| { value: value } }

  describe "#check" do
    it "answers the report when the model is clean" do
      answer = adapter.check(**held(domains: @dir))

      expect(answer.dig(:report, :value)).to include("clean")
    end

    it "passes --strict and --profile through to the analysis" do
      answer = adapter.check(**held(domains: @dir, profile: "client"), strict: { value: true })

      expect(answer.dig(:report, :value)).to include("clean")
    end

    it "splits a comma separated list of domains" do
      other = Dir.mktmpdir("operations-other")
      FileUtils.cp_r(File.join(@dir, "bluebook"), other)
      answer = adapter.check(**held(domains: "#{@dir},#{other}"))

      expect(answer.dig(:report, :value).scan("clean").size).to be >= 2
    ensure
      FileUtils.rm_rf(other)
    end

    it "refuses a domain that is not there" do
      Dir.mktmpdir do |scratch|
        expect { adapter.check(**held(domains: File.join(scratch, "no/such/domain"))) }
          .to raise_error(Hecks::Runtime::NotFound, /no such domain/)
      end
    end
  end

  describe "#execute" do
    it "dispatches a verb and answers what it did" do
      answer = adapter.execute(**held(subject: @dir, verb: "book.shelve"), arguments: [{ value: "title.value=Dune" }])

      expect(answer.dig(:output, :value)).to include("Dune")
    end

    it "refuses with the domain's own sentence when the verb is refused" do
      expect { adapter.execute(**held(subject: @dir, verb: "book.shelve")) }
        .to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /title/)
    end

    it "executes a step list from a script" do
      script = File.join(@dir, "steps.json")
      File.write(script, JSON.generate(steps: [{ verb: "Shelf::Book.Shelve", args: { title: { value: "Dune" } } }]))
      answer = adapter.execute(**held(subject: @dir, script: script))

      expect(answer.dig(:output, :value)).to include("Shelved")
    end
  end

  describe "#refresh" do
    it "reports how many projections it caught up" do
      expect(adapter.refresh(**held(subject: @dir)).dig(:output, :value)).to eq("refreshed 0 projection(s)")
    end

    it "refuses a domain that is not there" do
      Dir.mktmpdir do |scratch|
        expect { adapter.refresh(**held(subject: File.join(scratch, "no/such/domain"))) }
          .to raise_error(Hecks::Runtime::NotFound)
      end
    end
  end

  describe "#verify" do
    it "answers the per-test report of a behaviors file" do
      File.write(File.join(@dir, "bluebook/shelf.behaviors"), <<~RUBY)
        Hecks.behaviors "Shelf" do
          vision "Books are shelved."
          loads "shelf.bluebook", "shelf.hecksagon"

          test "Shelve records a book" do
            tests "Shelve", on: "Book"
            input title: { value: "Dune" }
            expect emits: ["Shelved"]
          end
        end
      RUBY

      answer = adapter.verify(**held(subject: File.join(@dir, "bluebook/shelf.behaviors")))

      expect(answer.dig(:output, :value)).to include("ok    Shelve records a book")
    end

    it "refuses when a test fails" do
      File.write(File.join(@dir, "bluebook/shelf.behaviors"), <<~RUBY)
        Hecks.behaviors "Shelf" do
          vision "Books are shelved."
          loads "shelf.bluebook", "shelf.hecksagon"

          test "Shelve emits something else" do
            tests "Shelve", on: "Book"
            input title: { value: "Dune" }
            expect emits: ["Lent"]
          end
        end
      RUBY

      expect { adapter.verify(**held(subject: File.join(@dir, "bluebook/shelf.behaviors"))) }
        .to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /FAIL/)
    end
  end

  describe "#smoke" do
    it "answers that every command dispatched cleanly" do
      expect(adapter.smoke(**held(subject: @dir)).dig(:output, :value)).to include("dispatched cleanly")
    end
  end

  describe "#follow" do
    let(:entries) do
      [Hecks::Runtime::Event.new(name: "Shelved", aggregate: "Shelf::Book", id: "Dune", payload: {}, occurred_at: "now"),
       Hecks::Runtime::Event.new(name: "Lent", aggregate: "Shelf::Loan", id: "1", payload: {}, occurred_at: "now")]
    end

    before { allow(adapter).to receive(:event_repository).and_return(double(events: entries)) }

    it "answers every entry and a cursor at the end" do
      answer = adapter.follow(domain: @dir)

      expect(answer[:cursor]).to eq(2)
      expect(answer[:events].map { |event| event["name"] }).to eq(%w[Shelved Lent])
    end

    it "answers only what is past the cursor it was given" do
      answer = adapter.follow(domain: @dir, since: 1)

      expect(answer[:events].map { |event| event["name"] }).to eq(["Lent"])
    end

    it "filters by the aggregate's bare name, in any case" do
      answer = adapter.follow(domain: @dir, aggregate: "book")

      expect(answer[:events].map { |event| event["name"] }).to eq(["Shelved"])
    end

    it "skips what exists when told to start from now" do
      answer = adapter.follow(domain: @dir, from_now: true)

      expect(answer).to include(cursor: 2, events: [])
    end

    it "waits no longer than asked for a first entry, then answers the same cursor" do
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      answer = adapter.follow(domain: @dir, since: 2, wait: 1, interval: 0.1)

      expect(answer).to include(cursor: 2, events: [])
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 3
    end
  end

  describe "#stream" do
    let(:entries) do
      [Hecks::Runtime::Event.new(name: "Shelved", aggregate: "Shelf::Book", id: "Dune", payload: {}, occurred_at: "now")]
    end

    before { allow(adapter).to receive(:event_repository).and_return(double(events: entries)) }

    def appended(name) = Hecks::Runtime::Event.new(name: name, aggregate: "Shelf::Book", id: "x", payload: {}, occurred_at: "now")

    it "hands over each entry the moment the log shows it, not when the read ends" do
      seen = []
      writer = Thread.new do
        sleep 0.15
        entries << appended("Lent")
        sleep 0.15
        entries << appended("Returned")
      end

      cursor = adapter.stream(domain: @dir, from_now: true, limit: 2, timeout: 5, interval: 0.02) do |entry|
        seen << [entry["name"], entries.size]
      end
      writer.join

      expect(seen).to eq([["Lent", 2], ["Returned", 3]])
      expect(cursor).to eq(3)
    end

    it "stops at the limit and answers a cursor just past the last entry handed over" do
      entries.push(appended("Lent"), appended("Returned"))
      names = []

      cursor = adapter.stream(domain: @dir, limit: 2) { |entry| names << entry["name"] }

      expect(names).to eq(%w[Shelved Lent])
      expect(cursor).to eq(2)
    end

    it "stops when the block says so, and resumes from the cursor it answered" do
      entries.push(appended("Lent"))
      first = []
      cursor = adapter.stream(domain: @dir) { |entry| first << entry["name"] and :stop }
      rest = []
      adapter.stream(domain: @dir, since: cursor, timeout: 0) { |entry| rest << entry["name"] }

      expect([first, rest]).to eq([["Shelved"], ["Lent"]])
    end

    it "ends at its timeout when nothing arrives" do
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      cursor = adapter.stream(domain: @dir, since: 1, timeout: 0.3, interval: 0.05) { raise "no entry expected" }

      expect(cursor).to eq(1)
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be_between(0.25, 2)
    end

    it "ends quietly when the reader goes away" do
      cursor = adapter.stream(domain: @dir, timeout: 5) { raise Errno::EPIPE }

      expect(cursor).to eq(1)
    end

    it "keeps only the aggregate asked for" do
      entries << Hecks::Runtime::Event.new(name: "Lent", aggregate: "Shelf::Loan", id: "1", payload: {}, occurred_at: "now")
      names = []
      adapter.stream(domain: @dir, aggregate: "loan", timeout: 0) { |entry| names << entry["name"] }

      expect(names).to eq(["Lent"])
    end
  end

  it "refuses to follow a domain that is not there" do
    Dir.mktmpdir do |scratch|
      expect { adapter.follow(domain: File.join(scratch, "no/such/domain")) }
        .to raise_error(Hecks::Runtime::NotFound, /no such domain/)
    end
  end
end
