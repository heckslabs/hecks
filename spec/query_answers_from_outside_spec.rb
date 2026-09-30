require "spec_helper"
require "tmpdir"
require "fileutils"
require "digest"
require "hecks/behaviors/rspec"

# A query answered from outside the domain is bound in the hecksagon, never in the bluebook:
# the port's adapter answers in a declared shape, every row says when it was taken, and a query
# that selects nothing and is bound to nothing is refused at boot.
RSpec.describe "a query answered by a port the hecksagon binds" do
  OUTSIDE_BLUEBOOK = <<~RUBY.freeze
    Hecks.bluebook "Lookup" do
      vision "Answers come from an adapter, not from stored records."

      aggregate "Note" do
        description "A stored note."

        attribute :title, Title
        identified_by :title

        value_object "Title" do
          attribute :value, String, pattern: '[^ \\t\\n\\r]'
          invariant("a note is titled") { !value.to_s.empty? }
        end

        query "Echo" do
          attribute :title, Title
        end

        query "Roster" do
          description "The notes the adapter lists."
        end

        query "Recent" do
          where(title: "x")
        end

        command "Write" do
          attribute :title, Title
          sets :title
          emits Written
        end
      end
    end
  RUBY

  OUTSIDE_HECKSAGON = <<~RUBY.freeze
    Hecks.hecksagon "Lookup" do
      persisted_by "Memory"

      Lookup::Note.port "Echoer" do
        answers_query "Echo", shape: :row
        answers_query "Roster", shape: :rows
      end
    end
  RUBY

  ECHOER_BODY = <<~RUBY.freeze
    def echo(title:)
      { heard: title }
    end

    def roster
      [{ title: "a" }, { title: "b" }]
    end
  RUBY

  def adapter_files(dir, name:, klass:, body:)
    FileUtils.mkdir_p(File.join(dir, "adapters"))
    File.write(File.join(dir, "adapters", "#{name}.adapter"), <<~RUBY)
      require_relative "#{name}"

      Hecks.adapter "#{klass}" do
        port "Echoer"
      end
    RUBY
    methods = body.gsub(/^(?=.)/, "      ")
    File.write(File.join(dir, "adapters", "#{name}.rb"), <<~RUBY)
      module Hecks
        module Adapters
          class #{klass}
            def initialize(aggregate: nil, settings: {}, root: nil); end

      #{methods}
          end
        end
      end
    RUBY
  end

  def write_domain(dir, bluebook: OUTSIDE_BLUEBOOK, hecksagon: OUTSIDE_HECKSAGON)
    FileUtils.mkdir_p(File.join(dir, "bluebook"))
    File.write(File.join(dir, "bluebook/lookup.bluebook"), bluebook)
    File.write(File.join(dir, "bluebook/lookup.hecksagon"), hecksagon)
    adapter_files(File.join(dir, "bluebook"), name: "answering_echoer", klass: "AnsweringEchoer", body: ECHOER_BODY)
  end

  def boot_domain(**options)
    write_domain(@dir, **options)
    Hecks.boot(@dir, install_facade: false)
  end

  around do |example|
    Dir.mktmpdir("outside") do |dir|
      @dir = dir
      example.run
    end
  end

  it "answers from the adapter, handing it plain data, and says when it was taken" do
    row = boot_domain.query("Lookup::Note.Echo", title: "hello").first

    expect(row[:heard]).to eq(value: "hello")
    expect(row[:taken_at]).to match(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\z/)
  end

  it "stamps every row of a rows answer" do
    rows = boot_domain.query("Lookup::Note.Roster")

    expect(rows.map { |row| row[:title] }).to eq(%w[a b])
    expect(rows.map { |row| row[:taken_at] }.uniq.size).to eq(1)
  end

  it "reads no record and writes no event" do
    runtime = boot_domain
    runtime.query("Lookup::Note.Echo", title: "hello")

    expect(runtime.registry.event_log.to_a).to be_empty
  end

  it "gives the reference oracle the adapter's rows unstamped" do
    expect(boot_domain.reference_query("Lookup::Note.Echo", title: "hello"))
      .to eq([{ heard: { value: "hello" } }])
  end

  it "carries the binding in the hecksagon's IR, on the port, and not in the bluebook's queries" do
    note    = boot_domain.registry.bluebook("Lookup").aggregate("Note")
    emitted = note.queries.to_h { |query| [query.name, query.to_h] }

    expect(note.port("Echoer").to_h[:answered_queries])
      .to eq([{ name: "Echo", shape: "row" }, { name: "Roster", shape: "rows" }])
    expect(emitted.values.flat_map(&:keys)).not_to include(:answered_by)
    expect(note.query_binding("Recent")).to be_nil
  end

  it "refuses an answer that is not the declared shape, naming the query" do
    runtime = boot_domain(hecksagon: OUTSIDE_HECKSAGON.sub("shape: :row", "shape: :text"))

    expect { runtime.query("Lookup::Note.Echo", title: "hello") }
      .to raise_error(Hecks::Runtime::WiringError, /Note\.Echo is bound as :text, but its adapter answered Hash/)
  end

  it "refuses a port no adapter implements, naming the port and the query" do
    runtime = boot_domain(hecksagon: OUTSIDE_HECKSAGON.sub('port "Echoer"', 'port "Nobody"'))

    expect { runtime.query("Lookup::Note.Echo", title: "hello") }
      .to raise_error(Hecks::Runtime::WiringError, /no adapter implements the Nobody port.*Note\.Echo/)
  end

  describe "at boot" do
    it "refuses a query whose arguments select nothing and that is bound by no port" do
      hecksagon = OUTSIDE_HECKSAGON.sub(%(    answers_query "Echo", shape: :row\n), "")

      expect { boot_domain(hecksagon: hecksagon) }
        .to raise_error(Hecks::Runtime::WiringError,
                        /Lookup::Note\.Echo declares no where and no hecksagon binds it.*\(title\)/)
    end

    it "keeps a query with no arguments and no clause as the plain list of records" do
      hecksagon = OUTSIDE_HECKSAGON.sub(%(    answers_query "Roster", shape: :rows\n), "")

      expect(boot_domain(hecksagon: hecksagon).query("Lookup::Note.Roster")).to eq([])
    end

    it "refuses a binding that names a query the aggregate does not declare" do
      expect { boot_domain(hecksagon: OUTSIDE_HECKSAGON.sub('"Roster"', '"Census"')) }
        .to raise_error(Hecks::Runtime::WiringError, /binds Lookup::Note\.Census, which the aggregate does not declare/)
    end

    it "refuses a binding on a query that also filters stored records" do
      expect { boot_domain(hecksagon: OUTSIDE_HECKSAGON.sub('"Roster"', '"Recent"')) }
        .to raise_error(Hecks::Runtime::WiringError,
                        /Lookup::Note\.Recent is bound to the Echoer port but also declares where/)
    end

    it "refuses a shape the language does not know" do
      expect { boot_domain(hecksagon: OUTSIDE_HECKSAGON.sub("shape: :rows", "shape: :xml")) }
        .to raise_error(Hecks::Bluebook::DSL::Malformed, /answers as :xml/)
    end
  end

  describe "a behaviors file swapping in a fake adapter" do
    def fingerprint
      Dir[File.join(@dir, "bluebook", "lookup.*")].to_h { |file| [file, Digest::SHA256.file(file).hexdigest] }
    end

    def write_fake_behaviors
      fake = File.join(@dir, "fake")
      FileUtils.mkdir_p(fake)
      File.write(File.join(fake, "anchor.hecksagon"), %(Hecks.hecksagon "Lookup" do\nend\n))
      adapter_files(fake, name: "answering_fake_echoer", klass: "AnsweringFakeEchoer", body: <<~RUBY)
        def echo(title:)
          { heard: "fake" }
        end
      RUBY
      File.write(File.join(fake, "lookup.behaviors"), <<~RUBY)
        Hecks.behaviors "Lookup" do
          vision "The lookup, heard from a fake."

          loads "anchor.hecksagon", "../bluebook/lookup.bluebook", "../bluebook/lookup.hecksagon"

          test "Echo answers what the fake heard" do
            tests "Echo", on: "Note", kind: :query
            input title: { value: "hi" }
            expect heard: "fake"
          end
        end
      RUBY
      File.join(fake, "lookup.behaviors")
    end

    it "answers from the fake for the same, untouched bluebook and hecksagon" do
      write_domain(@dir)
      behaviors = write_fake_behaviors
      before = fingerprint

      outcome = Hecks::Behaviors.run(behaviors)

      expect(outcome.parse_error).to be_nil
      expect(outcome.runs.map(&:status)).to eq([:pass]), outcome.runs.map(&:message).inspect
      expect(fingerprint).to eq(before)
    end
  end
end
