require "spec_helper"
require "tmpdir"
require "fileutils"
require "json"
require "socket"

# ADR 0080, section 7: every row of the command table resolves in the launcher. Each verb of
# Custodian's Introspection, Operation, Host, Era, Package and Door (and the ModelCheck the table
# puts beside them) answers
# `--help`, and the journaled ones are then run the way `hecks <verb>` runs them.
RSpec.describe "the Hecks command table through the launcher" do
  # Introspection's queries and the verbs of ModelCheckRun and Operation, as the launcher spells
  # them.
  COMMAND_LAUNCHER_NAMES = { "open_console" => "console", "serve_mcp" => "mcp" }.freeze

  CUSTODIAN_VERBS = %w[
    ir shape stores history statements narrate docs project_diagrams glossary
    model_check verdict flagged
    run refresh_projections run_behaviors open_console smoke_test smoke_http outcome failed follow
    check_era recheck standing drifted
    hold_first merge_tail reattest backfill_projections compact compact_heki approve_translation
    settlement abandoned scaffold_translation audit_translation attestation compaction
    vendor revendor pinning unpinned
    project_cli serve_mcp ended stopped
    project_rust build_wasm build_browser_wasm check_conformance fuzz_conformance
    check_coverage_allowlist rust_coverage result faulted
    fuzz bench conclusion halted generate_sequence
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
    @hecks = Hecks.boot(File.join(InMemoryDomain::ROOT, "lib/hecks/hecks"), install_facade: false)
  end

  after(:all) { FileUtils.rm_rf(@dir) }

  def write(path, text)
    full = File.join(@dir, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, text)
  end

  def run_verb(*argv)
    Hecks::Facade::CliRunner.call(runtime: @hecks, argv: argv, program: "hecks")
  end

  def verdict_of(run)
    JSON.parse(run_verb("verdict", run).first).first
  end

  def outcome_of(run)
    JSON.parse(run_verb("outcome", run).first).first
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
      out, status = run_verb("model_check", "run=clean-1", "domains=#{File.join(@dir, 'clean')}")

      expect(status).to eq(0)
      expect(JSON.parse(out).fetch("events")).to eq(["ModelCheckRequested"])
      row = verdict_of("clean-1")
      expect(row.fetch("status")).to eq("clean")
      expect(row.dig("report", "value")).to include("no dead states")
    end

    it "flags a domain whose model has a finding, and keeps what was found" do
      run_verb("model_check", "run=shelf-1", "domains=#{@shelf}")

      row = verdict_of("shelf-1")
      expect(row.fetch("status")).to eq("flagged")
      expect(row.dig("refusal", "value")).to include("Lend")
      expect(JSON.parse(run_verb("flagged").first).map { |flagged| flagged.dig("run", "value") }).to include("shelf-1")
    end

    it "flags a domain that does not exist instead of calling it clean" do
      run_verb("model_check", "run=none-1", "domains=#{File.join(@dir, 'nowhere')}")

      expect(verdict_of("none-1").fetch("status")).to eq("flagged")
    end

    it "refuses a profile it does not know, before anything is recorded" do
      out, status = run_verb("model_check", "run=bad-1", "profile=strictest")

      expect(status).to eq(1)
      expect(out).to include("must match")
      expect(run_verb("verdict", "bad-1").first).not_to include("bad-1")
    end
  end

  describe "the Operation verbs" do
    it "refresh_projections catches up and keeps how many" do
      run_verb("refresh_projections", "run=refresh-1", "subject=#{@shelf}")

      row = outcome_of("refresh-1")
      expect(row.fetch("status")).to eq("succeeded")
      expect(row.dig("output", "value")).to eq("refreshed 0 projection(s)")
    end

    it "run_behaviors keeps the per-test report" do
      run_verb("run_behaviors", "run=behave-1", "subject=#{File.join(@shelf, 'bluebook/shelf.behaviors')}")

      row = outcome_of("behave-1")
      expect(row.fetch("status")).to eq("succeeded")
      expect(row.dig("output", "value")).to include("Shelve records a book")
    end

    it "run dispatches a verb against the domain" do
      run_verb("run", "run=verb-1", "subject=#{@shelf}", "verb=shelve", "arguments=title.value=Dune")

      row = outcome_of("verb-1")
      expect(row.fetch("status")).to eq("succeeded")
      expect(row.dig("output", "value")).to include("Dune")
    end

    it "run keeps a refusal as a failed operation, with the domain's own sentence" do
      run_verb("run", "run=verb-2", "subject=#{@shelf}", "verb=shelve")

      row = outcome_of("verb-2")
      expect(row.fetch("status")).to eq("failed")
      expect(row.dig("refusal", "value")).to include("title")
      expect(JSON.parse(run_verb("failed").first).map { |failed| failed.dig("run", "value") }).to include("verb-2")
    end

    it "run refuses a request that names neither a script nor a verb, and records nothing" do
      out, status = run_verb("run", "run=neither-1", "subject=#{@shelf}")

      expect(status).to eq(1)
      expect(out).to include("exactly one of a script and a verb is named")
      expect(run_verb("outcome", "neither-1").first).not_to include("neither-1")
    end

    it "run refuses a request that names both a script and a verb, and records nothing" do
      out, status = run_verb("run", "run=both-1", "subject=#{@shelf}", "script=steps.json", "verb=shelve")

      expect(status).to eq(1)
      expect(out).to include("exactly one of a script and a verb is named")
      expect(run_verb("outcome", "both-1").first).not_to include("both-1")
    end

    it "run accepts a script alone, and keeps its failure as the operation's" do
      run_verb("run", "run=script-1", "subject=#{@shelf}", "script=#{File.join(@dir, 'no-such-steps.json')}")

      row = outcome_of("script-1")
      expect(row.fetch("status")).to eq("failed")
      expect(row.dig("script", "value")).to end_with("no-such-steps.json")
    end

    it "smoke_test dispatches one call per command" do
      run_verb("smoke_test", "run=smoke-1", "subject=#{File.join(@dir, 'clean')}")

      row = outcome_of("smoke-1")
      expect(row.fetch("status")).to eq("succeeded")
      expect(row.dig("output", "value")).to include("dispatched cleanly")
    end

    it "smoke_http fails without a signing secret in the environment, and never takes one as an argument" do
      run_verb("smoke_http", "run=hook-1", "path=/webhooks/events")

      row = outcome_of("hook-1")
      expect(row.fetch("status")).to eq("failed")
      expect(row.dig("refusal", "value")).to include("SMOKE_WEBHOOK_SECRET")
      expect(run_verb("smoke_http", "--help").first).not_to include("secret")
    end

    it "open_console launches its session through the Terminal adapter and keeps that it ended" do
      launched = []
      Hecks::Adapters::Terminal.launcher = -> { launched << :irb }

      begin
        capture_stdout { run_verb("open_console", "run=console-1", "subject=#{@shelf}") }
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
      out, status = run_verb("follow", @shelf)

      expect(status).to eq(0)
      expect(JSON.parse(out).first).to eq("cursor" => 0, "events" => [])
      expect(@hecks.registry.event_log.to_a.size).to eq(before)
    end

    it "words a domain that is not there as a refusal" do
      out, status = run_verb("follow", File.join(@dir, "nowhere"))

      expect(status).to eq(1)
      expect(out).to include("no such domain")
    end
  end

  describe "the Host verbs" do
    it "check_era keeps a host that cannot be reached as unreachable, with the reason" do
      run_verb("check_era", "http://127.0.0.1:1", "expected=#{File.join(@dir, 'eras.txt')}")

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

      run_verb("check_era", url, "expected=#{File.join(@dir, 'eras-ok.txt')}")
      row = standing_of(url)
      expect([row.fetch("status"), row.dig("era", "value"), row.dig("version", "value")])
        .to eq(["observed", "abc123", "3.0.0"])

      run_verb("recheck", url, "expected=#{File.join(@dir, 'eras-old.txt')}")
      expect(standing_of(url).fetch("status")).to eq("drifted")
      expect(JSON.parse(run_verb("drifted").first).map { |host| host.dig("host", "value") }).to include(url)
    ensure
      thread&.kill
      server&.close
    end

    it "refuses a second check of a host that is already recorded" do
      run_verb("check_era", "http://127.0.0.1:2", "expected=#{File.join(@dir, 'eras.txt')}")
      out, status = run_verb("check_era", "http://127.0.0.1:2", "expected=#{File.join(@dir, 'eras.txt')}")

      expect(status).to eq(1)
      expect(out).to include("already exists")
    end
  end

  describe "the Era verbs" do
    HEKI_FIXTURE = File.join(InMemoryDomain::ROOT, "spec/fixtures/heki_compact_fixture/bluebook").freeze
    BANKING_EXAMPLE = File.join(InMemoryDomain::ROOT, "examples/banking/bluebook").freeze

    def settlement_of(run)
      JSON.parse(run_verb("settlement", run).first).first
    end

    def seeded_heki(name)
      target = File.join(@dir, name)
      FileUtils.cp_r(HEKI_FIXTURE, target)
      runtime = Hecks.boot(target, install_facade: false)
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
      %w[hold_first merge_tail compact compact_heki approve_translation].each do |verb|
        out, status = run_verb(verb, @shelf, "run=unconfirmed-#{verb}")

        expect(status).to eq(1)
        expect(out).to include("is confirmed")
        expect(run_verb("settlement", "unconfirmed-#{verb}").first).not_to include("unconfirmed")
      end
      expect(run_verb("reattest", @shelf, "era=1", "run=unconfirmed-reattest").last).to eq(1)
    end

    describe "reattest, once the journal store has examined the era's text" do
      # The JournalStore adapter stands in for a Postgres journal: it reports the facts an
      # examination of a held text finds, and counts the changes it is asked to make.
      def examined_as(**found)
        facts = Hecks::Adapters::JournalStore::Examination::NEUTRAL.merge(capable: true, **found)
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
        out, = run_verb("reattest", @shelf, "era=1", "run=#{run}", "--confirm")
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
        expect(settlement_of("attest-2").fetch("status")).to eq("requested")
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

      expect(run_verb("compaction", target).first).to include("DRY RUN gadget: would discard 3 journal entries")

      out, status = run_verb("compact_heki", target, "run=compact-1", "--confirm")
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

      out, status = run_verb("compact_heki", target, "run=compact-2", "--confirm")

      expect(status).to eq(0)
      expect(JSON.parse(out).fetch("refused_reactions").first)
        .to include("policy" => "PermitWhenExamined",
                    "reason" => "Permit refused — no projection reads the journal that would be emptied")
      expect(settlement_of("compact-2").fetch("status")).to eq("requested")
    end

    it "keeps a domain that is not there as a refused change, with the reason" do
      run_verb("compact", File.join(@dir, "nowhere"), "run=compact-3", "--confirm")

      row = settlement_of("compact-3")
      expect(row.fetch("status")).to eq("refused")
      expect(row.dig("refusal", "value")).to include("no such domain")
      expect(JSON.parse(run_verb("abandoned").first).map { |change| change.dig("run", "value") })
        .to include("compact-3")
    end

    it "words a domain that holds no era as an answer, and never holds one to answer" do
      out, status = run_verb("audit_translation", @shelf)

      expect(status).to eq(1)
      expect(out).to include("Shelf is bound to Memory, which holds no eras")
    end

    it "takes winners as id:old,id:new and refuses a malformed list" do
      out, status = run_verb("merge_tail", @shelf, "run=merge-1", "winners=a1", "--confirm")

      expect(status).to eq(1)
      expect(out).to include("must match")
    end
  end

  describe "the Package verbs" do
    def pinning_of(package)
      JSON.parse(run_verb("pinning", package).first).first
    end

    it "vendor keeps a source that is not there as a refused pinning, and unpinned lists it" do
      run_verb("vendor", "payments@1.2.0", "from=#{File.join(@dir, 'nowhere')}", "root=#{@dir}")

      row = pinning_of("payments@1.2.0")
      expect(row.fetch("status")).to eq("refused")
      expect(row.dig("refusal", "value")).to include("no source repository")
      expect(JSON.parse(run_verb("unpinned").first).map { |package| package.dig("package", "value") })
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

      run_verb("vendor", "widgets", "from=#{registry.path}", "root=#{project}")
      row = pinning_of("widgets")
      expect(row.fetch("status")).to eq("vendored")
      expect(row.dig("report", "value")).to include("widgets 1.0.0")
      expect(File.exist?(File.join(project, "vendor/embryonaut_bluebooks/widgets/bluebook.lock"))).to be(true)

      run_verb("revendor", "widgets", "from=#{registry.path}", "root=#{project}")
      expect(pinning_of("widgets").fetch("status")).to eq("vendored")
    end
  end

  describe "the Door verbs" do
    def ended_of(run)
      JSON.parse(run_verb("ended", run).first).first
    end

    around do |example|
      Dir.chdir(@dir) { example.run }
    end

    it "project_cli writes a launcher beside each domain of the current directory and keeps what it wrote" do
      out, status = run_verb("project_cli", "run=launchers-1")

      expect(status).to eq(0)
      expect(JSON.parse(out).fetch("events")).to eq(["LaunchersRequested"])
      row = ended_of("launchers-1")
      expect(row.fetch("status")).to eq("finished")
      expect(row.dig("output", "value")).to include("shelf/shelf  ->  Shelf")
      expect(File.executable?(File.join(@shelf, "shelf"))).to be(true)
    end

    it "project_cli keeps a domain it cannot boot as a stopped door" do
      run_verb("project_cli", "run=launchers-2", "domains=nowhere")

      expect(ended_of("launchers-2").fetch("status")).to eq("stopped")
      expect(JSON.parse(run_verb("stopped").first).map { |door| door.dig("run", "value") }).to include("launchers-2")
    end

    it "serve_mcp hands the process to the door through the Terminal adapter and keeps that it closed" do
      served = []
      Hecks::Adapters::Terminal.server = ->(argv) { served << argv }

      begin
        run_verb("serve_mcp", "run=mcp-1", "--stdio")
      ensure
        Hecks::Adapters::Terminal.server = nil
      end

      expect(served).to eq([["--stdio"]])
      expect(ended_of("mcp-1").dig("output", "value")).to eq("mcp door closed")
    end
  end

  # A fake shell stands in for the toolchain, so each verb is journaled and asked without a build.
  describe "the Build verbs" do
    let(:asked) { [] }

    def result_of(run)
      JSON.parse(run_verb("result", run).first).first
    end

    def toolchain_says(out: "", err: "", passed: true)
      status = Struct.new(:success?, :exitstatus).new(passed, passed ? 0 : 1)
      answer = Struct.new(:out, :err, :status) { def ok? = status.success? }.new(out, err, status)
      log = asked
      Hecks::Adapters::RustToolchain.shell = Object.new.tap do |shell|
        shell.define_singleton_method(:capture) do |*command, **|
          log << command.drop(1).then { |script, *rest| [File.basename(script), *rest] }
          answer
        end
      end
    end

    after { Hecks::Adapters::RustToolchain.shell = nil }

    it "project_rust asks the toolchain to generate the domain and keeps what it reported" do
      toolchain_says(out: "wrote rust/src/generated/shelf/mod.rs\n")

      out, status = run_verb("project_rust", @shelf, "run=rust-1")

      expect(status).to eq(0)
      expect(JSON.parse(out).fetch("events")).to eq(["RustProjectionRequested"])
      expect(asked).to eq([["project_rust", @shelf]])
      row = result_of("rust-1")
      expect(row.fetch("status")).to eq("completed")
      expect(row.dig("output", "value")).to include("shelf/mod.rs")
    end

    it "keeps a build the toolchain refused as faulted, with its reason, and faulted lists it" do
      toolchain_says(err: "wasm32-wasip1 isn't installed for this toolchain\n", passed: false)

      run_verb("build_wasm", @shelf, "run=wasm-1")

      row = result_of("wasm-1")
      expect(row.fetch("status")).to eq("faulted")
      expect(row.dig("refusal", "value")).to include("wasm32-wasip1 isn't installed")
      expect(JSON.parse(run_verb("faulted").first).map { |build| build.dig("run", "value") }).to include("wasm-1")
    end

    it "build_browser_wasm, check_conformance, fuzz_conformance and check_coverage_allowlist each ask their own script" do
      toolchain_says
      steps = File.join(@dir, "steps.json")

      run_verb("build_browser_wasm", @shelf, "run=browser-1")
      run_verb("check_conformance", @shelf, "script=#{steps}", "run=conform-1", "artifact=native")
      run_verb("fuzz_conformance", @shelf, "artifact=native", "run=fuzz-1", "seeds=3")
      run_verb("check_coverage_allowlist", "run=allow-1")

      expect(asked).to eq([["project_wasm_browser", @shelf],
                           ["rust_conformance", @shelf, steps, "native"],
                           ["rust_conformance_fuzz", @shelf, "native", "3", "25"],
                           ["rust_coverage", "--check-allowlist"]])
    end

    it "answers rust_coverage as a report and writes no journal entry of its own" do
      toolchain_says(out: "#{'=' * 72}\nShelf - 2 constructs\n")
      before = @hecks.registry.event_log.to_a.size

      out, status = run_verb("rust_coverage", "shelf", "codegen=rust")

      expect(status).to eq(0)
      expect(out).to include("Shelf - 2 constructs")
      expect(asked).to eq([["rust_coverage", "shelf", "--codegen=rust"]])
      expect(@hecks.registry.event_log.to_a.size).to eq(before)
    end

    it "refuses a domain whose name cannot be a Rust module before anything is asked" do
      toolchain_says

      out, status = run_verb("project_rust", "Shelf", "run=rust-2")

      expect(status).to eq(1)
      expect(out).to include("must match")
      expect(asked).to be_empty
    end

    it "refuses a rust_coverage codegen that is neither ruby nor rust" do
      out, status = run_verb("rust_coverage", "shelf", "codegen=go")

      expect(status).to eq(1)
      expect(out).to include("must match")
    end
  end

  # A fake pool stands in for the child processes, so each verb is journaled and asked without one.
  describe "the Fuzzing verbs" do
    let(:started) { [] }

    def conclusion_of(run)
      JSON.parse(run_verb("conclusion", run).first).first
    end

    def pool_says(output, passed: true)
      log = started
      finished = Struct.new(:output, :ok?).new(output, passed)
      status = Struct.new(:success?, :exitstatus).new(passed, passed ? 0 : 1)
      Hecks::Adapters::ProcessPool.starter = lambda do |command, _env, _chdir|
        log << [File.basename(command[1]), *command.drop(2)]
        Hecks::Adapters::ProcessPool::Finished.new(finished.output, status)
      end
      Hecks::Adapters::RustToolchain.pool = Object.new.tap do |pool|
        pool.define_singleton_method(:run) do |command, **|
          log << [File.basename(command[1]), *command.drop(2)]
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

      out, status = run_verb("fuzz", @shelf, "run=sweep-1", "seeds=4", "steps=6", "adapter=memory")

      expect(status).to eq(0)
      expect(JSON.parse(out).fetch("events")).to eq(["FuzzRequested"])
      expect(started).to eq([["fuzz", @shelf, "--seeds", "4", "--steps", "6", "--adapter", "memory"]])
      row = conclusion_of("sweep-1")
      expect(row.fetch("status")).to eq("concluded")
      expect(row.dig("report", "value")).to start_with("CLEAN")
    end

    it "keeps a sweep that found something as halted, and halted lists it" do
      pool_says("FUZZ FOUND SOMETHING.\n", passed: false)

      run_verb("fuzz", @shelf, "run=sweep-2")

      expect(conclusion_of("sweep-2").fetch("status")).to eq("halted")
      expect(JSON.parse(run_verb("halted").first).map { |sweep| sweep.dig("run", "value") }).to include("sweep-2")
    end

    it "refuses a sweep of zero seeds before anything is asked" do
      pool_says("CLEAN\n")

      out, status = run_verb("fuzz", @shelf, "run=sweep-3", "seeds=0")

      expect(status).to eq(1)
      expect(out).to include("a count is positive")
      expect(started).to be_empty
    end

    it "bench asks the toolchain to measure with the flags it was given, and keeps the report" do
      pool_says("| target | ops/s |\n")

      run_verb("bench", "run=bench-1", "domains=pizzas", "iterations=10", "warmup=0", "runs=1", "format=json")

      expect(started).to eq([["bench", "--domain", "pizzas", "--iterations", "10", "--warmup", "0", "--runs", "1",
                              "--format", "json"]])
      expect(conclusion_of("bench-1").dig("report", "value")).to include("ops/s")
    end

    it "generate_sequence answers a replayable script, and writes no journal entry of its own" do
      before = @hecks.registry.event_log.to_a.size

      out, status = run_verb("generate_sequence", @shelf, "seed=2", "steps=4")

      expect(status).to eq(0)
      script = JSON.parse(out)
      expect(script.fetch("name")).to eq("shelf-generated")
      expect(script.fetch("steps")).to all(include("verb"))
      expect(@hecks.registry.event_log.to_a.size).to eq(before)
    end
  end

  def standing_of(url)
    JSON.parse(run_verb("standing", url).first).first
  end

  def capture_stdout
    saved = $stdout
    $stdout = StringIO.new
    yield
  ensure
    $stdout = saved
  end
end
