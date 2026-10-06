require "spec_helper"
require "json"
require "tmpdir"
require "fileutils"

# The opt-in launcher features the Hecks chapter's world switches on: generated run keys,
# launcher names, `--wait`, and the constant rule of the chapter's hecksagon build.
RSpec.describe "the launcher's opt-in options" do
  SHELF = <<~RUBY.freeze
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

  CHAPTER_AGGREGATE = 'description "x"; attribute :tag, Tag; identified_by :tag; ' \
                      'value_object("Tag") { attribute :value, String }; command("Go") { emits Went }'.freeze

  before(:all) do
    @dir = Dir.mktmpdir("launcher_options")
    write("shelf/bluebook/shelf.bluebook", SHELF)
    write("shelf/bluebook/shelf.hecksagon", "Hecks.hecksagon \"Shelf\" do\n  persisted_by \"Memory\"\nend\n")
    write("clean/bluebook/clean.bluebook", SHELF.sub('"Shelf"', '"Clean"').sub(/    lifecycle.*?    end\n\n/m, ""))
    write("clean/bluebook/clean.hecksagon", "Hecks.hecksagon \"Clean\" do\n  persisted_by \"Memory\"\nend\n")
    @hecks = Hecks.boot(File.join(InMemoryDomain::ROOT, "lib/hecks/hecks"), install_doors: false)
  end

  after(:all) { FileUtils.rm_rf(@dir) }

  def write(path, text)
    full = File.join(@dir, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, text)
  end

  def hecks_spec(command)
    cli = Hecks::Projector.call(:cli, bluebook: @hecks.registry.bluebook("Hecks"),
                                      options:  { program: "hecks", mint_run_keys: true })
    cli[:commands].fetch(cli[:names][:command].fetch(command))
  end

  def run_verb(*argv) = Hecks::Doors::CliRunner.call(runtime: @hecks, argv: argv, program: "hecks")

  describe "run keys" do
    it "mints the key of a creating command given none, and answers it", :aggregate_failures do
      out, status = run_verb("model_check_run.model_check", "domains=#{File.join(@dir, "clean")}")
      key = JSON.parse(out).fetch("run")

      expect(status).to eq(0)
      expect(key).not_to be_empty
      expect(JSON.parse(run_verb("query", "model_check_run.verdict", key).first).first.dig("run", "value")).to eq(key)
    end

    it "refuses, saying to name a key, when no identity adapter can mint one" do
      allow(Hecks::Ports::IdentityGeneration).to receive(:uuid)
        .and_raise(Hecks::Runtime::WiringError, "no identity adapter bound")
      spec = { creates: true, arguments: [{ path: "run.value" }] }

      expect { Hecks::Doors::LauncherOptions.run_key(@hecks, spec, {}, { run_keys: true }) }
        .to raise_error(Hecks::Runtime::NotFound, /cannot mint a run key.*run=<key>/)
    end

    it "never fills the minted run key from a bare word, and says so", :aggregate_failures do
      out, status = run_verb("conformance_run.check_engine_agreement", "bogus")

      expect(status).to eq(1)
      expect(out).to include("only argument is its run key", "run=<key>")
    end

    it "shows the minted run key as optional in help, and fills the next argument from a bare word", :aggregate_failures do
      help, = run_verb("operation.run_behaviors", "--help")

      expect(help).to match(/run\.value\s+.*minted when omitted; optional/)
      expect(Hecks::Doors::CliDoor.arguments(hecks_spec("operation.run_behaviors"), ["examples/banking"]))
        .to eq(subject: { value: "examples/banking" })
    end

    it "keeps an explicit key", :aggregate_failures do
      out, = run_verb("model_check_run.model_check", "run=mine-1", "domains=#{File.join(@dir, "clean")}")

      expect(JSON.parse(out)).not_to have_key("run")
      expect(JSON.parse(run_verb("query", "model_check_run.verdict", "mine-1").first).first.dig("run", "value")).to eq("mine-1")
    end

    it "leaves a chapter that did not opt in alone" do
      runtime = boot_in_memory
      expect(Hecks::Doors::LauncherOptions.settings(runtime, "Pizzas")).to be_nil
    end
  end

  describe "names" do
    it "lists the command by its real name, and says the alias", :aggregate_failures do
      help = run_verb.first

      expect(help).to match(/^\s+serve_mcp! .*\(also: mcp!\)/)
      expect(help).to match(/^\s+open_console! .*\(also: console!\)/)
    end

    it "keeps both spellings working", :aggregate_failures do
      expect(run_verb("door.serve_mcp", "--help").first).to include("dispatches")
      expect(run_verb("serve_mcp", "--help").first).to include("no such command: serve_mcp", "door.serve_mcp")
      expect(run_verb("mcp", "--help").first).to start_with("mcp")
    end

    it "resolves the qualified names the ten words clients already typed now stand for, and the two aliases" do
      %w[operation.run introspection.docs introspection.narrate introspection.ir introspection.stores
         model_check_run.model_check operation.smoke_test introspection.project_diagrams door.project_cli
         mcp console].each do |name|
        expect(run_verb(name, "--help")[1]).to eq(0), name
      end
    end

    it "refuses the bare words that were once commands", :aggregate_failures do
      %w[run model_check smoke_test project_cli].each do |name|
        out, status = run_verb(name, "--help")
        expect(status).to eq(1), name
        expect(out).to include("no such command: #{name}")
      end
    end

    it "refuses a launcher name another command already has" do
      specs = { "a.go" => { short: "go" }, "a.stop" => { short: "stop" } }

      expect { Hecks::Projector::CliProjector.rename(specs, "stop" => "go") }
        .to raise_error(Hecks::Bluebook::DSL::Malformed, /already a command/)
    end
  end

  describe "--wait" do
    def take_wait(spec, argv) = Hecks::Doors::LauncherOptions.take_wait(spec, argv)

    it "exits 1 when the check is flagged, and prints the final state", :aggregate_failures do
      out, status = run_verb("model_check_run.model_check", "run=wait-1", "domains=#{File.join(@dir, "shelf")}", "--wait")

      expect(status).to eq(1)
      expect(JSON.parse(out).dig("state", "status")).to eq("flagged")
    end

    it "exits 0 when the check is clean", :aggregate_failures do
      out, status = run_verb("model_check_run.model_check", "run=wait-2", "domains=#{File.join(@dir, "clean")}", "--wait")

      expect(status).to eq(0)
      expect(JSON.parse(out).dig("state", "status")).to eq("clean")
    end

    it "exits 1 for a refused request", :aggregate_failures do
      out, status = run_verb("model_check_run.model_check", "run=wait-3", "profile=strictest", "--wait")

      expect(status).to eq(1)
      expect(out).to include("must match")
    end

    it "makes a question fail when its refusal or its report names a gap", :aggregate_failures do
      text, status = run_verb("ask", "build.rust_coverage", "module_name=nosuchmodule", "--wait")

      expect(status).to eq(1)
      expect(text).to include("no such generated module")
    end

    it "reads a `GAP (n)` heading above zero as a gap, and nothing else", :aggregate_failures do
      gap = Hecks::Doors::LauncherOptions.method(:gap_reported?)

      expect(gap.call("GAP (2) — missing, and NOT on the allowlist")).to be(true)
      expect(gap.call("\nGAP (0) — missing, and NOT on the allowlist")).to be(false)
      expect(gap.call(nil)).to be(false)
    end

    it "accepts --wait=true, --wait=false and --wait yes, and refuses --wait=maybe", :aggregate_failures do
      spec = { arguments: [] }

      expect(take_wait(spec, ["--wait=true", "x=1"])).to eq([["x=1"], true])
      expect(take_wait(spec, ["--wait=false"])).to eq([[], false])
      expect(take_wait(spec, ["--wait", "yes"])).to eq([[], true])
      expect { take_wait(spec, ["--wait=maybe"]) }.to raise_error(Hecks::Runtime::TypeMismatch, /not Boolean/)
    end

    it "is left to a command that declares its own wait argument" do
      spec = { arguments: [{ path: "wait", type: "Integer" }] }

      expect(Hecks::Doors::LauncherOptions.take_wait(spec, ["--wait"])).to eq([["--wait"], false])
    end
  end

  describe "chapter constants" do
    def declare_hecks_chapter(names)
      aggregates = names.map { |name| "aggregate(\"#{name}\") { #{CHAPTER_AGGREGATE} }" }
      Hecks.bluebook("Hecks") do
        namespace "Hecks::Domain"
        instance_eval(aggregates.join("\n"))
      end
    end

    def build_hecks_chapter(*names)
      registry = Hecks::Runtime::Registry.new
      Hecks.with_registry(registry) do
        declare_hecks_chapter(names)
        seen = {}
        Hecks::Bluebook::DSL::HecksagonBuilder.build("Hecks") do
          names.each { |name| seen[name] = Hecks.const_get(name) }
        end
        seen
      end
    end

    it "resolves a colliding name to the chapter's aggregate, and restores the module", :aggregate_failures do
      modules = [Hecks::Release, Hecks::Fuzzing]
      seen = build_hecks_chapter("Fuzzing", "Release")

      expect(seen.values).to all(be_a(Hecks::Bluebook::DSL::BindingProxy))
      expect([Hecks::Release, Hecks::Fuzzing]).to eq(modules)
    end
  end
end
