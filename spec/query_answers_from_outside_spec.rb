require "spec_helper"
require "tmpdir"
require "fileutils"
require "digest"
require "json"
require "open3"
require "hecks/behaviors/rspec"
require "hecks/bluebook/model_check"

# A query answered from outside the domain is declared in the bluebook, which owns the meaning:
# the question and the value object its answer takes (`returns`). The hecksagon owns the
# capability and binds the query to a port (`answers_query "Name"`), and the world configures the
# adapter. Every row an adapter answers is built as the value object before it enters the domain,
# and a query has exactly one answer path, checked at boot.
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

        value_object "Heard" do
          attribute :heard, Title
        end

        value_object "Listing" do
          attribute :title, String
          invariant("a listing is titled") { !title.to_s.empty? }
        end

        value_object "Sighting" do
          attribute :seen,     String
          attribute :taken_at, String
        end

        query "Echo" do
          attribute :title, Title
          returns Heard
        end

        query "Roster" do
          description "The notes the adapter lists."
          returns list_of(Listing)
        end

        query "Sight" do
          returns Sighting
        end

        query "Recent" do
          where(title: "x")
        end

        query "Everything" do
          description "Every note on file."
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
        answers_query "Echo"
        answers_query "Roster"
        answers_query "Sight"
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

    def sight
      { seen: "the heron", taken_at: Time.at(Hecks::Adapters::SystemClock.now).utc.iso8601 }
    end
  RUBY

  ISO_8601 = /\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\z/

  def adapter_files(dir, name:, klass:, body:, port: "Echoer")
    FileUtils.mkdir_p(File.join(dir, "adapters"))
    File.write(File.join(dir, "adapters", "#{name}.adapter"), <<~RUBY)
      require_relative "#{name}"

      Hecks.adapter "#{klass}" do
        port "#{port}"
      end
    RUBY
    methods = body.gsub(/^(?=.)/, "      ")
    File.write(File.join(dir, "adapters", "#{name}.rb"), <<~RUBY)
      require "time"

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

  # One class name per call: a class reopened by a later example would keep the methods an
  # earlier body defined, and hide a method the body under test leaves out.
  def unique(prefix) = "#{prefix}#{Digest::SHA256.hexdigest(@dir)[0, 8]}#{@serial = @serial.to_i + 1}"

  def write_domain(dir, bluebook: OUTSIDE_BLUEBOOK, hecksagon: OUTSIDE_HECKSAGON, body: ECHOER_BODY, extra: [])
    FileUtils.mkdir_p(File.join(dir, "bluebook"))
    File.write(File.join(dir, "bluebook/lookup.bluebook"), bluebook)
    File.write(File.join(dir, "bluebook/lookup.hecksagon"), hecksagon)
    name = unique("answering_echoer")
    adapter_files(File.join(dir, "bluebook"), name: name, klass: name.split("_").map(&:capitalize).join, body: body)
    extra.each { |file| adapter_files(File.join(dir, "bluebook"), **file) }
  end

  def boot_domain(**options)
    write_domain(@dir, **options)
    Hecks.boot(@dir, install_facade: false)
  end

  # The bluebook with `returns Heard` swapped for another line of Echo's body.
  def echo_with(line) = OUTSIDE_BLUEBOOK.sub("returns Heard", line)

  def without_binding(name) = OUTSIDE_HECKSAGON.sub(%(    answers_query "#{name}"\n), "")

  around do |example|
    Dir.mktmpdir("outside") do |dir|
      @dir = dir
      example.run
    end
  end

  describe "an answer that is its declared shape" do
    it "comes from the adapter, which is handed plain data, and arrives as the value object's fields" do
      row = boot_domain.query("Lookup::Note.Echo", title: "hello").first

      expect(row).to eq(heard: { value: "hello" })
    end

    it "builds every row of a list_of answer" do
      rows = boot_domain.query("Lookup::Note.Roster")

      expect(rows).to eq([{ title: "a" }, { title: "b" }])
    end

    it "stamps no time of its own: a query that wants one declares taken_at and its adapter fills it" do
      runtime = boot_domain

      expect(runtime.query("Lookup::Note.Echo", title: "hello").first.keys).to eq([:heard])
      expect(runtime.query("Lookup::Note.Sight").first[:taken_at]).to match(ISO_8601)
    end

    it "reads no record and writes no event" do
      runtime = boot_domain
      runtime.query("Lookup::Note.Echo", title: "hello")
      runtime.query("Lookup::Note.Roster")

      expect(runtime.registry.event_log.to_a).to be_empty
    end

    it "gives the reference oracle the same rows, through the same shape check" do
      expect(boot_domain.reference_query("Lookup::Note.Echo", title: "hello"))
        .to eq([{ heard: { value: "hello" } }])
    end
  end

  describe "the arguments an adapter is asked with" do
    it "refuses a required argument left out, as the derived path does, before the adapter is asked" do
      runtime = boot_domain

      expect { runtime.query("Lookup::Note.Echo") }
        .to raise_error(Hecks::Runtime::AbsentArgument, /Note\.Echo was not given title/)
    end

    it "refuses an argument the query does not declare" do
      runtime = boot_domain

      expect { runtime.query("Lookup::Note.Echo", title: "hello", extra: 1) }
        .to raise_error(Hecks::Runtime::UnknownArgument, /extra/)
    end
  end

  describe "an answer that is not its declared shape" do
    def answering_with(echo: "{ heard: title }", roster: "[]")
      boot_domain(body: "def echo(title:) = #{echo}\ndef roster = #{roster}\ndef sight = {}")
    end

    it "is refused when a field has the wrong type, naming the query" do
      runtime = answering_with(echo: "{ heard: 7 }")

      expect { runtime.query("Lookup::Note.Echo", title: "hello") }
        .to raise_error(Hecks::Runtime::TypeMismatch, /Note\.Echo answered outside the domain, but not as its Heard/)
    end

    it "is refused when a field the value object requires is missing" do
      runtime = answering_with(echo: "{}")

      expect { runtime.query("Lookup::Note.Echo", title: "hello") }
        .to raise_error(Hecks::Runtime::TypeMismatch, /Note\.Echo answered outside the domain.*heard/)
    end

    it "is refused when the adapter answers a field the value object does not declare" do
      runtime = answering_with(echo: "{ heard: title, taken_at: 'now' }")

      expect { runtime.query("Lookup::Note.Echo", title: "hello") }
        .to raise_error(Hecks::Runtime::UnknownArgument, /Note\.Echo answered outside the domain/)
    end

    it "is refused when a row breaks the value object's invariant" do
      runtime = answering_with(roster: "[{ title: 'a' }, { title: '' }]")

      expect { runtime.query("Lookup::Note.Roster") }
        .to raise_error(Hecks::Runtime::InvariantViolation,
                        /Note\.Roster answered outside the domain.*a listing is titled/)
    end

    it "is refused when it is not a row at all" do
      runtime = answering_with(echo: "'hello'")

      expect { runtime.query("Lookup::Note.Echo", title: "hello") }
        .to raise_error(Hecks::Runtime::TypeMismatch,
                        /Note\.Echo answered outside the domain, but String is not a Heard row/)
    end

    it "is refused when it is one row where a list was declared" do
      runtime = answering_with(roster: "{ title: 'a' }")

      expect { runtime.query("Lookup::Note.Roster") }
        .to raise_error(Hecks::Runtime::TypeMismatch, /Note\.Roster.*Hash is not a list of Listing row/)
    end

    it "is refused by the reference oracle as well" do
      runtime = answering_with(echo: "{ heard: 7 }")

      expect { runtime.reference_query("Lookup::Note.Echo", title: "hello") }
        .to raise_error(Hecks::Runtime::TypeMismatch, /Note\.Echo answered outside the domain/)
    end
  end

  describe "the IR" do
    it "carries the shape on the query, in the bluebook, and only the binding on the hecksagon's port" do
      note    = boot_domain.registry.bluebook("Lookup").aggregate("Note")
      emitted = note.queries.to_h { |query| [query.name, query.to_h] }

      expect(emitted["Echo"]).to include(returns: "Heard")
      expect(emitted["Roster"]).to include(returns: "list_of(Listing)")
      expect(emitted["Recent"]).not_to have_key(:returns)
      expect(note.query("Roster")).to have_attributes(returns_name: "Listing", returns_list?: true)
      expect(note.port("Echoer").to_h[:answered_queries])
        .to eq([{ name: "Echo" }, { name: "Roster" }, { name: "Sight" }])
      expect(emitted.values.flat_map(&:keys)).not_to include(:answered_by)
      expect(note.query_binding("Recent")).to be_nil
    end
  end

  describe "at boot, a query has exactly one answer path" do
    def expect_refusal(message, **options)
      expect { boot_domain(**options) }.to raise_error(Hecks::Runtime::WiringError, message)
    end

    it "refuses a query that returns a value object and is bound to no port" do
      expect_refusal(/Lookup::Note\.Echo has no answer path: it returns Heard.*answers_query "Echo"/,
                     hecksagon: without_binding("Echo"))
    end

    it "refuses a query with arguments that select nothing, returns nothing and is bound to no port" do
      expect_refusal(/Lookup::Note\.Echo has no answer path: it declares no where and returns nothing.*\(title\)/,
                     bluebook: echo_with(""), hecksagon: without_binding("Echo"))
    end

    it "refuses a bound query that returns nothing, since its answer would have no shape" do
      expect_refusal(/Lookup::Note\.Echo is bound to the Echoer port but returns nothing/,
                     bluebook: echo_with(""))
    end

    it "refuses a query bound by two ports" do
      twin = OUTSIDE_HECKSAGON.sub(/\nend\n\z/, "\n\n  Lookup::Note.port \"Twin\" do\n    answers_query \"Echo\"\n  end\nend\n")

      expect_refusal(/Lookup::Note\.Echo has two answer paths: the Echoer port and the Twin port/, hecksagon: twin)
    end

    it "merges a port declared twice under one name, as an environment overlay repeats it" do
      again    = %(\n\n  Lookup::Note.port "Echoer" do\n    answers_query "Echo"\n  end\nend\n)
      repeated = OUTSIDE_HECKSAGON.sub(/\nend\n\z/, again)
      runtime  = boot_domain(hecksagon: repeated)

      expect(runtime.registry.bluebook("Lookup").aggregate("Note").ports.map(&:name)).to eq(["Echoer"])
      expect(runtime.query("Lookup::Note.Echo", title: "hello")).to eq([{ heard: { value: "hello" } }])
    end

    it "refuses a query that filters stored records and is bound too" do
      expect_refusal(/Lookup::Note\.Recent has two answer paths: its records and the Echoer port/,
                     hecksagon: OUTSIDE_HECKSAGON.sub(%(answers_query "Sight"),
                                                      %(answers_query "Sight"\n        answers_query "Recent")))
    end

    it "refuses a returning query that also declares a where, since the where could not be used" do
      expect_refusal(/Lookup::Note\.Echo has two answer paths: it is bound to the Echoer port but also declares where/,
                     bluebook: echo_with("where(title: :title)\n      returns Heard"))
    end

    it "refuses a returned value object the aggregate does not declare" do
      expect_refusal(/Lookup::Note\.Echo returns Ghost, but Note declares no such value object/,
                     bluebook: echo_with("returns Ghost"))
    end

    it "refuses a binding that names a query the aggregate does not declare" do
      expect_refusal(/binds Lookup::Note\.Census, which the aggregate does not declare/,
                     hecksagon: OUTSIDE_HECKSAGON.sub('"Roster"', '"Census"'))
    end

    it "refuses a port no adapter implements, naming the port and the query" do
      expect_refusal(/no adapter implements the Nobody port.*Note\.Echo/,
                     hecksagon: OUTSIDE_HECKSAGON.sub('port "Echoer"', 'port "Nobody"'))
    end

    it "refuses a port two adapters implement" do
      twin = { name: "answering_second_echoer", klass: "AnsweringSecondEchoer", body: ECHOER_BODY }

      expect_refusal(/2 adapters implement the Echoer port.*the runtime will not choose for you/, extra: [twin])
    end

    it "refuses an adapter that lacks the method a bound query is asked by" do
      body = ECHOER_BODY.sub(/def roster.*?end\n/m, "")

      expect_refusal(/implements the Echoer port but not #roster, which answers Lookup::Note\.Roster/, body: body)
    end

    it "refuses a query named like a method every object has, which no adapter defined" do
      display   = %(    query "Display" do\n      returns Sighting\n    end\n\n    query "Sight" do)
      bluebook  = OUTSIDE_BLUEBOOK.sub('    query "Sight" do', display)
      hecksagon = OUTSIDE_HECKSAGON.sub(%(answers_query "Sight"), %(answers_query "Sight"\n        answers_query "Display"))

      expect_refusal(/implements the Echoer port but not #display, which answers Lookup::Note\.Display/,
                     bluebook: bluebook, hecksagon: hecksagon)
    end

    it "refuses an adapter method that does not take the query's arguments as keywords" do
      expect_refusal(/#echo answers Lookup::Note\.Echo but does not take title:/,
                     body: ECHOER_BODY.sub("def echo(title:)", "def echo"))
    end

    it "refuses an adapter method that takes a positional argument" do
      expect_refusal(/#echo answers Lookup::Note\.Echo but takes positional arguments/,
                     body: ECHOER_BODY.sub("def echo(title:)", "def echo(title, **)"))
    end

    it "refuses an adapter method that requires a keyword the query does not declare" do
      expect_refusal(/#echo answers Lookup::Note\.Echo but requires token:, which the query does not/,
                     body: ECHOER_BODY.sub("def echo(title:)", "def echo(title:, token:)"))
    end

    it "refuses an adapter whose constructor requires arguments, since it is built with none" do
      write_domain(@dir)
      path = Dir[File.join(@dir, "bluebook", "adapters", "answering_echoer*.rb")].first
      File.write(path, File.read(path).sub("def initialize(aggregate: nil, settings: {}, root: nil)",
                                           "def initialize(token)"))

      expect { Hecks.boot(@dir, install_facade: false) }
        .to raise_error(Hecks::Runtime::WiringError, /constructor requires token/)
    end

    it "refuses a bound query that declares authorize, since an outside answer is never scoped" do
      expect_refusal(/Lookup::Note\.Echo is bound to the Echoer port but declares authorize/,
                     bluebook: echo_with("authorize :readers, tenant: :title\n      returns Heard"))
    end

    it "refuses the old spelling, which took the shape the bluebook now declares" do
      expect { boot_domain(hecksagon: OUTSIDE_HECKSAGON.sub('"Echo"', '"Echo", shape: :row')) }
        .to raise_error(Hecks::Bluebook::DSL::Malformed, /takes only the query's name.*returns/)
    end

    it "refuses an entity's query that returns a value object, since nothing can be bound to it" do
      bluebook = OUTSIDE_BLUEBOOK.sub("    command \"Write\" do", <<~RUBY.chomp)
        entity "Line" do
          attribute :text, Title
          identified_by :text

          query "Spoken" do
            returns Heard
          end
        end

        command "Write" do
      RUBY

      expect_refusal(/Lookup::Note\.Line\.Spoken has no answer path: it returns Heard/, bluebook: bluebook)
    end
  end

  describe "an entity's query with arguments that select nothing" do
    it "is refused at boot, as an aggregate's is" do
      bluebook = OUTSIDE_BLUEBOOK.sub("    command \"Write\" do", <<~RUBY.chomp)
        entity "Line" do
          attribute :text, Title
          identified_by :text

          query "Spoken" do
            attribute :text, Title
          end
        end

        command "Write" do
      RUBY

      expect { boot_domain(bluebook: bluebook) }
        .to raise_error(Hecks::Runtime::WiringError, /Lookup::Note\.Line\.Spoken has no answer path.*\(text\)/)
    end
  end

  describe "a query answered from the aggregate's records" do
    it "keeps a query with no arguments, no clause and no return as the plain list of records" do
      runtime = boot_domain

      expect(runtime.query("Lookup::Note.Everything")).to eq([])
      runtime.dispatch("Lookup::Note.Write", with: { title: { value: "kept" } })
      expect(runtime.query("Lookup::Note.Everything").map { |row| row[:title].to_h }).to eq([{ value: "kept" }])
    end

    it "still filters stored records for a query with a where" do
      runtime = boot_domain
      runtime.dispatch("Lookup::Note.Write", with: { title: { value: "x" } })
      runtime.dispatch("Lookup::Note.Write", with: { title: { value: "y" } })

      expect(runtime.query("Lookup::Note.Recent").map { |row| row[:title].to_h }).to eq([{ value: "x" }])
    end
  end

  describe "model_check" do
    it "refuses the outside-answered queries of a domain with a Rust target, which the Rust host cannot serve" do
      bluebook = boot_domain.registry.bluebook("Lookup")

      findings = Hecks::Bluebook::ModelCheck.call(bluebook, rust_target: true).select { |f| f.kind == :external_query }

      expect(findings.map(&:subject)).to eq(%w[Note.Echo Note.Roster Note.Sight])
      expect(findings.map(&:severity).uniq).to eq([:error])
      expect(Hecks::Bluebook::ModelCheck.call(bluebook).map(&:kind)).not_to include(:external_query)
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

        def roster = []

        def sight = { seen: "nothing", taken_at: "then" }
      RUBY
      File.write(File.join(fake, "lookup.behaviors"), <<~RUBY)
        Hecks.behaviors "Lookup" do
          vision "The lookup, heard from a fake."

          loads "anchor.hecksagon", "../bluebook/lookup.bluebook", "../bluebook/lookup.hecksagon"

          test "Echo answers what the fake heard" do
            tests "Echo", on: "Note", kind: :query
            input title: { value: "hi" }
            expect heard: { value: "fake" }
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

  describe "the Rust parser", :io do
    PARSER_DIR    = File.expand_path("../rust/parser", __dir__)
    PARSER_BINARY = File.join(PARSER_DIR, "target", "debug", "hecks-parse")

    it "emits the same IR for returns as the Ruby exporter, byte for byte" do
      built = system("cargo", "build", chdir: PARSER_DIR, out: File::NULL, err: File::NULL)
      raise "cargo build failed in rust/parser" unless built

      path = File.join(@dir, "lookup.bluebook")
      File.write(path, OUTSIDE_BLUEBOOK)
      stdout, stderr, status = Open3.capture3(PARSER_BINARY, "chapter", "--chapter", "Lookup", path)
      expect(status.exitstatus).to eq(0), stderr

      registry = Hecks::Runtime::Registry.new(root: @dir)
      Hecks.with_registry(registry) do
        Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
        Kernel.load(InMemoryDomain::EXTRACTION_PORT)
        Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
        Kernel.load(InMemoryDomain::PRISM_ADAPTER)
        InMemoryDomain.load_bluebook_files([path])
      end
      expected = "#{JSON.pretty_generate(Hecks::Projector::Exporter.call(registry).fetch('Lookup'))}\n"

      expect(stdout).to eq(expected)
      expect(stdout).to include('"returns": "list_of(Listing)"')
    end
  end
end
