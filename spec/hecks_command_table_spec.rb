require "spec_helper"
require "tmpdir"
require "fileutils"
require "json"
require "socket"
require "securerandom"

# ADR 0080, section 7: every row of the command table resolves in the launcher. Each verb of
# Custodian's Introspection, Operation, Host, Era, Package and Door (and the ModelCheck the table
# puts beside them) answers
# `--help`, and the journaled ones are then run the way `hecks <verb>` runs them.
RSpec.describe "the Hecks command table through the launcher" do
  # Introspection's queries and the verbs of ModelCheckRun and Operation, as the launcher spells
  # them.
  COMMAND_LAUNCHER_NAMES = { "operation.open_console" => "console", "door.serve_mcp" => "mcp" }.freeze

  # Settled verbs of the attached Deploy chapter; hecks_deploy_smoke_run_spec.rb runs them.
  DEPLOY_CHAPTER_VERBS = %w[smoke_run.run].freeze

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
    package.pinning package.unpinned package.verify package.check package.release
    operation.bootstrap_admin door.project_cli door.serve_mcp
    door.ended door.stopped build.project_rust build.build_wasm
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
    @hecks = Hecks.boot(File.join(InMemoryDomain::ROOT, "lib/hecks/hecks"), install_doors: false)
  end

  after(:all) { FileUtils.rm_rf(@dir) }

  def write(path, text)
    full = File.join(@dir, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, text)
  end

  def run_verb(*argv)
    Hecks::Doors::CliRunner.call(runtime: @hecks, argv: argv, program: "hecks")
  end

  def verdict_of(run)
    JSON.parse(run_verb("model_check_run.verdict", run).first).first
  end

  def outcome_of(run)
    JSON.parse(run_verb("operation.outcome", run).first).first
  end

  CUSTODIAN_VERBS.each do |verb|
    it "answers `hecks #{verb} --help`" do
      out, status = run_verb(verb, "--help")

      expect(status).to eq(0)
      expect(out).to start_with(COMMAND_LAUNCHER_NAMES.fetch(verb, verb))
    end
  end

  describe "model_check" do
    it "keeps a clean verdict beside the request" do
      out, status = run_verb("model_check_run.model_check", "run=clean-1", "domains=#{File.join(@dir, 'clean')}")

      expect(status).to eq(0)
      expect(JSON.parse(out).fetch("events")).to eq(["ModelCheckRequested"])
      row = verdict_of("clean-1")
      expect(row.fetch("status")).to eq("clean")
      expect(row.dig("report", "value")).to include("no dead states")
    end

    it "flags a domain whose model has a finding, and keeps what was found" do
      run_verb("model_check_run.model_check", "run=shelf-1", "domains=#{@shelf}")

      row = verdict_of("shelf-1")
      expect(row.fetch("status")).to eq("flagged")
      expect(row.dig("refusal", "value")).to include("Lend")
      expect(JSON.parse(run_verb("model_check_run.flagged").first).map do |flagged|
        flagged.dig("run", "value")
      end).to include("shelf-1")
    end

    it "flags a domain that does not exist instead of calling it clean" do
      run_verb("model_check_run.model_check", "run=none-1", "domains=#{File.join(@dir, 'nowhere')}")

      expect(verdict_of("none-1").fetch("status")).to eq("flagged")
    end

    it "refuses a profile it does not know, before anything is recorded" do
      out, status = run_verb("model_check_run.model_check", "run=bad-1", "profile=strictest")

      expect(status).to eq(1)
      expect(out).to include("must match")
      expect(run_verb("model_check_run.verdict", "bad-1").first).not_to include("bad-1")
    end
  end

  describe "the Operation verbs" do
    it "refresh_projections catches up and keeps how many" do
      run_verb("operation.refresh_projections", "run=refresh-1", "subject=#{@shelf}")

      row = outcome_of("refresh-1")
      expect(row.fetch("status")).to eq("succeeded")
      expect(row.dig("output", "value")).to eq("refreshed 0 projection(s)")
    end

    it "run_behaviors keeps the per-test report" do
      run_verb("operation.run_behaviors", "run=behave-1", "subject=#{File.join(@shelf, 'bluebook/shelf.behaviors')}")

      row = outcome_of("behave-1")
      expect(row.fetch("status")).to eq("succeeded")
      expect(row.dig("output", "value")).to include("Shelve records a book")
    end

    it "run dispatches a verb against the domain" do
      run_verb("operation.run", "run=verb-1", "subject=#{@shelf}", "verb=book.shelve", "arguments=title.value=Dune")

      row = outcome_of("verb-1")
      expect(row.fetch("status")).to eq("succeeded")
      expect(row.dig("output", "value")).to include("Dune")
    end

    it "run keeps a refusal as a failed operation, with the domain's own sentence" do
      run_verb("operation.run", "run=verb-2", "subject=#{@shelf}", "verb=book.shelve")

      row = outcome_of("verb-2")
      expect(row.fetch("status")).to eq("failed")
      expect(row.dig("refusal", "value")).to include("title")
      expect(JSON.parse(run_verb("operation.failed").first).map { |failed| failed.dig("run", "value") }).to include("verb-2")
    end

    it "run refuses a request that names neither a script nor a verb, and records nothing" do
      out, status = run_verb("operation.run", "run=neither-1", "subject=#{@shelf}")

      expect(status).to eq(1)
      expect(out).to include("exactly one of a script and a verb is named")
      expect(run_verb("operation.outcome", "neither-1").first).not_to include("neither-1")
    end

    it "run refuses a request that names both a script and a verb, and records nothing" do
      out, status = run_verb("operation.run", "run=both-1", "subject=#{@shelf}", "script=steps.json", "verb=book.shelve")

      expect(status).to eq(1)
      expect(out).to include("exactly one of a script and a verb is named")
      expect(run_verb("operation.outcome", "both-1").first).not_to include("both-1")
    end

    it "run accepts a script alone, and keeps its failure as the operation's" do
      run_verb("operation.run", "run=script-1", "subject=#{@shelf}", "script=#{File.join(@dir, 'no-such-steps.json')}")

      row = outcome_of("script-1")
      expect(row.fetch("status")).to eq("failed")
      expect(row.dig("script", "value")).to end_with("no-such-steps.json")
    end

    it "smoke_test dispatches one call per command" do
      run_verb("operation.smoke_test", "run=smoke-1", "subject=#{File.join(@dir, 'clean')}")

      row = outcome_of("smoke-1")
      expect(row.fetch("status")).to eq("succeeded")
      expect(row.dig("output", "value")).to include("dispatched cleanly")
    end

    it "smoke_http fails without a signing secret in the environment, and never takes one as an argument" do
      run_verb("operation.smoke_http", "run=hook-1", "path=/webhooks/events")

      row = outcome_of("hook-1")
      expect(row.fetch("status")).to eq("failed")
      expect(row.dig("refusal", "value")).to include("SMOKE_WEBHOOK_SECRET")
      expect(run_verb("operation.smoke_http", "--help").first).not_to include("secret")
    end

    it "open_console launches its session through the Terminal adapter and keeps that it ended" do
      launched = []
      Hecks::Adapters::Terminal.launcher = -> { launched << :irb }

      begin
        capture_stdout { run_verb("operation.open_console", "run=console-1", "subject=#{@shelf}") }
      ensure
        Hecks::Adapters::Terminal.launcher = nil
      end

      expect(launched).to eq([:irb])
      expect(outcome_of("console-1").dig("output", "value")).to include("console session ended")
    end
  end

  describe "follow" do
    it "answers a cursor and the entries past it, and writes no journal entry of its own" do
      before = @hecks.registry.event_log.to_a.size
      out, status = run_verb("operation.follow", @shelf)

      expect(status).to eq(0)
      row = JSON.parse(out).first
      expect(row).to include("cursor" => 0, "events" => [])
      expect(row["taken_at"]).to match(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\z/)
      expect(@hecks.registry.event_log.to_a.size).to eq(before)
    end

    describe "--stream" do
      def tail_row(cursor, *events)
        entries = events.map do |name|
          { name: name, aggregate: "Shelf::Book", id: "b1", payload: "{\"title\":\"Dune\"}",
            occurred_at: "2026-10-01T00:00:00Z" }
        end
        [{ cursor: cursor, taken_at: "2026-10-01T00:00:00Z", events: entries }]
      end

      it "asks again from the cursor each answer gives and prints every entry as one line" do
        asked = []
        answers = [tail_row(2, "Shelved", "Borrowed"), tail_row(2), tail_row(3, "Returned")]
        allow(@hecks).to receive(:query) do |_verb, **args|
          asked << args
          answers.shift
        end
        out = StringIO.new

        status = Hecks::Doors::CliRunner.stream(runtime: @hecks, argv: ["operation.follow", @shelf, "from_now=true", "--stream"],
                                                program: "hecks", out: out, max_polls: 3)

        lines = out.string.lines.map { |line| JSON.parse(line) }
        expect(status).to eq(0)
        expect(lines.map { |line| line["name"] }).to eq(%w[Shelved Borrowed Returned])
        expect(lines.first["payload"]).to eq("title" => "Dune")
        expect(asked.map { |args| args.dig(:since, :value) }).to eq([nil, 2, 2])
        expect(asked.map { |args| args.key?(:from_now) }).to eq([true, false, false])
        expect(asked).to all(include(wait: { value: 30 }))
      end

      it "is not a stream without --stream, or for a question the world does not list" do
        expect(Hecks::Doors::CliRunner.stream(runtime: @hecks, argv: ["operation.follow", @shelf], program: "hecks")).to be_nil
        expect(Hecks::Doors::CliRunner.stream(runtime: @hecks, argv: ["model_check_run.verdict", "x", "--stream"],
                                              program: "hecks")).to be_nil
      end

      it "ends with status 0 when the reader interrupts" do
        allow(@hecks).to receive(:query).and_raise(Interrupt)

        expect(Hecks::Doors::CliRunner.stream(runtime: @hecks, argv: ["operation.follow", @shelf, "--stream"], program: "hecks",
                                              out: StringIO.new)).to eq(0)
      end
    end

    it "words a domain that is not there as a refusal" do
      out, status = run_verb("operation.follow", File.join(@dir, "nowhere"))

      expect(status).to eq(1)
      expect(out).to include("no such domain")
    end
  end

  describe "the Host verbs" do
    it "check_era keeps a host that cannot be reached as unreachable, with the reason" do
      run_verb("host.check_era", "http://127.0.0.1:1", "expected=#{File.join(@dir, 'eras.txt')}")

      row = standing_of("http://127.0.0.1:1")
      expect(row.fetch("status")).to eq("unreachable")
      expect(row.dig("refusal", "value")).to include("could not be reached")
    end

    it "keeps the era a host reports, flags a drift, and rechecks the same host", :io do
      server = TCPServer.new("127.0.0.1", 0)
      thread = Thread.new do
        loop do
          client = server.accept
          while (line = client.gets) && line != "\r\n"; end
          body = JSON.generate(era: "abc123", version: "3.0.0")
          client.write("HTTP/1.1 200 OK\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
          client.close
        end
      end
      url = "http://127.0.0.1:#{server.addr[1]}"
      write("eras-ok.txt", "abc123\n")
      write("eras-old.txt", "def456\n")

      run_verb("host.check_era", url, "expected=#{File.join(@dir, 'eras-ok.txt')}")
      row = standing_of(url)
      expect([row.fetch("status"), row.dig("era", "value"), row.dig("version", "value")])
        .to eq(["observed", "abc123", "3.0.0"])

      run_verb("host.recheck", url, "expected=#{File.join(@dir, 'eras-old.txt')}")
      expect(standing_of(url).fetch("status")).to eq("drifted")
      expect(JSON.parse(run_verb("host.drifted").first).map { |host| host.dig("host", "value") }).to include(url)
    ensure
      thread&.kill
      server&.close
    end

    it "refuses a second check of a host that is already recorded" do
      run_verb("host.check_era", "http://127.0.0.1:2", "expected=#{File.join(@dir, 'eras.txt')}")
      out, status = run_verb("host.check_era", "http://127.0.0.1:2", "expected=#{File.join(@dir, 'eras.txt')}")

      expect(status).to eq(1)
      expect(out).to include("already exists")
    end
  end

  describe "the Era verbs" do
    HEKI_FIXTURE = File.join(InMemoryDomain::ROOT, "spec/fixtures/heki_compact_fixture/bluebook").freeze
    BANKING_EXAMPLE = File.join(InMemoryDomain::ROOT, "examples/banking/bluebook").freeze

    def settlement_of(run)
      JSON.parse(run_verb("era.settlement", run).first).first
    end

    def seeded_heki(name)
      target = File.join(@dir, name)
      FileUtils.cp_r(HEKI_FIXTURE, target)
      runtime = Hecks.boot(target, install_doors: false)
      aggregate = runtime.registry.bluebook("HekiCompactFixture").aggregate("Gadget")
      repository = runtime.registry.repository("HekiCompactFixture", aggregate)
      3.times do |i|
        built = Hecks::Runtime::Instance.new(aggregate: aggregate, id: "g1")
        built[:name] = Hecks::Runtime::Value.for(aggregate, :name, { value: "g1" })
        built[:label] = Hecks::Runtime::Value.for(aggregate, :label, { value: "label#{i}" })
        repository.save(built)
      end
      target
    end

    it "refuses every change that changes something until it is confirmed, and records nothing" do
      %w[era.hold_first era.merge_tail era.compact era.compact_heki era.approve_translation].each do |verb|
        out, status = run_verb(verb, @shelf, "run=unconfirmed-#{verb.split('.').last}")

        expect(status).to eq(1)
        expect(out).to include("is confirmed")
        expect(run_verb("era.settlement", "unconfirmed-#{verb.split('.').last}").first).not_to include("unconfirmed")
      end
      expect(run_verb("era.reattest", @shelf, "era=1", "run=unconfirmed-reattest").last).to eq(1)
    end

    describe "reattest, once the journal store has examined the era's text" do
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

      it "attests a text that drifted from its digest, loads, and kept the era's shape" do
        examined_as(drifted: true, loadable: true, shape_kept: true)

        expect(reattest("attest-1")).to be_empty
        expect(settlement_of("attest-1").fetch("status")).to eq("settled")
        expect(@applied).to eq(1)
      end

      it "refuses a text that still matches its digest: there is nothing to re-attest" do
        examined_as

        expect(reattest("attest-2"))
          .to eq(["Permit refused — the held text no longer matches its digest: there is nothing to re-attest"])
        expect(settlement_of("attest-2").fetch("status")).to eq("refused")
        expect(JSON.parse(run_verb("era.abandoned").first).map { |change| change.dig("run", "value") })
          .to include("attest-2")
        expect(@applied).to eq(0)
      end

      it "refuses an edited text that does not load as a bluebook" do
        examined_as(drifted: true, loadable: false, shape_kept: false)

        expect(reattest("attest-3"))
          .to eq(["Permit refused — the edited text loads as a bluebook: restore a loadable text"])
        expect(@applied).to eq(0)
      end

      it "refuses an edit that changed the era's shape, whatever was confirmed" do
        examined_as(drifted: true, loadable: true, shape_kept: false)

        expect(reattest("attest-4")).to eq(
          ["Permit refused — the edit kept the era's shape, not just its text: " \
           "restore a text with the original shape"]
        )
        expect(@applied).to eq(0)
      end
    end

    it "previews a compaction, then compacts once confirmed, and keeps what was done" do
      target = seeded_heki("heki-compact")

      expect(run_verb("era.compaction", target).first).to include("DRY RUN gadget: would discard 3 journal entries")

      out, status = run_verb("era.compact_heki", target, "run=compact-1", "--confirm")
      expect(status).to eq(0)
      expect(JSON.parse(out).fetch("events")).to eq(["HekiCompactionRequested"])
      row = settlement_of("compact-1")
      expect(row.fetch("status")).to eq("settled")
      expect(row.dig("report", "value")).to include("COMPACTED gadget: discarded 3 journal entries")
      expect(File.size(File.join(@dir, "data", "gadget.heki.journal"))).to eq(0)
    end

    it "does not compact a journal a projection reads, and says why beside the request" do
      target = File.join(@dir, "banking")
      FileUtils.cp_r(BANKING_EXAMPLE, target)

      out, status = run_verb("era.compact_heki", target, "run=compact-2", "--confirm")

      expect(status).to eq(0)
      expect(JSON.parse(out).fetch("refused_reactions").first)
        .to include("policy" => "PermitWhenExamined",
                    "reason" => "Permit refused — no projection reads the journal that would be emptied")
      expect(settlement_of("compact-2").fetch("status")).to eq("refused")
      expect(JSON.parse(run_verb("era.abandoned").first).map { |change| change.dig("run", "value") })
        .to include("compact-2")
    end

    it "does not make a change its gate refused when `apply` is asked for the run anyway" do
      target = seeded_heki("heki-apply")
      journal = File.join(@dir, "data", "gadget.heki.journal")
      none = Hecks::Adapters::JournalStore::Examination::NEUTRAL.merge(operation: "compact_heki")
      found = none.transform_values { |fact| { value: fact } }
      allow(Hecks::Adapters::JournalStore).to receive(:new).and_wrap_original do |original, *args, **kwargs|
        original.call(*args, **kwargs).tap { |store| allow(store).to receive(:examine).and_return(found) }
      end
      run_verb("era.compact_heki", target, "run=apply-1", "--confirm")
      expect(settlement_of("apply-1").fetch("status")).to eq("refused")
      size = File.size(journal)

      run_verb("era.apply", "to=apply-1", "run=apply-1")

      expect(size).to be_positive
      expect(File.size(journal)).to eq(size)
      expect(settlement_of("apply-1").fetch("status")).to eq("refused")
    ensure
      FileUtils.rm_rf(File.join(@dir, "data"))
    end

    it "keeps a domain that is not there as a refused change, with the reason" do
      run_verb("era.compact", File.join(@dir, "nowhere"), "run=compact-3", "--confirm")

      row = settlement_of("compact-3")
      expect(row.fetch("status")).to eq("refused")
      expect(row.dig("refusal", "value")).to include("no such domain")
      expect(JSON.parse(run_verb("era.abandoned").first).map { |change| change.dig("run", "value") })
        .to include("compact-3")
    end

    it "words a domain that holds no era as an answer, and never holds one to answer" do
      out, status = run_verb("era.audit_translation", @shelf)

      expect(status).to eq(1)
      expect(out).to include("Shelf is bound to Memory, which holds no eras")
    end

    it "takes winners as id:old,id:new and refuses a malformed list" do
      out, status = run_verb("era.merge_tail", @shelf, "run=merge-1", "winners=a1", "--confirm")

      expect(status).to eq(1)
      expect(out).to include("must match")
    end
  end

  describe "operation.bootstrap_admin", :io do
    require_relative "support/crew_domain"

    let(:id)   { SecureRandom.hex(4) }
    let(:crew) { CrewDomain.write(File.join(@dir, "crew-#{id}"), sqlite: File.join(@dir, "crew-#{id}.sqlite3")) }

    it "admits and grants the first administrator, then exits 1 for a second" do
      out, status = run_verb("operation.bootstrap_admin", crew, "email=ada@example.com", "name=Ada")
      expect(status).to eq(0)
      expect(JSON.parse(out).dig("state", "output", "value")).to eq("Granted Admin access to ada@example.com (admitted first)")

      _out, status, reason = run_verb("operation.bootstrap_admin", crew, "email=grace@example.com")
      expect(status).to eq(1)
      expect(reason).to include("an administrator already exists (ada@example.com)")
    end

    it "exits 1 for a domain that provides no membership" do
      _out, status, reason = run_verb("operation.bootstrap_admin", File.join(@dir, "clean"), "email=ada@example.com")

      expect(status).to eq(1)
      expect(reason).to include("provides \"membership\"")
    end

    it "exits 1 for an email that is not one, before booting anything" do
      out, status = run_verb("operation.bootstrap_admin", crew, "email=ada")

      expect(status).to eq(1)
      expect(out).to include("must match")
    end
  end

  describe "the Package verbs" do
    def pinning_of(package)
      JSON.parse(run_verb("package.pinning", package).first).first
    end

    it "vendor keeps a source that is not there as a refused pinning, and unpinned lists it" do
      run_verb("package.vendor", "payments@1.2.0", "from=#{File.join(@dir, 'nowhere')}", "root=#{@dir}")

      row = pinning_of("payments@1.2.0")
      expect(row.fetch("status")).to eq("refused")
      expect(row.dig("refusal", "value")).to include("no source repository")
      expect(JSON.parse(run_verb("package.unpinned").first).map { |package| package.dig("package", "value") })
        .to include("payments@1.2.0")
    end

    it "vendors a release from a registry, and revendors the same spelling", :io do
      require_relative "support/registry_repo"
      registry = RegistryRepo.new(File.join(@dir, "registry"))
      registry.write("widgets/bluebook.yml"              => "name: widgets\nversion: 1.0.0\nsummary: Widgets.\n",
                     "widgets/bluebook/widgets.bluebook" => RegistryRepo.widgets_bluebook)
      registry.commit("widgets 1.0.0")
      registry.tag("widgets-v1.0.0")
      project = File.join(@dir, "project")

      run_verb("package.vendor", "widgets", "from=#{registry.path}", "root=#{project}")
      row = pinning_of("widgets")
      expect(row.fetch("status")).to eq("vendored")
      expect(row.dig("report", "value")).to include("widgets 1.0.0")
      expect(File.exist?(File.join(project, "vendor/embryonaut_bluebooks/widgets/bluebook.lock"))).to be(true)

      run_verb("package.revendor", "widgets", "from=#{registry.path}", "root=#{project}")
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

      it "prints the manifest as JSON and exits 0 when every package matches its lock" do
        out, status = run_verb("package.verify", "root=#{project}")

        expect(status).to eq(0)
        expect(JSON.parse(out).dig("bluebooks", "widgets", "version")).to eq("1.0.0")
      end

      it "exits 1 naming the package whose files were edited" do
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

      it "check answers versions ok, then exits 1 naming a changed package that was not bumped" do
        publish("1.0.0")
        registry.tag("widgets-v1.0.0")
        out, status = run_verb("package.check", "root=#{registry.path}")
        expect(status).to eq(0)
        expect(out).to eq("versions ok")

        publish("1.0.0", description: "Reworded.")
        out, status = run_verb("package.check", "root=#{registry.path}")
        expect(status).to eq(1)
        expect(out).to include("FAIL widgets: bluebook files changed since widgets-v1.0.0")
      end

      it "release tags the version locally, keeps the record, and exits 0" do
        publish("1.0.0")

        out, status = run_verb("package.release", "widgets", "root=#{registry.path}")

        expect(status).to eq(0)
        expect(JSON.parse(out).dig("state", "report", "value")).to include("git push origin widgets-v1.0.0")
        expect(registry.git("tag", "--list")).to eq("widgets-v1.0.0\n")
      end

      it "release exits 1 with the reason when a rule is broken, and makes no tag" do
        publish("1.0.0")
        registry.tag("widgets-v1.0.0")

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

      it "is 0 when the package was pinned" do
        release("#{major}.0.0")

        expect(vendor("widgets@#{major}.0.0").drop(1).first).to eq(0)
      end

      it "is 1 for a downgrade, with the reason, with or without --wait" do
        release("#{major}.0.0")
        release("#{major}.1.0", description: "Reworded.")
        vendor("widgets@#{major}.1.0")

        _out, status, reason = vendor("widgets@#{major}.0.0")
        expect(status).to eq(1)
        expect(reason).to include("widgets #{major}.1.0 is vendored; #{major}.0.0 is older")

        _out, status, reason = run_verb("package.revendor", "widgets@#{major}.0.0", "from=#{registry.path}",
                                        "root=#{project}", "--wait")
        expect(status).to eq(1)
        expect(reason).to include("widgets #{major}.1.0 is vendored; #{major}.0.0 is older")
      end

      it "is 1 for a shape change on a patch bump, with the reason" do
        release("#{major}.0.0")
        release("#{major}.0.1", extra_attribute: true)
        vendor("widgets@#{major}.0.0")

        _out, status, reason = vendor("widgets@#{major}.0.1")

        expect(status).to eq(1)
        expect(reason).to include("changes the storage shape but is only a patch bump")
        expect(reason).not_to include("Hecks::Adapters")
      end

      it "is 1 for a package the source does not carry, with the reason" do
        release("#{major}.0.0")

        _out, status, reason = vendor("gadgets_#{major}")

        expect(status).to eq(1)
        expect(reason).to include("no gadgets_#{major}-v* release tag")
      end

      it "is 1 for a name that is not a plain name, with the reason" do
        out, status = vendor("../widgets")

        expect(status).to eq(1)
        expect(out).to include("must match")
      end

      it "lists only commands the table has" do
        settled = Hecks::Doors::LauncherOptions.settings(@hecks, "Hecks").fetch(:settled)

        expect(settled - CUSTODIAN_VERBS - DEPLOY_CHAPTER_VERBS).to be_empty
      end

      it "leaves another command to its own --wait, unchanged" do
        _out, status = run_verb("package.unpinned", "--wait")

        expect(status).to eq(0)
      end
    end
  end

  describe "the Door verbs" do
    def ended_of(run)
      JSON.parse(run_verb("door.ended", run).first).first
    end

    around do |example|
      Dir.chdir(@dir) { example.run }
    end

    it "project_cli writes a launcher beside each domain of the current directory and keeps what it wrote" do
      out, status = run_verb("door.project_cli", "run=launchers-1")

      expect(status).to eq(0)
      expect(JSON.parse(out).fetch("events")).to eq(["LaunchersRequested"])
      row = ended_of("launchers-1")
      expect(row.fetch("status")).to eq("finished")
      expect(row.dig("output", "value")).to include("shelf/shelf  ->  Shelf")
      expect(File.executable?(File.join(@shelf, "shelf"))).to be(true)
    end

    it "project_cli keeps a domain it cannot boot as a stopped door" do
      run_verb("door.project_cli", "run=launchers-2", "domains=nowhere")

      expect(ended_of("launchers-2").fetch("status")).to eq("stopped")
      expect(JSON.parse(run_verb("door.stopped").first).map { |door| door.dig("run", "value") }).to include("launchers-2")
    end

    it "serve_mcp hands the process to the door through the Terminal adapter and keeps that it closed" do
      served = []
      Hecks::Adapters::Terminal.server = ->(argv) { served << argv }

      begin
        run_verb("door.serve_mcp", "run=mcp-1", "--stdio")
      ensure
        Hecks::Adapters::Terminal.server = nil
      end

      expect(served).to eq([["--stdio"]])
      expect(ended_of("mcp-1").dig("output", "value")).to eq("mcp door closed")
    end
  end

  # A fake runner stands in for the toolchain, so each verb is journaled and asked without a build.
  describe "the Build verbs" do
    let(:asked) { [] }

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

    it "project_rust asks the toolchain to generate the domain and keeps what it reported" do
      toolchain_says(out: "wrote rust/src/generated/shelf/mod.rs\n")

      out, status = run_verb("build.project_rust", @shelf, "run=rust-1")

      expect(status).to eq(0)
      expect(JSON.parse(out).fetch("events")).to eq(["RustProjectionRequested"])
      expect(asked).to eq([["project_rust", @shelf]])
      row = result_of("rust-1")
      expect(row.fetch("status")).to eq("completed")
      expect(row.dig("output", "value")).to include("shelf/mod.rs")
    end

    it "keeps a build the toolchain refused as faulted, with its reason, and faulted lists it" do
      toolchain_says(err: "wasm32-wasip1 isn't installed for this toolchain\n", passed: false)

      run_verb("build.build_wasm", @shelf, "run=wasm-1")

      row = result_of("wasm-1")
      expect(row.fetch("status")).to eq("faulted")
      expect(row.dig("refusal", "value")).to include("wasm32-wasip1 isn't installed")
      expect(JSON.parse(run_verb("build.faulted").first).map { |build| build.dig("run", "value") }).to include("wasm-1")
    end

    it "build_host asks project_host with its target and stage, and refuses a target that is no triple" do
      toolchain_says
      stage = File.join(@dir, "stage")

      run_verb("build.build_host", @shelf, "run=host-1", "target=aarch64-unknown-linux-gnu", "stage_dir=#{stage}")
      _out, status = run_verb("build.build_host", @shelf, "run=host-2", "target=arm64")

      expect(asked).to eq([["project_host", @shelf, "--target=aarch64-unknown-linux-gnu", "--stage=#{stage}"]])
      expect(status).not_to eq(0)
    end

    it "build_browser_wasm, check_conformance, fuzz_conformance and check_coverage_allowlist each ask their own script" do
      toolchain_says
      steps = File.join(@dir, "steps.json")

      run_verb("build.build_browser_wasm", @shelf, "run=browser-1")
      run_verb("build.check_conformance", @shelf, "script=#{steps}", "run=conform-1", "artifact=native")
      run_verb("build.fuzz_conformance", @shelf, "artifact=native", "run=fuzz-1", "seeds=3")
      run_verb("build.check_coverage_allowlist", "run=allow-1")

      expect(asked).to eq([["project_wasm_browser", @shelf],
                           ["rust_conformance", @shelf, steps, "native"],
                           ["rust_conformance_fuzz", @shelf, "native", "3", "25"],
                           ["rust_coverage", "--check-allowlist"]])
    end

    it "answers rust_coverage as a report and writes no journal entry of its own" do
      toolchain_says(out: "#{'=' * 72}\nShelf - 2 constructs\n")
      before = @hecks.registry.event_log.to_a.size

      out, status = run_verb("build.rust_coverage", "shelf", "codegen=rust")

      expect(status).to eq(0)
      expect(out).to include("Shelf - 2 constructs")
      expect(asked).to eq([["rust_coverage", "shelf", "--codegen=rust"]])
      expect(@hecks.registry.event_log.to_a.size).to eq(before)
    end

    it "refuses a domain whose name cannot be a Rust module before anything is asked" do
      toolchain_says

      out, status = run_verb("build.project_rust", "Shelf", "run=rust-2")

      expect(status).to eq(1)
      expect(out).to include("must match")
      expect(asked).to be_empty
    end

    it "refuses a rust_coverage codegen that is neither ruby nor rust" do
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
      log = started
      finished = Struct.new(:output, :ok?).new(output, passed)
      status = Struct.new(:success?, :exitstatus).new(passed, passed ? 0 : 1)
      Hecks::Adapters::ProcessPool.starter = lambda do |command, _env, _chdir|
        # A sweep starts as `ruby -I lib -e <program> -- <flags>`; a script as
        # `ruby <script> <flags>`.
        log << if command[1] == "-I" then ["fuzz", *command.drop(command.index("--") + 1)]
               else [File.basename(command[1]), *command.drop(2)]
               end
        Hecks::Adapters::ProcessPool::Finished.new(finished.output, status)
      end
      Hecks::Adapters::RustToolchain.pool = Object.new.tap do |pool|
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

    it "fuzz asks the pool for a sweep and keeps what it printed" do
      pool_says("CLEAN — no generated sequence broke a property or the interpreter.\n")

      out, status = run_verb("fuzz_run.fuzz", @shelf, "run=sweep-1", "seeds=4", "steps=6", "adapter=memory")

      expect(status).to eq(0)
      expect(JSON.parse(out).fetch("events")).to eq(["FuzzRequested"])
      expect(started).to eq([["fuzz", @shelf, "--seeds", "4", "--steps", "6", "--adapter", "memory"]])
      row = conclusion_of("sweep-1")
      expect(row.fetch("status")).to eq("concluded")
      expect(row.dig("report", "value")).to start_with("CLEAN")
    end

    it "keeps a sweep that found something as halted, and halted lists it" do
      pool_says("FUZZ FOUND SOMETHING.\n", passed: false)

      run_verb("fuzz_run.fuzz", @shelf, "run=sweep-2")

      expect(conclusion_of("sweep-2").fetch("status")).to eq("halted")
      expect(JSON.parse(run_verb("fuzz_run.halted").first).map { |sweep| sweep.dig("run", "value") }).to include("sweep-2")
    end

    it "refuses a sweep of zero seeds before anything is asked" do
      pool_says("CLEAN\n")

      out, status = run_verb("fuzz_run.fuzz", @shelf, "run=sweep-3", "seeds=0")

      expect(status).to eq(1)
      expect(out).to include("a count is positive")
      expect(started).to be_empty
    end

    it "bench asks the toolchain to measure with the flags it was given, and keeps the report" do
      pool_says("| target | ops/s |\n")

      run_verb("fuzz_run.bench", "run=bench-1", "domains=pizzas", "iterations=10", "warmup=0", "runs=1", "format=json")

      expect(started).to eq([["bench", "--domain", "pizzas", "--iterations", "10", "--warmup", "0", "--runs", "1",
                              "--format", "json"]])
      expect(conclusion_of("bench-1").dig("report", "value")).to include("ops/s")
    end

    it "generate_sequence answers a replayable script, and writes no journal entry of its own" do
      before = @hecks.registry.event_log.to_a.size

      out, status = run_verb("fuzz_run.generate_sequence", @shelf, "seed=2", "steps=4")

      expect(status).to eq(0)
      script = JSON.parse(out)
      expect(script.fetch("name")).to eq("shelf-generated")
      expect(script.fetch("steps")).to all(include("verb"))
      expect(@hecks.registry.event_log.to_a.size).to eq(before)
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
