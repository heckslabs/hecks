require "spec_helper"
require "tmpdir"
require "fileutils"
require "json"
require "socket"

# ADR 0080, section 7: every row of the command table resolves in the launcher. Each verb of
# Custodian's Introspection, Operation, Host and Package (and the ModelCheck the table puts beside
# them) answers
# `--help`, and the journaled ones are then run the way `hecks <verb>` runs them.
RSpec.describe "the Hecks command table through the launcher" do
  # Introspection's queries and the verbs of ModelCheckRun and Operation, as the launcher spells
  # them.
  CUSTODIAN_VERBS = %w[
    ir shape stores history statements narrate docs project_diagrams glossary
    model_check verdict flagged
    run refresh_projections run_behaviors open_console smoke_test smoke_http outcome failed follow
    check_era recheck standing drifted
    vendor revendor pinning unpinned
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
      expect(out).to start_with(verb)
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
