require "spec_helper"
require "tmpdir"
require "fileutils"
require "json"

# ADR 0080, sections 4 and 7: the Hecks domain attaches the language's chapters, Tenancy and
# Deploy, and the launcher reaches Deploy's verbs as `hecks deploy <verb>`. Each row of the table's
# Deploy section resolves, answers `--help`, and runs the way a client types it, anywhere.
RSpec.describe "the Hecks Deploy table through the launcher" do
  ATTACHED_CHAPTERS = %w[Bluebook Paging Hecksagon World Adapter Port Translation Expression Tenancy Deploy].freeze

  # The five rows of the ADR's Deploy table, then the questions and records around them.
  DEPLOY_ROWS = %w[project lint diff project_oidc provision].freeze
  DEPLOY_RECORDS = %w[rendering unrendered verdict flagged manifest unwritten refused].freeze

  SHOP_BLUEBOOK = <<~RUBY.freeze
    Hecks.bluebook "Shop" do
      aggregate "Thing" do
        identified_by :name
        attribute :name, ThingName
        value_object "ThingName" do
          attribute :value, String
          invariant("named") { !value.to_s.empty? }
        end
        command "Create" do
          attribute :name, ThingName
          sets :name
          emits "ThingCreated"
        end
      end
    end
  RUBY

  SHOP_WORLD = <<~RUBY.freeze
    Hecks.world "Shop" do
      deployed_to("AwsLambda") do
        region "us-east-1"
      end
    end
  RUBY

  SHOP_HECKSAGON = <<~RUBY.freeze
    Hecks.hecksagon "Shop" do
      persisted_by "Memory"
    end
  RUBY

  before(:all) do
    @dir = Dir.mktmpdir("deploy_table")
    write("shop/bluebook/shop.bluebook", SHOP_BLUEBOOK)
    write("shop/bluebook/shop.world", SHOP_WORLD)
    write("shop/bluebook/shop.hecksagon", SHOP_HECKSAGON)
    write("nodeploy/bluebook/nodeploy.bluebook", SHOP_BLUEBOOK.sub('"Shop"', '"Nodeploy"'))
    write("nodeploy/bluebook/nodeploy.world", "Hecks.world \"Nodeploy\" do\n  realm \"Nodeploy\"\nend\n")
    write("nodeploy/bluebook/nodeploy.hecksagon", SHOP_HECKSAGON.sub('"Shop"', '"Nodeploy"'))
    write("before.yaml", "Resources:\n  Fn:\n    Type: AWS::Lambda::Function\n    Properties:\n      MemorySize: 128\n")
    write("after.yaml", "Resources:\n  Fn:\n    Type: AWS::Lambda::Function\n    Properties:\n      MemorySize: 256\n")
    @hecks = Hecks.boot(File.join(InMemoryDomain::ROOT, "lib/hecks/hecks"), install_facade: false)
  end

  after(:all) { FileUtils.rm_rf(@dir) }

  def write(path, text)
    full = File.join(@dir, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, text)
  end

  def run_verb(*argv)
    Hecks::Facade::CliRunner.call(runtime: @hecks, argv: ["deploy", *argv], program: "hecks")
  end

  def in_dir(&) = Dir.chdir(@dir, &)

  def row(*argv) = JSON.parse(run_verb(*argv).first).first

  describe "the attached chapters" do
    it "holds the language, Tenancy and Deploy beside the Hecks chapter" do
      expect(@hecks.registry.bluebooks.keys).to include("Hecks", *ATTACHED_CHAPTERS)
    end

    it "never attaches the grammar's Translation chapter" do
      translation = @hecks.registry.bluebook("Translation")

      expect(translation.aggregates.map(&:hecks_name)).to include("Translation")
      expect(translation.aggregates.map(&:hecks_name)).not_to include("Rule")
    end

    (ATTACHED_CHAPTERS - ["Paging"]).each do |chapter|
      it "routes `hecks #{Hecks::Naming.snake(chapter)} --help` to the #{chapter} chapter" do
        out, status = Hecks::Facade::CliRunner.call(runtime: @hecks, argv: [Hecks::Naming.snake(chapter), "--help"],
                                                    program: "hecks")

        expect(status).to eq(0)
        expect(out).to start_with(chapter)
      end
    end
  end

  (DEPLOY_ROWS + DEPLOY_RECORDS).each do |verb|
    it "answers `hecks deploy #{verb} --help`" do
      out, status = run_verb(verb, "--help")

      expect(status).to eq(0)
      expect(out).to start_with(verb)
    end
  end

  describe "the ADR rows, as a client types them" do
    it "project renders the recipe and keeps the files it wrote" do
      out, status = run_verb("project", File.join(@dir, "shop"), "run=proj-1", "out=#{File.join(@dir, 'recipe')}")

      expect(status).to eq(0)
      expect(JSON.parse(out).fetch("events")).to eq(["RecipeRequested"])
      kept = row("rendering", "proj-1")
      expect(kept.fetch("status")).to eq("rendered")
      expect(kept.dig("target", "value")).to eq("AwsLambda")
      expect(File.read(File.join(@dir, "recipe/Makefile"))).to include("deploy")
    end

    it "project holds back a domain that declares no deploy target, and writes nothing" do
      out, = run_verb("project", File.join(@dir, "nodeploy"), "run=proj-2", "out=#{File.join(@dir, 'none')}")

      expect(JSON.parse(out).fetch("refused_reactions").first.fetch("reason"))
        .to include("deployed_to(\"AwsLambda\") or deployed_to(\"AwsFargate\")")
      kept = row("rendering", "proj-2")
      expect(kept.fetch("status")).to eq("requested")
      expect(File.exist?(File.join(@dir, "none"))).to be false
    end

    it "project keeps a domain with no world file as a faulted rendering" do
      run_verb("project", File.join(@dir, "nowhere"), "run=proj-5")

      expect(row("rendering", "proj-5").fetch("status")).to eq("faulted")
      expect(row("unrendered").dig("refusal", "value")).to include("nowhere.world does not exist")
    end

    it "project refuses a schema given with no tenant, before anything is recorded" do
      out, status = run_verb("project", File.join(@dir, "shop"), "run=proj-3", "schema=acme")

      expect(status).to eq(1)
      expect(out).to include("a schema names the tenant it scopes")
      expect(run_verb("rendering", "proj-3").first).not_to include("proj-3")
    end

    it "project --wait exits 1 for a rendering held back or faulted" do
      held = run_verb("project", File.join(@dir, "nodeploy"), "run=proj-4", "--wait")
      faulted = run_verb("project", File.join(@dir, "nowhere"), "run=proj-6", "--wait")

      expect(held.last).to eq(1)
      expect(faulted.last).to eq(1)
      expect(JSON.parse(faulted.first).dig("state", "status")).to eq("faulted")
    end

    it "project names the run it minted when none is given" do
      out, = run_verb("project", File.join(@dir, "shop"), "out=#{File.join(@dir, 'minted')}")

      minted = JSON.parse(out).fetch("run")
      expect(row("rendering", minted).fetch("status")).to eq("rendered")
    end

    it "lint renders the fixture domains and keeps a clean verdict" do
      run_verb("lint", "run=lint-1")

      kept = row("verdict", "lint-1")
      expect(kept.fetch("status")).to eq("clean")
      expect(kept.dig("report", "value")).to eq("no violations found")
    end

    it "lint flags a Makefile that hides a failure, and keeps every violation" do
      write("bad/Makefile", "mint-era:\n\t@aws cloudformation describe-stacks --stack-name x >/dev/null; \\\n\texit 0\n")
      run_verb("lint", "run=lint-2", "makefiles=#{File.join(@dir, 'bad/Makefile')}")

      kept = row("verdict", "lint-2")
      expect(kept.fetch("status")).to eq("flagged")
      expect(kept.dig("refusal", "value")).to include("UNVERIFIED_EXIT_ZERO")
      expect(JSON.parse(run_verb("flagged").first).map { |r| r.dig("run", "value") }).to include("lint-2")
    end

    it "diff answers what differs between two templates, as text or JSON" do
      out, status = run_verb("diff", "before=#{File.join(@dir, 'before.yaml')}", "after=#{File.join(@dir, 'after.yaml')}")

      expect(status).to eq(0)
      expect(out).to include("Fn")
      json, = run_verb("diff", "before=#{File.join(@dir, 'before.yaml')}", "after=#{File.join(@dir, 'after.yaml')}", "--json")
      expect(JSON.parse(json).fetch("different")).to be true
    end

    it "diff says nothing differs for a template held against itself, and refuses one that is missing" do
      same = File.join(@dir, "before.yaml")
      json, = run_verb("diff", "before=#{same}", "after=#{same}", "--json", "--strict")
      out, status = run_verb("diff", "before=#{same}", "after=#{File.join(@dir, 'gone.yaml')}")

      expect(JSON.parse(json).fetch("different")).to be false
      expect(status).to eq(1)
      expect(out).to include("gone.yaml")
    end

    it "project_oidc writes an oidc.json beside each domain it names" do
      in_dir { run_verb("project_oidc", "run=oidc-1", "domains=shop") }

      kept = row("manifest", "oidc-1")
      expect(kept.fetch("status")).to eq("written")
      expect(kept.dig("report", "value")).to include("shop/oidc.json  <-  Shop")
      expect(File.exist?(File.join(@dir, "shop/oidc.json"))).to be true
    end

    it "project_oidc keeps a domain it cannot find as a stopped projection" do
      in_dir { run_verb("project_oidc", "run=oidc-2", "domains=nowhere") }

      expect(row("manifest", "oidc-2").fetch("status")).to eq("stopped")
      expect(JSON.parse(run_verb("unwritten").first).map { |r| r.dig("run", "value") }).to include("oidc-2")
    end

    it "provision writes the tenant's overlay, boots the domain under it, and registers the tenant" do
      out, status = run_verb("provision", File.join(@dir, "shop/bluebook"), "slug=acme", "domain=Shop", "realm=Acme",
                             "schema=acme", "database=shop", "adapter=Memory", "--wait")

      expect(status).to eq(0), out
      overlay = File.read(File.join(@dir, "shop/bluebook/environments/acme.world"))
      expect(overlay).to include('realm "Acme"', 'schema   "acme"')
      active = JSON.parse(Hecks::Facade::CliRunner.call(runtime: @hecks, argv: %w[tenancy active], program: "hecks").first)
      expect(active.map { |tenant| tenant.dig("slug", "value") }).to include("acme")
    end

    it "provision keeps a directory that does not exist as a refused tenant" do
      out, status = run_verb("provision", File.join(@dir, "gone"), "slug=lost", "domain=Shop", "realm=Lost",
                             "schema=lost", "database=shop", "--wait")

      expect(status).to eq(1)
      expect(JSON.parse(out).dig("state", "status")).to eq("refused")
      expect(row("refused").dig("refusal", "value")).to include("no such domain directory")
    end

    it "provision refuses a slug that is not lowercase" do
      out, status = run_verb("provision", File.join(@dir, "shop/bluebook"), "slug=Acme", "domain=Shop",
                             "realm=Acme", "schema=acme", "database=shop")

      expect(status).to eq(1)
      expect(out).to include("must match")
    end
  end
end
