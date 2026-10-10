require "spec_helper"
require "tmpdir"
require "fileutils"
require "json"
require "socket"
require "securerandom"

# ADR 0080, section 7: every row of the command table resolves in the launcher. Each verb of
# Custodian's Introspection, Operation, Host, Era, Package and Launch (and the ModelCheck the table
# puts beside them) answers
# `--help`, and the journaled ones are then run the way `hecks <verb>` runs them.
RSpec.describe "the Hecks command table through the launcher" do
  # Introspection's queries and the verbs of ModelCheckRun and Operation, as the launcher spells
  # them.
  COMMAND_LAUNCHER_NAMES = { "operation.open_console" => "console", "launch.serve_mcp" => "mcp" }.freeze

  # Settled verbs of the attached Deploy chapter; hecks_deploy_smoke_run_spec.rb and
  # hecks_deploy_roll_spec.rb and the data copy, diff, preview and companion specs run them.
  DEPLOY_CHAPTER_VERBS = %w[smoke_run.run service_roll.run box_roll.run data_copy.restore
                            data_copy.verify bluebook_diff.run preview_run.name preview_run.url
                            preview_run.list preview_run.deploy preview_run.destroy preview_run.login
                            companion_roll.run handover.clear].freeze

  CUSTODIAN_VERBS = %w[
    introspection.ir introspection.shape introspection.stores introspection.history
    introspection.statements introspection.narrate introspection.docs introspection.project_diagrams
    introspection.glossary model_check_run.model_check model_check_run.verdict model_check_run.flagged
    operation.run operation.refresh_projections operation.run_behaviors operation.open_console
    operation.smoke_test operation.smoke_http operation.outcome operation.failed
    operation.follow host.check_era host.recheck host.standing
    host.drifted era.hold_first era.merge_tail era.reattest
    era.backfill_projections era.compact era.compact_heki era.approve_translation
    era.settlement era.abandoned era.scaffold_translation era.audit_translation
    era.attestation era.compaction package.vendor package.revendor
    package.pinning package.unpinned package.verify package.digest package.check package.release
    operation.bootstrap_admin launch.project_cli launch.serve_mcp
    launch.ended launch.stopped build.project_rust build.build_wasm
    build.build_host build.build_browser_wasm build.check_conformance build.fuzz_conformance build.check_coverage_allowlist
    build.rust_coverage build.result build.faulted fuzz_run.fuzz
    fuzz_run.bench fuzz_run.conclusion fuzz_run.halted fuzz_run.generate_sequence
  ].freeze

  SHELF_BLUEBOOK = <<~RUBY.freeze
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

  SHELF_HECKSAGON = <<~RUBY.freeze
    Hecks.hecksagon "Shelf" do
      persisted_by "Memory"
    end
  RUBY

  SHELF_BEHAVIORS = <<~RUBY.freeze
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

  # The same shelf without the lifecycle whose transition names a command nobody declared.
  CLEAN_BLUEBOOK = SHELF_BLUEBOOK.sub(/    lifecycle.*?    end\n\n/m, "").freeze

  before(:all) do
    @dir = Dir.mktmpdir("command_table")
    @shelf = File.join(@dir, "shelf")
    write("shelf/bluebook/shelf.bluebook", SHELF_BLUEBOOK)
    write("shelf/bluebook/shelf.hecksagon", SHELF_HECKSAGON)
    write("shelf/bluebook/shelf.behaviors", SHELF_BEHAVIORS)
    write("clean/bluebook/clean.bluebook", CLEAN_BLUEBOOK.sub('"Shelf"', '"Clean"'))
    write("eras.txt", "abc123\n")
    write("clean/bluebook/clean.hecksagon", SHELF_HECKSAGON.sub('"Shelf"', '"Clean"'))
    @hecks = Hecks.boot(File.join(InMemoryDomain::ROOT, "lib/hecks/hecks"), install_driving: false)
  end

  after(:all) { FileUtils.rm_rf(@dir) }

  def write(path, text)
    full = File.join(@dir, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, text)
  end

  def run_verb(*argv)
    Hecks::Adapters::Driving::CliRunner.call(runtime: @hecks, argv: argv, program: "hecks")
  end

  def verdict_of(run)
    JSON.parse(run_verb("model_check_run.verdict", run).first).first
  end

  def outcome_of(run)
    JSON.parse(run_verb("operation.outcome", run).first).first
  end

  # A row's status beside the text of its `field`.
  def status_and(row, field)
    [row.fetch("status"), row.dig(field, "value")]
  end

  # The names a listing query answers, read from each row's `key` field.
  def listed(query, key)
    JSON.parse(run_verb(query).first).map { |row| row.dig(key, "value") }
  end

  def journal_size
    @hecks.registry.event_log.to_a.size
  end

  Ran = Struct.new(:out, :status, :journaled)

  # Runs a verb and answers what it printed, its status and how many journal entries it wrote.
  def run_counting_journal(*argv)
    before = journal_size
    out, status = run_verb(*argv)
    Ran.new(out, status, journal_size - before)
  end

  CUSTODIAN_VERBS.each do |verb|
    it "answers `hecks #{verb} --help`", :aggregate_failures do
      out, status = run_verb(verb, "--help")

      expect(status).to eq(0)
      expect(out).to start_with(COMMAND_LAUNCHER_NAMES.fetch(verb, verb))
    end
  end

  describe "model_check" do
    it "keeps a clean verdict beside the request", :aggregate_failures do
      out, status = run_verb("model_check_run.model_check", "run=clean-1", "domains=#{File.join(@dir, "clean")}")

      expect([status, JSON.parse(out).fetch("events")]).to eq([0, ["ModelCheckRequested"]])
      row = verdict_of("clean-1")
      expect(row.fetch("status")).to eq("clean")
      expect(row.dig("report", "value")).to include("no dead states")
    end

    it "flags a domain whose model has a finding, and keeps what was found", :aggregate_failures do
      run_verb("model_check_run.model_check", "run=shelf-1", "domains=#{@shelf}")

      row = verdict_of("shelf-1")
      expect(row.fetch("status")).to eq("flagged")
      expect(row.dig("refusal", "value")).to include("Lend")
      expect(listed("model_check_run.flagged", "run")).to include("shelf-1")
    end

    it "flags a domain that does not exist instead of calling it clean" do
      run_verb("model_check_run.model_check", "run=none-1", "domains=#{File.join(@dir, "nowhere")}")

      expect(verdict_of("none-1").fetch("status")).to eq("flagged")
    end

    it "refuses a profile it does not know, before anything is recorded", :aggregate_failures do
      out, status = run_verb("model_check_run.model_check", "run=bad-1", "profile=strictest")

      expect(status).to eq(1)
      expect(out).to include("must match")
      expect(run_verb("model_check_run.verdict", "bad-1").first).not_to include("bad-1")
    end
  end

  describe "the Operation verbs" do
    # The sessions the Terminal adapter was asked to launch while `operation.open_console` ran.
    def open_console_sessions(run)
      launched = []
      Hecks::Adapters::Terminal.launcher = -> { launched << :irb }
      begin
        capture_stdout { run_verb("operation.open_console", "run=#{run}", "subject=#{@shelf}") }
      ensure
        Hecks::Adapters::Terminal.launcher = nil
      end
      launched
    end

    it "refresh_projections catches up and keeps how many", :aggregate_failures do
      run_verb("operation.refresh_projections", "run=refresh-1", "subject=#{@shelf}")

      row = outcome_of("refresh-1")
      expect(row.fetch("status")).to eq("succeeded")
      expect(row.dig("output", "value")).to eq("refreshed 0 projection(s)")
    end

    it "run_behaviors keeps the per-test report", :aggregate_failures do
      run_verb("operation.run_behaviors", "run=behave-1", "subject=#{File.join(@shelf, "bluebook/shelf.behaviors")}")

      row = outcome_of("behave-1")
      expect(row.fetch("status")).to eq("succeeded")
      expect(row.dig("output", "value")).to include("Shelve records a book")
    end

    it "run dispatches a verb against the domain", :aggregate_failures do
      run_verb("operation.run", "run=verb-1", "subject=#{@shelf}", "verb=book.shelve", "arguments=title.value=Dune")

      row = outcome_of("verb-1")
      expect(row.fetch("status")).to eq("succeeded")
      expect(row.dig("output", "value")).to include("Dune")
    end

    it "run keeps a refusal as a failed operation, with the domain's own sentence", :aggregate_failures do
      run_verb("operation.run", "run=verb-2", "subject=#{@shelf}", "verb=book.shelve")

      row = outcome_of("verb-2")
      expect(row.fetch("status")).to eq("failed")
      expect(row.dig("refusal", "value")).to include("title")
      expect(listed("operation.failed", "run")).to include("verb-2")
    end

    it "run refuses a request that names neither a script nor a verb, and records nothing", :aggregate_failures do
      out, status = run_verb("operation.run", "run=neither-1", "subject=#{@shelf}")

      expect(status).to eq(1)
      expect(out).to include("exactly one of a script and a verb is named")
      expect(run_verb("operation.outcome", "neither-1").first).not_to include("neither-1")
    end

    it "run refuses a request that names both a script and a verb, and records nothing", :aggregate_failures do
      out, status = run_verb("operation.run", "run=both-1", "subject=#{@shelf}", "script=steps.json", "verb=book.shelve")

      expect(status).to eq(1)
      expect(out).to include("exactly one of a script and a verb is named")
      expect(run_verb("operation.outcome", "both-1").first).not_to include("both-1")
    end

    it "run accepts a script alone, and keeps its failure as the operation's", :aggregate_failures do
      run_verb("operation.run", "run=script-1", "subject=#{@shelf}", "script=#{File.join(@dir, "no-such-steps.json")}")

      row = outcome_of("script-1")
      expect(row.fetch("status")).to eq("failed")
      expect(row.dig("script", "value")).to end_with("no-such-steps.json")
    end

    it "smoke_test dispatches one call per command", :aggregate_failures do
      run_verb("operation.smoke_test", "run=smoke-1", "subject=#{File.join(@dir, "clean")}")

      row = outcome_of("smoke-1")
      expect(row.fetch("status")).to eq("succeeded")
      expect(row.dig("output", "value")).to include("dispatched cleanly")
    end

    it "smoke_http fails without a signing secret in the environment, and never takes one as an argument", :aggregate_failures do
      run_verb("operation.smoke_http", "run=hook-1", "path=/webhooks/events")

      row = outcome_of("hook-1")
      expect(row.fetch("status")).to eq("failed")
      expect(row.dig("refusal", "value")).to include("SMOKE_WEBHOOK_SECRET")
      expect(run_verb("operation.smoke_http", "--help").first).not_to include("secret")
    end

    it "open_console launches its session through the Terminal adapter and keeps that it ended", :aggregate_failures do
      launched = open_console_sessions("console-1")

      expect(launched).to eq([:irb])
      expect(outcome_of("console-1").dig("output", "value")).to include("console session ended")
    end
  end

  describe "follow" do
    it "answers a cursor and the entries past it, and writes no journal entry of its own", :aggregate_failures do
      ran = run_counting_journal("operation.follow", @shelf)

      expect([ran.status, ran.journaled]).to eq([0, 0])
      row = JSON.parse(ran.out).first
      expect(row).to include("cursor" => 0, "events" => [], "taken_at" => match(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\z/))
    end

    describe "--stream" do
      def tail_row(cursor, *events)
        entries = events.map do |name|
          { name: name, aggregate: "Shelf::Book", id: "b1", payload: "{\"title\":\"Dune\"}",
            occurred_at: "2026-10-01T00:00:00Z" }
        end
        [{ cursor: cursor, taken_at: "2026-10-01T00:00:00Z", events: entries }]
      end

      StreamRun = Struct.new(:status, :lines, :asked) do
        # Each question's `since` cursor and whether it carried `from_now`.
        def asks
          asked.map { |args| [args.dig(:since, :value), args.key?(:from_now)] }
        end
      end

      # Streams `operation.follow` against three canned answers and keeps what was asked of the
      # query and what was printed.
      def stream_follow
        asked = []
        answers = [tail_row(2, "Shelved", "Borrowed"), tail_row(2), tail_row(3, "Returned")]
        allow(@hecks).to receive(:query) do |_verb, **args|
          asked << args
          answers.shift
        end
        out = StringIO.new
        argv = ["operation.follow", @shelf, "from_now=true", "--stream"]
        status = Hecks::Adapters::Driving::CliRunner.stream(runtime: @hecks, argv: argv, program: "hecks", out: out, max_polls: 3)
        StreamRun.new(status, out.string.lines.map { |line| JSON.parse(line) }, asked)
      end

      let(:stream) { stream_follow }

      it "asks again from the cursor each answer gives and prints every entry as one line", :aggregate_failures do
        expect(stream.status).to eq(0)
        expect(stream.lines.map { |line| line["name"] }).to eq(%w[Shelved Borrowed Returned])
        expect(stream.lines.first["payload"]).to eq("title" => "Dune")
        expect(stream.asks).to eq([[nil, true], [2, false], [2, false]])
        expect(stream.asked).to all(include(wait: { value: 30 }))
      end

      it "is not a stream without --stream, or for a question the world does not list", :aggregate_failures do
        expect(Hecks::Adapters::Driving::CliRunner.stream(runtime: @hecks, argv: ["operation.follow", @shelf],
                                                          program: "hecks")).to be_nil
        expect(Hecks::Adapters::Driving::CliRunner.stream(runtime: @hecks, argv: ["model_check_run.verdict", "x", "--stream"],
                                                          program: "hecks")).to be_nil
      end

      it "ends with status 0 when the reader interrupts" do
        allow(@hecks).to receive(:query).and_raise(Interrupt)

        stream = Hecks::Adapters::Driving::CliRunner.stream(runtime: @hecks, argv: ["operation.follow", @shelf, "--stream"],
                                                            program: "hecks", out: StringIO.new)
        expect(stream).to eq(0)
      end
    end

    it "words a domain that is not there as a refusal", :aggregate_failures do
      out, status = run_verb("operation.follow", File.join(@dir, "nowhere"))

      expect(status).to eq(1)
      expect(out).to include("no such domain")
    end
  end

  describe "the Host verbs" do
    it "check_era keeps a host that cannot be reached as unreachable, with the reason", :aggregate_failures do
      run_verb("host.check_era", "http://127.0.0.1:1", "expected=#{File.join(@dir, "eras.txt")}")

      row = standing_of("http://127.0.0.1:1")
      expect(row.fetch("status")).to eq("unreachable")
      expect(row.dig("refusal", "value")).to include("could not be reached")
    end

    context "when the host answers an era", :io do
      let(:server) { TCPServer.new("127.0.0.1", 0) }
      let(:url) { "http://127.0.0.1:#{server.addr[1]}" }

      before do
        @thread = Thread.new do
          loop do
            client = server.accept
            while (line = client.gets) && line != "\r\n"; end
            body = JSON.generate(era: "abc123", version: "3.0.0")
            client.write("HTTP/1.1 200 OK\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
            client.close
          end
        end
      end

      after do
        @thread&.kill
        server.close
      end

      # Writes the expected era to `file`, asks `verb` about the host against it and answers the standing.
      def era_check(verb, file, era)
        write(file, "#{era}\n")
        run_verb(verb, url, "expected=#{File.join(@dir, file)}")
        standing_of(url)
      end

      it "keeps the era a host reports, flags a drift, and rechecks the same host", :aggregate_failures do
        row = era_check("host.check_era", "eras-ok.txt", "abc123")
        expect([row.fetch("status"), row.dig("era", "value"), row.dig("version", "value")]).to eq(%w[observed abc123 3.0.0])

        drifted = era_check("host.recheck", "eras-old.txt", "def456")
        expect(drifted.fetch("status")).to eq("drifted")
        expect(listed("host.drifted", "host")).to include(url)
      end
    end

    it "refuses a second check of a host that is already recorded", :aggregate_failures do
      run_verb("host.check_era", "http://127.0.0.1:2", "expected=#{File.join(@dir, "eras.txt")}")
      out, status = run_verb("host.check_era", "http://127.0.0.1:2", "expected=#{File.join(@dir, "eras.txt")}")

      expect(status).to eq(1)
      expect(out).to include("already exists")
    end
  end

  describe "the Era verbs" do
    HEKI_FIXTURE = File.join(InMemoryDomain::ROOT, "spec/fixtures/heki_compact_fixture/bluebook").freeze
    BANKING_EXAMPLE = File.join(InMemoryDomain::ROOT, "examples/banking/bluebook").freeze

    # Seeding and compaction write the journal under the shared data directory; each example starts clean.
    after { FileUtils.rm_rf(File.join(@dir, "data")) }

    COMPACTED = "COMPACTED gadget: discarded 3 journal entries".freeze
    UNREAD_JOURNAL_REFUSAL = {
      "policy" => "PermitWhenExamined",
      "reason" => "Permit refused — no projection reads the journal that would be emptied"
    }.freeze

    def settlement_of(run)
      JSON.parse(run_verb("era.settlement", run).first).first
    end

    def banking_copy
      target = File.join(@dir, "banking")
      FileUtils.cp_r(BANKING_EXAMPLE, target)
      target
    end

    def seeded_heki(name)
      target = File.join(@dir, name)
      FileUtils.cp_r(HEKI_FIXTURE, target)
      runtime = Hecks.boot(target, install_driving: false)
      aggregate = runtime.registry.bluebook("HekiCompactFixture").aggregate("Gadget")
      repository = runtime.registry.repository("HekiCompactFixture", aggregate)
      3.times { |i| repository.save(gadget_labelled(aggregate, i)) }
      target
    end

    def gadget_labelled(aggregate, number)
      built = Hecks::Runtime::Instance.new(aggregate: aggregate, id: "g1")
      built[:name] = Hecks::Runtime::Value.for(aggregate, :name, { value: "g1" })
      built[:label] = Hecks::Runtime::Value.for(aggregate, :label, { value: "label#{number}" })
      built
    end

    # What `verb` answers when asked for a change without `--confirm`, and whether it was recorded.
    def unconfirmed_attempt(verb)
      run = "unconfirmed-#{verb.split(".").last}"
      out, status = run_verb(verb, @shelf, "run=#{run}")
      { status: status, out: out, recorded: run_verb("era.settlement", run).first.include?("unconfirmed") }
    end

    it "refuses every change that changes something until it is confirmed, and records nothing", :aggregate_failures do
      %w[era.hold_first era.merge_tail era.compact era.compact_heki era.approve_translation].each do |verb|
        expect(unconfirmed_attempt(verb)).to include(status: 1, out: include("is confirmed"), recorded: false)
      end
      expect(run_verb("era.reattest", @shelf, "era=1", "run=unconfirmed-reattest").last).to eq(1)
    end

    describe "reattest, once the journal store has examined the era's text" do
      SHAPE_CHANGED = "Permit refused — the edit kept the era's shape, not just its text: " \
                      "restore a text with the original shape".freeze

      # The JournalStore adapter stands in for a Postgres journal: it reports the facts an
      # examination of a held text finds, and counts the changes it is asked to make.
      def examined_as(**found)
        facts = Hecks::Adapters::JournalStore::Examination::NEUTRAL.merge(capable: true, operation: "reattest", **found)
        @applied = 0
        counter = -> { @applied += 1 }
        store = Object.new
        store.define_singleton_method(:examine) { |**| facts.transform_values { |fact| { value: fact } } }
        store.define_singleton_method(:apply) do |**|
          counter.call
          { report: { value: "ATTESTED: era 1 re-frozen" } }
        end
        allow(Hecks::Adapters::JournalStore).to receive(:new).and_return(store)
      end

      def reattest(run)
        out, = run_verb("era.reattest", @shelf, "era=1", "run=#{run}", "--confirm")
        JSON.parse(out).fetch("refused_reactions", []).map { |reaction| reaction.fetch("reason") }
      end

      it "attests a text that drifted from its digest, loads, and kept the era's shape", :aggregate_failures do
        examined_as(drifted: true, loadable: true, shape_kept: true)

        expect(reattest("attest-1")).to be_empty
        expect(settlement_of("attest-1").fetch("status")).to eq("settled")
        expect(@applied).to eq(1)
      end

      it "refuses a text that still matches its digest: there is nothing to re-attest", :aggregate_failures do
        examined_as

        expect(reattest("attest-2"))
          .to eq(["Permit refused — the held text no longer matches its digest: there is nothing to re-attest"])
        expect([settlement_of("attest-2").fetch("status"), @applied]).to eq(["refused", 0])
        expect(listed("era.abandoned", "run")).to include("attest-2")
      end

      it "refuses an edited text that does not load as a bluebook", :aggregate_failures do
        examined_as(drifted: true, loadable: false, shape_kept: false)

        expect(reattest("attest-3"))
          .to eq(["Permit refused — the edited text loads as a bluebook: restore a loadable text"])
        expect(@applied).to eq(0)
      end

      it "refuses an edit that changed the era's shape, whatever was confirmed", :aggregate_failures do
        examined_as(drifted: true, loadable: true, shape_kept: false)

        expect(reattest("attest-4")).to eq([SHAPE_CHANGED])
        expect(@applied).to eq(0)
      end
    end

    it "previews a compaction before anything is confirmed" do
      target = seeded_heki("heki-preview")

      expect(run_verb("era.compaction", target).first).to include("DRY RUN gadget: would discard 3 journal entries")
    end

    it "compacts once confirmed, and keeps what was done", :aggregate_failures do
      out, status = run_verb("era.compact_heki", seeded_heki("heki-compact"), "run=compact-1", "--confirm")

      expect([status, JSON.parse(out).fetch("events")]).to eq([0, ["HekiCompactionRequested"]])
      row = settlement_of("compact-1")
      expect([row.fetch("status"), row.dig("report", "value")]).to match(["settled", a_string_including(COMPACTED)])
      expect(File.size(File.join(@dir, "data", "gadget.heki.journal"))).to eq(0)
    end

    it "does not compact a journal a projection reads, and says why beside the request", :aggregate_failures do
      out, status = run_verb("era.compact_heki", banking_copy, "run=compact-2", "--confirm")

      expect(status).to eq(0)
      expect(JSON.parse(out).fetch("refused_reactions").first).to include(UNREAD_JOURNAL_REFUSAL)
      expect(settlement_of("compact-2").fetch("status")).to eq("refused")
      expect(listed("era.abandoned", "run")).to include("compact-2")
    end

    context "when `apply` is asked for a run its gate refused" do
      let(:journal) { File.join(@dir, "data", "gadget.heki.journal") }

      before do
        none = Hecks::Adapters::JournalStore::Examination::NEUTRAL.merge(operation: "compact_heki")
        found = none.transform_values { |fact| { value: fact } }
        allow(Hecks::Adapters::JournalStore).to receive(:new).and_wrap_original do |original, *args, **kwargs|
          original.call(*args, **kwargs).tap { |store| allow(store).to receive(:examine).and_return(found) }
        end
        run_verb("era.compact_heki", seeded_heki("heki-apply-#{SecureRandom.hex(3)}"), "run=apply-1", "--confirm")
        @size = File.size(journal)
      end

      it "has refused the change in the first place" do
        expect(settlement_of("apply-1").fetch("status")).to eq("refused")
      end

      it "does not make the change anyway", :aggregate_failures do
        run_verb("era.apply", "to=apply-1", "run=apply-1")

        expect(@size).to be_positive
        expect(File.size(journal)).to eq(@size)
        expect(settlement_of("apply-1").fetch("status")).to eq("refused")
      end
    end

    it "keeps a domain that is not there as a refused change, with the reason", :aggregate_failures do
      run_verb("era.compact", File.join(@dir, "nowhere"), "run=compact-3", "--confirm")

      row = settlement_of("compact-3")
      expect(row.fetch("status")).to eq("refused")
      expect(row.dig("refusal", "value")).to include("no such domain")
      expect(listed("era.abandoned", "run")).to include("compact-3")
    end

    it "words a domain that holds no era as an answer, and never holds one to answer", :aggregate_failures do
      out, status = run_verb("era.audit_translation", @shelf)

      expect(status).to eq(1)
      expect(out).to include("Shelf is bound to Memory, which holds no eras")
    end

    it "takes winners as id:old,id:new and refuses a malformed list", :aggregate_failures do
      out, status = run_verb("era.merge_tail", @shelf, "run=merge-1", "winners=a1", "--confirm")

      expect(status).to eq(1)
      expect(out).to include("must match")
    end
  end

  describe "operation.bootstrap_admin", :io do
    require_relative "support/crew_domain"

    let(:id)   { SecureRandom.hex(4) }
    let(:crew) { CrewDomain.write(File.join(@dir, "crew-#{id}"), sqlite: File.join(@dir, "crew-#{id}.sqlite3")) }

    it "admits and grants the first administrator", :aggregate_failures do
      out, status = run_verb("operation.bootstrap_admin", crew, "email=ada@example.com", "name=Ada")

      expect(status).to eq(0)
      expect(JSON.parse(out).dig("state", "output", "value")).to eq("Granted Admin access to ada@example.com (admitted first)")
    end

    it "exits 1 for a second", :aggregate_failures do
      run_verb("operation.bootstrap_admin", crew, "email=ada@example.com", "name=Ada")

      _out, status, reason = run_verb("operation.bootstrap_admin", crew, "email=grace@example.com")

      expect(status).to eq(1)
      expect(reason).to include("an administrator already exists (ada@example.com)")
    end

    it "exits 1 for a domain that provides no membership", :aggregate_failures do
      _out, status, reason = run_verb("operation.bootstrap_admin", File.join(@dir, "clean"), "email=ada@example.com")

      expect(status).to eq(1)
      expect(reason).to include("provides \"membership\"")
    end

    it "exits 1 for an email that is not one, before booting anything", :aggregate_failures do
      out, status = run_verb("operation.bootstrap_admin", crew, "email=ada")

      expect(status).to eq(1)
      expect(out).to include("must match")
    end
  end

  describe "the Package verbs" do
    let(:registry) { widgets_registry(File.join(@dir, "registry-#{SecureRandom.hex(4)}")) }
    let(:project) { File.join(@dir, "project-#{File.basename(registry.path)}") }

    def pinning_of(package)
      JSON.parse(run_verb("package.pinning", package).first).first
    end

    it "vendor keeps a source that is not there as a refused pinning, and unpinned lists it", :aggregate_failures do
      run_verb("package.vendor", "payments@1.2.0", "from=#{File.join(@dir, "nowhere")}", "root=#{@dir}")

      row = pinning_of("payments@1.2.0")
      expect(row.fetch("status")).to eq("refused")
      expect(row.dig("refusal", "value")).to include("no source repository")
      expect(listed("package.unpinned", "package")).to include("payments@1.2.0")
    end

    # A registry holding widgets 1.0.0, committed and tagged the way a release is.
    def widgets_registry(path)
      require_relative "support/registry_repo"
      registry = RegistryRepo.new(path)
      registry.write("widgets/bluebook.yml"              => "name: widgets\nversion: 1.0.0\nsummary: Widgets.\n",
                     "widgets/bluebook/widgets.bluebook" => RegistryRepo.widgets_bluebook)
      registry.commit("widgets 1.0.0")
      registry.tag("widgets-v1.0.0")
      registry
    end

    def vendor_widgets(verb)
      run_verb(verb, "widgets", "from=#{registry.path}", "root=#{project}")
    end

    it "vendors a release from a registry, and revendors the same spelling", :aggregate_failures, :io do
      vendor_widgets("package.vendor")
      expect(status_and(pinning_of("widgets"), "report")).to match(["vendored", a_string_including("widgets 1.0.0")])
      expect(File.exist?(File.join(project, "vendor/embryonaut_bluebooks/widgets/bluebook.lock"))).to be(true)

      vendor_widgets("package.revendor")
      expect(pinning_of("widgets").fetch("status")).to eq("vendored")
    end

    describe "package.verify", :io do
      require_relative "support/registry_repo"

      let(:scratch)  { Dir.mktmpdir("verify-status") }
      let(:registry) { RegistryRepo.new(File.join(scratch, "registry")) }
      let(:project)  { File.join(scratch, "project") }
      let(:bluebook) { File.join(project, "vendor/embryonaut_bluebooks/widgets/bluebook/widgets.bluebook") }

      before do
        registry.write("widgets/bluebook.yml"              => "name: widgets\nversion: 1.0.0\nsummary: Widgets.\n",
                       "widgets/bluebook/widgets.bluebook" => RegistryRepo.widgets_bluebook)
        registry.commit("widgets 1.0.0")
        registry.tag("widgets-v1.0.0")
        Hecks::EmbryonautBluebook.vendor!("widgets", from: registry.path, root: project)
      end

      after { FileUtils.rm_rf(scratch) }

      it "prints the manifest as JSON and exits 0 when every package matches its lock", :aggregate_failures do
        out, status = run_verb("package.verify", "root=#{project}")

        expect(status).to eq(0)
        expect(JSON.parse(out).dig("bluebooks", "widgets", "version")).to eq("1.0.0")
      end

      it "exits 1 naming the package whose files were edited", :aggregate_failures do
        File.write(bluebook, "# edited\n", mode: "a")

        out, status = run_verb("package.verify", "root=#{project}")

        expect(status).to eq(1)
        expect(out).to include("FAIL widgets: vendored files hash to")
      end
    end

    describe "package.check and package.release", :io do
      require_relative "support/registry_repo"

      let(:scratch)  { Dir.mktmpdir("registry-verbs") }
      let(:registry) { RegistryRepo.new(File.join(scratch, "registry")) }

      def publish(version, description: "A widget.")
        registry.write("widgets/bluebook.yml"              => "name: widgets\nversion: #{version}\nsummary: Widgets.\n",
                       "widgets/CHANGELOG.md"              => "## #{version}\n\nChanged.\n",
                       "widgets/bluebook/widgets.bluebook" => RegistryRepo.widgets_bluebook(description: description))
        registry.commit("widgets #{version}")
      end

      before do
        registry.git("config", "user.name", "Spec")
        registry.git("config", "user.email", "spec@example.com")
      end

      after { FileUtils.rm_rf(scratch) }

      def publish_tagged(version)
        publish(version)
        registry.tag("widgets-v#{version}")
      end

      it "check answers versions ok", :aggregate_failures do
        publish_tagged("1.0.0")

        out, status = run_verb("package.check", "root=#{registry.path}")

        expect(status).to eq(0)
        expect(out).to eq("versions ok")
      end

      it "check exits 1 naming a changed package that was not bumped", :aggregate_failures do
        publish_tagged("1.0.0")
        publish("1.0.0", description: "Reworded.")

        out, status = run_verb("package.check", "root=#{registry.path}")

        expect(status).to eq(1)
        expect(out).to include("FAIL widgets: bluebook files changed since widgets-v1.0.0")
      end

      it "release tags the version locally, keeps the record, and exits 0", :aggregate_failures do
        publish("1.0.0")

        out, status = run_verb("package.release", "widgets", "root=#{registry.path}")

        expect(status).to eq(0)
        expect(JSON.parse(out).dig("state", "report", "value")).to include("git push origin widgets-v1.0.0")
        expect(registry.git("tag", "--list")).to eq("widgets-v1.0.0\n")
      end

      it "release exits 1 with the reason when a rule is broken, and makes no tag", :aggregate_failures do
        publish_tagged("1.0.0")

        _out, status, reason = run_verb("package.release", "widgets", "root=#{registry.path}")

        expect(status).to eq(1)
        expect(reason).to include("widgets-v1.0.0 already exists")
        expect(registry.git("tag", "--list")).to eq("widgets-v1.0.0\n")
      end

      it "release lists the refused run among registry.refused" do
        publish("1.0.0")
        registry.tag("widgets-v1.0.0")
        run_verb("package.release", "widgets", "root=#{registry.path}", "run=refused-#{rand(1_000_000)}")

        expect(JSON.parse(run_verb("registry.refused").first)).not_to be_empty
      end
    end

    describe "package.digest", :io do
      require_relative "support/registry_repo"

      let(:scratch)  { Dir.mktmpdir("digest-verb") }
      let(:registry) { RegistryRepo.new(File.join(scratch, "registry")) }
      let(:project)  { File.join(scratch, "project") }
      let(:lock)     { Hecks::EmbryonautBluebook::Lock.read(File.join(project, "vendor/embryonaut_bluebooks/widgets/bluebook.lock")) }

      before do
        registry.write("widgets/bluebook.yml"              => "name: widgets\nversion: 1.0.0\nsummary: Widgets.\n",
                       "widgets/CHANGELOG.md"              => "## 1.0.0\n\nFirst.\n",
                       "widgets/bluebook/widgets.bluebook" => RegistryRepo.widgets_bluebook)
        registry.commit("widgets 1.0.0")
        registry.tag("widgets-v1.0.0")
        Hecks::EmbryonautBluebook.vendor!("widgets", from: registry.path, root: project)
      end

      after { FileUtils.rm_rf(scratch) }

      it "prints the digest and shape label the package's lock records, from a registry or a project", :aggregate_failures do
        [registry.path, project].each do |root|
          out, status = run_verb("package.digest", "widgets", "root=#{root}")

          expect(status).to eq(0)
          expect(out).to eq("digest: #{lock.digest}\n#{lock.shape.map { |label| "shape: #{label}\n" }.join}")
        end
      end

      it "digests the bluebook files alone, not the other files of the package" do
        before_text, = run_verb("package.digest", "widgets", "root=#{registry.path}")
        File.write(File.join(registry.path, "widgets/bluebook/notes.md"), "not part of the digest\n")
        File.write(File.join(registry.path, "widgets/CHANGELOG.md"), "## 1.0.0\n\nEdited.\n")

        after_text, = run_verb("package.digest", "widgets", "root=#{registry.path}")

        expect(after_text).to eq(before_text)
      end

      it "exits 1 naming where it looked when the package is not there", :aggregate_failures do
        out, status = run_verb("package.digest", "gadgets", "root=#{registry.path}")

        expect(status).to eq(1)
        expect(out).to include("gadgets has no bluebook/ directory")
      end
    end

    describe "its exit status", :io do
      require_relative "support/registry_repo"

      # A package spelling names one journaled record, and a shared journal keeps it between
      # examples and runs, so each example vendors a release number of its own.
      let(:major)    { rand(1000..999_999) }
      let(:scratch)  { Dir.mktmpdir("vendor-status") }
      let(:registry) { RegistryRepo.new(File.join(scratch, "registry")) }
      let(:project)  { File.join(scratch, "project") }

      after { FileUtils.rm_rf(scratch) }

      def release(version, **bluebook)
        registry.write("widgets/bluebook.yml"              => "name: widgets\nversion: #{version}\nsummary: Widgets.\n",
                       "widgets/bluebook/widgets.bluebook" => RegistryRepo.widgets_bluebook(**bluebook))
        registry.commit("widgets #{version}")
        registry.tag("widgets-v#{version}")
      end

      def vendor(package, *flags)
        run_verb("package.vendor", package, "from=#{registry.path}", "root=#{project}", *flags)
      end

      def revendor(package, *flags)
        run_verb("package.revendor", package, "from=#{registry.path}", "root=#{project}", *flags)
      end

      it "is 0 when the package was pinned" do
        release("#{major}.0.0")

        expect(vendor("widgets@#{major}.0.0").drop(1).first).to eq(0)
      end

      # Releases `first` then `second` (with `bluebook` options) and vendors the `vendored` one.
      def release_then_vendor(first, second, vendored, **bluebook)
        release(first)
        release(second, **bluebook)
        vendor("widgets@#{vendored}")
      end

      it "is 1 for a downgrade, with the reason", :aggregate_failures do
        release_then_vendor("#{major}.0.0", "#{major}.1.0", "#{major}.1.0", description: "Reworded.")

        _out, status, reason = vendor("widgets@#{major}.0.0")

        expect(status).to eq(1)
        expect(reason).to include("widgets #{major}.1.0 is vendored; #{major}.0.0 is older")
      end

      it "is 1 for a downgrade, with the reason, with --wait", :aggregate_failures do
        release_then_vendor("#{major}.0.0", "#{major}.1.0", "#{major}.1.0", description: "Reworded.")

        vendor("widgets@#{major}.0.0")
        _out, status, reason = revendor("widgets@#{major}.0.0", "--wait")

        expect(status).to eq(1)
        expect(reason).to include("widgets #{major}.1.0 is vendored; #{major}.0.0 is older")
      end

      it "is 1 for a shape change on a patch bump, with the reason", :aggregate_failures do
        release_then_vendor("#{major}.0.0", "#{major}.0.1", "#{major}.0.0", extra_attribute: true)

        _out, status, reason = vendor("widgets@#{major}.0.1")

        expect(status).to eq(1)
        expect(reason).to include("changes the storage shape but is only a patch bump")
        expect(reason).not_to include("Hecks::Adapters")
      end

      it "is 1 for a package the source does not carry, with the reason", :aggregate_failures do
        release("#{major}.0.0")

        _out, status, reason = vendor("gadgets_#{major}")

        expect(status).to eq(1)
        expect(reason).to include("no gadgets_#{major}-v* release tag")
      end

      it "is 1 for a name that is not a plain name, with the reason", :aggregate_failures do
        out, status = vendor("../widgets")

        expect(status).to eq(1)
        expect(out).to include("must match")
      end

      it "lists only commands the table has" do
        settled = Hecks::Adapters::Driving::LauncherOptions.settings(@hecks, "Hecks").fetch(:settled)

        expect(settled - CUSTODIAN_VERBS - DEPLOY_CHAPTER_VERBS).to be_empty
      end

      it "leaves another command to its own --wait, unchanged" do
        _out, status = run_verb("package.unpinned", "--wait")

        expect(status).to eq(0)
      end
    end
  end

  describe "the Launch verbs" do
    def ended_of(run)
      JSON.parse(run_verb("launch.ended", run).first).first
    end

    around do |example|
      Dir.chdir(@dir) { example.run }
    end

    # The argv the Terminal adapter was handed while `launch.serve_mcp` ran.
    def served_by_mcp(run)
      served = []
      Hecks::Adapters::Terminal.server = ->(argv) { served << argv }
      begin
        run_verb("launch.serve_mcp", "run=#{run}", "--stdio")
      ensure
        Hecks::Adapters::Terminal.server = nil
      end
      served
    end

    it "project_cli writes a launcher beside each domain of the current directory and keeps what it wrote", :aggregate_failures do
      out, status = run_verb("launch.project_cli", "run=launchers-1")

      expect([status, JSON.parse(out).fetch("events")]).to eq([0, ["LaunchersRequested"]])
      row = ended_of("launchers-1")
      expect(status_and(row, "output")).to match(["finished", a_string_including("shelf/shelf  ->  Shelf")])
      expect(File.executable?(File.join(@shelf, "shelf"))).to be(true)
    end

    it "project_cli keeps a domain it cannot boot as a stopped entry point", :aggregate_failures do
      run_verb("launch.project_cli", "run=launchers-2", "domains=nowhere")

      expect(ended_of("launchers-2").fetch("status")).to eq("stopped")
      expect(listed("launch.stopped", "run")).to include("launchers-2")
    end

    it "serve_mcp hands the process to the entry point through the Terminal adapter and keeps that it closed",
       :aggregate_failures do
      served = served_by_mcp("mcp-1")

      expect(served).to eq([["--stdio"]])
      expect(ended_of("mcp-1").dig("output", "value")).to eq("mcp server closed")
    end
  end

  # A fake runner stands in for the toolchain, so each verb is journaled and asked without a build.
  describe "the Build verbs" do
    let(:asked) { [] }
    let(:stage) { File.join(@dir, "stage") }
    let(:steps) { File.join(@dir, "steps.json") }
    let(:script_calls) do
      [["project_wasm_browser", @shelf],
       ["rust_conformance", @shelf, steps, "native"],
       ["rust_conformance_fuzz", @shelf, "native", "3", "25"],
       ["rust_coverage", "--check-allowlist"]]
    end

    def result_of(run)
      JSON.parse(run_verb("build.result", run).first).first
    end

    def toolchain_says(out: "", err: "", passed: true)
      answer = Struct.new(:out, :err, :status) { def ok? = status.zero? }.new(out, err, passed ? 0 : 1)
      log = asked
      Hecks::Adapters::RustToolchain.runner = Object.new.tap do |runner|
        runner.define_singleton_method(:capture) do |tool, argv, **|
          log << [tool, *argv]
          answer
        end
      end
    end

    after { Hecks::Adapters::RustToolchain.runner = nil }

    def run_script_verbs
      run_verb("build.build_browser_wasm", @shelf, "run=browser-1")
      run_verb("build.check_conformance", @shelf, "script=#{steps}", "run=conform-1", "artifact=native")
      run_verb("build.fuzz_conformance", @shelf, "artifact=native", "run=fuzz-1", "seeds=3")
      run_verb("build.check_coverage_allowlist", "run=allow-1")
    end

    it "project_rust asks the toolchain to generate the domain and keeps what it reported", :aggregate_failures do
      toolchain_says(out: "wrote rust/src/generated/shelf/mod.rs\n")

      out, status = run_verb("build.project_rust", @shelf, "run=rust-1")

      expect([status, JSON.parse(out).fetch("events")]).to eq([0, ["RustProjectionRequested"]])
      expect(asked).to eq([["project_rust", @shelf]])
      expect(status_and(result_of("rust-1"), "output")).to match(["completed", a_string_including("shelf/mod.rs")])
    end

    it "keeps a build the toolchain refused as faulted, with its reason, and faulted lists it", :aggregate_failures do
      toolchain_says(err: "wasm32-wasip1 isn't installed for this toolchain\n", passed: false)

      run_verb("build.build_wasm", @shelf, "run=wasm-1")

      row = result_of("wasm-1")
      expect(status_and(row, "refusal")).to match(["faulted", a_string_including("wasm32-wasip1 isn't installed")])
      expect(listed("build.faulted", "run")).to include("wasm-1")
    end

    it "build_host asks project_host with its target and stage, and refuses a target that is no triple", :aggregate_failures do
      toolchain_says

      run_verb("build.build_host", @shelf, "run=host-1", "target=aarch64-unknown-linux-gnu", "stage_dir=#{stage}")
      _out, status = run_verb("build.build_host", @shelf, "run=host-2", "target=arm64")

      expect(asked).to eq([["project_host", @shelf, "--target=aarch64-unknown-linux-gnu", "--stage=#{stage}"]])
      expect(status).not_to eq(0)
    end

    it "build_browser_wasm, check_conformance, fuzz_conformance and check_coverage_allowlist each ask their own script" do
      toolchain_says

      run_script_verbs

      expect(asked).to eq(script_calls)
    end

    it "answers rust_coverage as a report and writes no journal entry of its own", :aggregate_failures do
      toolchain_says(out: "#{"=" * 72}\nShelf - 2 constructs\n")

      ran = run_counting_journal("build.rust_coverage", "shelf", "codegen=rust")

      expect([ran.status, ran.journaled]).to eq([0, 0])
      expect(ran.out).to include("Shelf - 2 constructs")
      expect(asked).to eq([["rust_coverage", "shelf", "--codegen=rust"]])
    end

    it "refuses a domain whose name cannot be a Rust module before anything is asked", :aggregate_failures do
      toolchain_says

      out, status = run_verb("build.project_rust", "Shelf", "run=rust-2")

      expect(status).to eq(1)
      expect(out).to include("must match")
      expect(asked).to be_empty
    end

    it "refuses a rust_coverage codegen that is neither ruby nor rust", :aggregate_failures do
      out, status = run_verb("build.rust_coverage", "shelf", "codegen=go")

      expect(status).to eq(1)
      expect(out).to include("must match")
    end
  end

  # A fake pool stands in for the child processes, so each verb is journaled and asked without one.
  describe "the Fuzzing verbs" do
    let(:started) { [] }

    def conclusion_of(run)
      JSON.parse(run_verb("fuzz_run.conclusion", run).first).first
    end

    def pool_says(output, passed: true)
      Hecks::Adapters::ProcessPool.starter = recording_starter(output, passed)
      Hecks::Adapters::RustToolchain.pool = recording_pool(Struct.new(:output, :ok?).new(output, passed))
    end

    def recording_starter(output, passed)
      log = started
      status = Struct.new(:success?, :exitstatus).new(passed, passed ? 0 : 1)
      lambda do |command, _env, _chdir|
        # A sweep starts as `ruby -I lib -e <program> -- <flags>`; a script as
        # `ruby <script> <flags>`.
        log << if command[1] == "-I" then ["fuzz", *command.drop(command.index("--") + 1)]
               else [File.basename(command[1]), *command.drop(2)]
               end
        Hecks::Adapters::ProcessPool::Finished.new(output, status)
      end
    end

    def recording_pool(finished)
      log = started
      Object.new.tap do |pool|
        pool.define_singleton_method(:run) do |command, **|
          # The benchmark starts as `ruby -I lib -e <program> -- <flags>`.
          log << ["bench", *command.drop(command.index("--") + 1)]
          finished
        end
      end
    end

    after do
      Hecks::Adapters::ProcessPool.starter = nil
      Hecks::Adapters::RustToolchain.pool = nil
    end

    it "fuzz asks the pool for a sweep and keeps what it printed", :aggregate_failures do
      pool_says("CLEAN — no generated sequence broke a property or the interpreter.\n")

      out, status = run_verb("fuzz_run.fuzz", @shelf, "run=sweep-1", "seeds=4", "steps=6", "adapter=memory")

      expect([status, JSON.parse(out).fetch("events")]).to eq([0, ["FuzzRequested"]])
      expect(started).to eq([["fuzz", @shelf, "--seeds", "4", "--steps", "6", "--adapter", "memory"]])
      expect(status_and(conclusion_of("sweep-1"), "report")).to match(["concluded", a_string_starting_with("CLEAN")])
    end

    it "keeps a sweep that found something as halted, and halted lists it", :aggregate_failures do
      pool_says("FUZZ FOUND SOMETHING.\n", passed: false)

      run_verb("fuzz_run.fuzz", @shelf, "run=sweep-2")

      expect(conclusion_of("sweep-2").fetch("status")).to eq("halted")
      expect(listed("fuzz_run.halted", "run")).to include("sweep-2")
    end

    it "refuses a sweep of zero seeds before anything is asked", :aggregate_failures do
      pool_says("CLEAN\n")

      out, status = run_verb("fuzz_run.fuzz", @shelf, "run=sweep-3", "seeds=0")

      expect(status).to eq(1)
      expect(out).to include("a count is positive")
      expect(started).to be_empty
    end

    it "bench asks the toolchain to measure with the flags it was given, and keeps the report", :aggregate_failures do
      pool_says("| target | ops/s |\n")

      run_verb("fuzz_run.bench", "run=bench-1", "domains=pizzas", "iterations=10", "warmup=0", "runs=1", "format=json")

      expect(started).to eq([["bench", "--domain", "pizzas", "--iterations", "10", "--warmup", "0", "--runs", "1",
                              "--format", "json"]])
      expect(conclusion_of("bench-1").dig("report", "value")).to include("ops/s")
    end

    it "generate_sequence answers a replayable script, and writes no journal entry of its own", :aggregate_failures do
      ran = run_counting_journal("fuzz_run.generate_sequence", @shelf, "seed=2", "steps=4")

      expect([ran.status, ran.journaled]).to eq([0, 0])
      script = JSON.parse(ran.out)
      expect(script.fetch("name")).to eq("shelf-generated")
      expect(script.fetch("steps")).to all(include("verb"))
    end
  end

  def standing_of(url)
    JSON.parse(run_verb("host.standing", url).first).first
  end

  def capture_stdout
    saved = $stdout
    $stdout = StringIO.new
    yield
  ensure
    $stdout = saved
  end
end
