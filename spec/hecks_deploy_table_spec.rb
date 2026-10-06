require "spec_helper"
require "json"
require "tmpdir"
require "hecks/tools"
require "hecks/tools/tools_doc"
require_relative "support/fake_codebase_shell"

# ADR 0080, section 7: the Deploy rows of the command table. The Deploy chapter is attached to the
# Hecks domain, so each row is `hecks deploy <verb>`. This spec lists every row and checks that the
# command is declared in the Deploy chapter, that its verb answers `--help` through the launcher,
# and that the launcher's form is the one the 2.10 notices promise. It then runs the commands whose
# whole effect can be seen in a temporary directory: a comparison of two templates, and a tenant's
# provisioning.
RSpec.describe "the Deploy rows of the ADR command table" do
  DeployRow = Struct.new(:script, :aggregate, :name, :verb, keyword_init: true) do
    # The launcher's name for the row: its aggregate, snake-cased, then its verb.
    def qualified = "#{aggregate.gsub(/([a-z])([A-Z])/, '\1_\2').downcase}.#{verb}"
  end

  DEPLOY_ROWS = [
    DeployRow.new(script: "project_deploy", aggregate: "Recipe", name: "Project", verb: "project"),
    DeployRow.new(script: "lint_deploy_recipes", aggregate: "MakefileCheck", name: "Lint", verb: "lint"),
    DeployRow.new(script: "deploy_template_diff", aggregate: "TemplateComparison", name: "Diff", verb: "diff"),
    DeployRow.new(script: "project_oidc", aggregate: "OidcManifest", name: "ProjectOidc", verb: "project_oidc"),
    DeployRow.new(script: "project_tenant", aggregate: "Tenant", name: "Provision", verb: "provision"),
    DeployRow.new(script: "project_tenant", aggregate: "Tenant", name: "Reprovision", verb: "reprovision")
  ].freeze

  before(:all) do
    @hecks = Hecks.boot(File.join(InMemoryDomain::ROOT, "lib/hecks/hecks"), install_doors: false)
    @bluebook = @hecks.registry.bluebook("Deploy")
  end

  after do
    Hecks::Adapters::Codebase::Tree.root = nil
  end

  # Routes the tools the toolchain runs in this process to a fake that answers what it was given.
  def stub_tools(shell)
    allow(Hecks::Tools).to receive(:run, &shell.method(:run_tool))
  end

  def launch(argv)
    Hecks::Doors::CliRunner.call(runtime: @hecks, argv: ["deploy", *argv], program: "hecks")
  end

  def answer(argv)
    out, status = launch(argv)
    [JSON.parse(out), status]
  end

  DEPLOY_ROWS.each do |row|
    it "answers #{row.script} as #{row.aggregate}.#{row.name}, `hecks deploy #{row.qualified}`" do
      aggregate = @bluebook.aggregate(row.aggregate)

      expect(aggregate).not_to be_nil, "#{row.aggregate} is not declared in the Deploy chapter"
      expect(aggregate.commands.map(&:hecks_name)).to include(row.name)

      out, status = launch([row.qualified, "--help"])

      expect(status).to eq(0)
      expect(out).to start_with(row.qualified)
    end
  end

  it "names, for every script it replaces, the form the 2.10 notice promises" do
    forms = Hecks::Tools::ToolsDoc.forms(root: InMemoryDomain::ROOT)
    DEPLOY_ROWS.map(&:script).uniq.each do |script|
      expect(forms.fetch(script)).to start_with("hecks deploy ")
    end
    promised = DEPLOY_ROWS.map(&:script).uniq.map { |script| forms.fetch(script)[/deploy ([\w.]+)/, 1] }

    expect(promised).to all(satisfy { |verb| DEPLOY_ROWS.map(&:qualified).include?(verb) })
  end

  it "lists every command of the table once, with the Deploy aggregates each holding a row" do
    expect(DEPLOY_ROWS.map { |row| [row.aggregate, row.name] }.uniq.size).to eq(DEPLOY_ROWS.size)
    expect(DEPLOY_ROWS.map(&:verb).uniq.size).to eq(DEPLOY_ROWS.size)
    expect(DEPLOY_ROWS.map(&:aggregate).uniq).to match_array(%w[Recipe MakefileCheck TemplateComparison OidcManifest Tenant])
  end

  it "keeps the deployed_to targets beside the new commands, and Provision the only Tenant creator" do
    expect(@bluebook.aggregate("LambdaTarget").commands.map(&:hecks_name)).to eq(["Declare"])
    expect(@bluebook.aggregate("FargateTarget").commands.map(&:hecks_name)).to eq(["Declare"])
    expect(@bluebook.aggregate("BoxTarget").commands.map(&:hecks_name)).to eq(["Declare"])
    tenant = @bluebook.aggregate("Tenant").commands
    expect(tenant.map(&:hecks_name)).not_to include("Declare")
    expect(tenant.select(&:creates?).map(&:hecks_name)).to eq(["Provision"])
  end

  it "keeps the TenantProvisioning port on Tenant" do
    port = @bluebook.aggregate("Tenant").ports.find { |candidate| candidate.name == "TenantProvisioning" }

    expect(port).not_to be_nil
    expect(port.operations.map(&:hecks_name)).to eq(["WriteOverlay"])
  end

  describe "hecks deploy diff" do
    def write_templates(dir)
      File.write(File.join(dir, "a.yaml"), "Resources:\n  Bucket:\n    Type: AWS::S3::Bucket\n")
      File.write(File.join(dir, "b.yaml"),
                 "Resources:\n  Bucket:\n    Type: AWS::S3::Bucket\n    Properties:\n      BucketName: x\n")
    end

    it "records two templates that agree as matching, and exits 0 under --wait" do
      Dir.mktmpdir("deploy_diff") do |dir|
        write_templates(dir)
        json, status = answer(["template_comparison.diff", File.join(dir, "a.yaml"), "after=#{File.join(dir, "a.yaml")}",
                               "--wait"])

        expect(status).to eq(0)
        expect(json.dig("state", "status")).to eq("matching")
        expect(json.dig("state", "report", "value")).to eq("no differences\n")
        expect(json.fetch("events")).to eq(%w[ComparisonRequested ComparisonAnswered TemplatesMatched])
        # The Drift half of the given-gated pair declines by design: shown, but not a failure.
        expect(json.fetch("refused_reactions").map { |r| r["reason"] }).to all(include("Drift refused"))
      end
    end

    it "records templates that differ as drifted, and exits 1 under --wait" do
      Dir.mktmpdir("deploy_diff") do |dir|
        write_templates(dir)
        json, status = answer(["template_comparison.diff", File.join(dir, "a.yaml"), "after=#{File.join(dir, "b.yaml")}",
                               "--wait"])

        expect(status).to eq(1)
        expect(json.dig("state", "status")).to eq("drifted")
        expect(json.dig("state", "report", "value")).to include("~ Bucket (AWS::S3::Bucket)", "BucketName")
        expect(json.fetch("events")).to eq(%w[ComparisonRequested ComparisonAnswered TemplatesDrifted])
      end
    end

    it "writes the report as JSON with --json" do
      Dir.mktmpdir("deploy_diff") do |dir|
        write_templates(dir)
        json, = answer(["template_comparison.diff", File.join(dir, "a.yaml"), "after=#{File.join(dir, "b.yaml")}", "--json",
                        "--wait"])

        report = JSON.parse(json.dig("state", "report", "value"))

        expect(report.fetch("different")).to be(true)
      end
    end

    it "records a template that is not there as refused, and exits 1 under --wait" do
      json, status = answer(["template_comparison.diff", "/no/such/before.yaml", "after=/no/such/after.yaml", "--wait"])

      expect(status).to eq(1)
      expect(json.dig("state", "status")).to eq("refused")
      expect(json.dig("state", "refusal", "value")).to include("does not exist")
    end
  end

  describe "hecks deploy provision" do
    def provision(dir, *extra)
      answer(["tenant.provision", dir, "slug=acme", "domain=Scratch", "realm=Acme", "schema=acme",
              "database=hecks_tenants", *extra, "--wait"])
    end

    it "writes the tenant's overlay world, records it provisioned and registers it in Tenancy" do
      Dir.mktmpdir("deploy_tenant") do |dir|
        json, status = provision(dir)

        expect(status).to eq(0)
        expect(json.dig("state", "status")).to eq("provisioned")
        expect(json.fetch("events")).to eq(%w[TenantProvisionRequested TenantProvisioned TenantRecorded])
        expect(json.dig("state", "output", "value")).to eq("wrote #{File.join(dir, "environments/acme.world")}\n")

        overlay = File.read(File.join(dir, "environments/acme.world"))
        expect(overlay).to include('realm "Acme"', 'persisted_by("PostgresEra")', 'database "hecks_tenants"')

        tenants = @hecks.registry.repository("Tenancy", @hecks.registry.bluebook("Tenancy").aggregate("Tenant"))
        expect(tenants.find("acme")).not_to be_nil
      end
    end

    it "binds the adapter it is named" do
      Dir.mktmpdir("deploy_tenant") do |dir|
        answer(["tenant.provision", dir, "slug=bloom", "domain=Scratch", "realm=Bloom", "schema=bloom",
                "database=hecks_tenants", "adapter=Sqlite", "--wait"])

        expect(File.read(File.join(dir, "environments/bloom.world"))).to include('persisted_by("Sqlite")')
      end
    end

    it "refuses a slug that is not lowercase before it writes anything" do
      Dir.mktmpdir("deploy_tenant") do |dir|
        out, status = launch(["tenant.provision", dir, "slug=Not_A_Slug", "domain=Scratch", "realm=Acme", "schema=acme",
                              "database=hecks_tenants"])

        expect(status).to eq(1)
        expect(out).to include("must match")
        expect(Dir.exist?(File.join(dir, "environments"))).to be(false)
      end
    end

    it "provisions a slug whose declaration was only validated by a dry run" do
      Dir.mktmpdir("deploy_tenant") do |dir|
        facts = { slug: { value: "declared" }, domain: { value: "Scratch" }, realm: { value: "Declared" },
                  schema: { value: "declared" }, database: { value: "hecks_tenants" },
                  directory: { value: dir } }
        expect(@hecks.dry_run?("Deploy::Tenant.Provision", **facts)).to be(true)
        json, status = answer(["tenant.provision", dir, "slug=declared", "domain=Scratch", "realm=Declared",
                               "schema=declared", "database=hecks_tenants", "--wait"])

        expect(status).to eq(0)
        expect(json.dig("state", "status")).to eq("provisioned")
        expect(File.read(File.join(dir, "environments/declared.world"))).to include('realm "Declared"')
      end
    end

    it "refuses to provision the same slug twice, and points at `reprovision`" do
      Dir.mktmpdir("deploy_tenant") do |dir|
        args = ["tenant.provision", dir, "slug=twice", "domain=Scratch", "realm=Twice", "schema=twice",
                "database=hecks_tenants", "--wait"]
        answer(args)
        out, status = launch(args)

        expect(status).to eq(1)
        expect(out).to include("already")
      end
    end

    it "writes the overlay again for a tenant that was provisioned, under `reprovision`" do
      Dir.mktmpdir("deploy_tenant") do |dir|
        answer(["tenant.provision", dir, "slug=again", "domain=Scratch", "realm=Again", "schema=again",
                "database=hecks_first", "--wait"])
        json, status = answer(["tenant.reprovision", "to=again", "directory=#{dir}", "database=hecks_second", "--wait"])

        expect(status).to eq(0)
        expect(json.dig("state", "status")).to eq("provisioned")
        expect(File.read(File.join(dir, "environments/again.world"))).to include('database "hecks_second"')
      end
    end
  end

  describe "hecks deploy project, lint and project_oidc" do
    it "asks the generator for a domain, with each flag it was given, and keeps what it wrote" do
      shell = FakeCodebaseShell.new("wrote deploy/pizzas/template.yaml\n")
      stub_tools(shell)

      json, status = answer(["recipe.project", "examples/pizzas", "tenant=acme", "schema=acme", "out=/tmp/pizzas-out",
                             "environment=production", "--wait"])

      expect(status).to eq(0)
      expect(json.dig("state", "status")).to eq("projected")
      expect(json.dig("state", "output", "value")).to eq("wrote deploy/pizzas/template.yaml\n")
      expect(shell.command.drop(1)).to eq(%w[--tenant=acme --schema=acme --out=/tmp/pizzas-out
                                             --environment=production examples/pizzas])
    end

    it "keeps a generator that refused as a faulted recipe with its own sentence, and exits 1 under --wait" do
      stub_tools(FakeCodebaseShell.new(["no deployed_to block", 1]))

      json, status = answer(["recipe.project", "examples/pizzas", "--wait"])

      expect(status).to eq(1)
      expect(json.dig("state", "status")).to eq("faulted")
      expect(json.dig("state", "refusal", "value")).to include("no deployed_to block")
    end

    it "keeps a Makefile that hides a failure as a flagged lint, and exits 1 under --wait" do
      stub_tools(FakeCodebaseShell.new(["1 violation(s) found", 1]))

      json, status = answer(["makefile_check.lint", "makefiles=deploy/pizzas/Makefile", "--wait"])

      expect(status).to eq(1)
      expect(json.dig("state", "status")).to eq("flagged")
    end

    it "records clean Makefiles as a clean lint" do
      shell = FakeCodebaseShell.new("hecks deploy lint: no violations found.\n")
      stub_tools(shell)

      json, status = answer(["makefile_check.lint", "makefiles=a/Makefile,b/Makefile", "--wait"])

      expect(status).to eq(0)
      expect(json.dig("state", "status")).to eq("clean")
      expect(shell.command.drop(1)).to eq(%w[a/Makefile b/Makefile])
    end

    it "projects the manifests of the domains it is named" do
      shell = FakeCodebaseShell.new("  examples/banking/oidc.json  <-  Banking\n")
      stub_tools(shell)

      json, status = answer(["oidc_manifest.project_oidc", "examples/banking", "--wait"])

      expect(status).to eq(0)
      expect(json.dig("state", "status")).to eq("projected")
      expect(shell.command.drop(1)).to eq(%w[examples/banking])
    end

    it "refuses the lint outside a hecks checkout, where the generators are not" do
      Dir.mktmpdir("not_a_checkout") do |dir|
        Dir.mkdir(File.join(dir, "lib"))
        Hecks::Adapters::Codebase::Tree.root = dir

        json, status = answer(["makefile_check.lint", "makefiles=deploy/pizzas/Makefile", "--wait"])

        expect(status).to eq(1)
        expect(json.dig("state", "refusal", "value")).to include("needs a hecks checkout")
      end
    end

    it "generates a recipe for a project beside the cwd, from an installed gem with no checkout" do
      Dir.mktmpdir("installed_gem") do |scratch|
        gem_dir = File.join(scratch, "gem")
        project = File.join(scratch, "client_#{rand(1_000_000)}")
        FileUtils.mkdir_p(File.join(gem_dir, "lib"))
        FileUtils.cp_r(File.join(InMemoryDomain::ROOT, "examples/pizzas"), project)
        File.write(File.join(project, "bluebook/pizzas.world"), <<~RUBY)
          Hecks.world "Pizzas" do
            realm "Examples"
            deployed_to("AwsLambda") do
              region "us-east-1"
              memory 512
              timeout 10
            end
          end
        RUBY
        Hecks::Adapters::Codebase::Tree.root = gem_dir

        Dir.chdir(scratch) do
          json, status = answer(["recipe.project", File.basename(project), "out=generated_recipe", "--wait"])

          expect(json.dig("state", "refusal", "value")).to be_nil
          expect(status).to eq(0)
          expect(json.dig("state", "status")).to eq("projected")
        end
        expect(File.file?(File.join(scratch, "generated_recipe/template.yaml"))).to be(true)
        expect(File.read(File.join(scratch, "generated_recipe/Makefile"))).to include("ROOT      := #{File.realpath(scratch)}")
      end
    end
  end
end
