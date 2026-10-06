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

  DEPLOY_SPEC_LAMBDA_WORLD = <<~RUBY.freeze
    Hecks.world "Pizzas" do
      realm "Examples"
      deployed_to("AwsLambda") do
        region "us-east-1"
        memory 512
        timeout 10
      end
    end
  RUBY

  before(:all) do
    @hecks = Hecks.boot(File.join(InMemoryDomain::ROOT, "lib/hecks/hecks"), install_doors: false)
    @bluebook = @hecks.registry.bluebook("Deploy")
  end

  after do
    Hecks::Adapters::Codebase::Tree.root = nil
  end

  # A scratch directory for each example, named by `dir` in the groups that write files.
  around do |example|
    Dir.mktmpdir("deploy_table") do |scratch|
      @dir = scratch
      example.run
    end
  end

  attr_reader :dir

  # Routes the tools the toolchain runs in this process to a fake that answers what it was given.
  def stub_tools(shell)
    allow(Hecks::Tools).to receive(:run, &shell.method(:run_tool))
  end

  def stubbed_shell(reply) = FakeCodebaseShell.new(reply).tap { |shell| stub_tools(shell) }

  def launch(argv)
    Hecks::Doors::CliRunner.call(runtime: @hecks, argv: ["deploy", *argv], program: "hecks")
  end

  def answer(argv)
    out, status = launch(argv)
    [JSON.parse(out), status]
  end

  DEPLOY_ROWS.each do |row|
    it "answers #{row.script} as #{row.aggregate}.#{row.name}, `hecks deploy #{row.qualified}`", :aggregate_failures do
      aggregate = @bluebook.aggregate(row.aggregate)

      expect(aggregate).not_to be_nil, "#{row.aggregate} is not declared in the Deploy chapter"
      expect(aggregate.commands.map(&:hecks_name)).to include(row.name)
    end

    it "answers `hecks deploy #{row.qualified} --help` for #{row.script}", :aggregate_failures do
      out, status = launch([row.qualified, "--help"])

      expect(status).to eq(0)
      expect(out).to start_with(row.qualified)
    end
  end

  it "names, for every script it replaces, the form the 2.10 notice promises", :aggregate_failures do
    forms = Hecks::Tools::ToolsDoc.forms(root: InMemoryDomain::ROOT)
    promised = DEPLOY_ROWS.map(&:script).uniq.map { |script| forms.fetch(script) }

    expect(promised).to all(start_with("hecks deploy "))
    expect(promised.map { |form| form[/deploy ([\w.]+)/, 1] } - DEPLOY_ROWS.map(&:qualified)).to be_empty
  end

  it "lists every command of the table once, with the Deploy aggregates each holding a row", :aggregate_failures do
    expect(DEPLOY_ROWS.map { |row| [row.aggregate, row.name] }.uniq.size).to eq(DEPLOY_ROWS.size)
    expect(DEPLOY_ROWS.map(&:verb).uniq.size).to eq(DEPLOY_ROWS.size)
    expect(DEPLOY_ROWS.map(&:aggregate).uniq).to match_array(%w[Recipe MakefileCheck TemplateComparison OidcManifest Tenant])
  end

  def command_names(aggregate) = @bluebook.aggregate(aggregate).commands.map(&:hecks_name)

  it "keeps the deployed_to targets beside the new commands, and Provision the only Tenant creator", :aggregate_failures do
    declared = %w[LambdaTarget FargateTarget BoxTarget VercelTarget].map { |t| command_names(t) }
    tenant = @bluebook.aggregate("Tenant").commands

    expect(declared).to all(eq(["Declare"]))
    expect(tenant.map(&:hecks_name)).not_to include("Declare")
    expect(tenant.select(&:creates?).map(&:hecks_name)).to eq(["Provision"])
  end

  it "keeps the TenantProvisioning port on Tenant", :aggregate_failures do
    port = @bluebook.aggregate("Tenant").ports.find { |candidate| candidate.name == "TenantProvisioning" }

    expect(port).not_to be_nil
    expect(port.operations.map(&:hecks_name)).to eq(["WriteOverlay"])
  end

  describe "hecks deploy diff" do
    before do
      File.write(File.join(dir, "a.yaml"), "Resources:\n  Bucket:\n    Type: AWS::S3::Bucket\n")
      File.write(File.join(dir, "b.yaml"),
                 "Resources:\n  Bucket:\n    Type: AWS::S3::Bucket\n    Properties:\n      BucketName: x\n")
    end

    def diff_answer(before, after, *flags)
      answer(["template_comparison.diff", File.join(dir, before), "after=#{File.join(dir, after)}", *flags, "--wait"])
    end

    it "records two templates that agree as matching, and exits 0 under --wait", :aggregate_failures do
      json, status = diff_answer("a.yaml", "a.yaml")

      expect(status).to eq(0)
      expect(json.dig("state", "status")).to eq("matching")
      expect(json.dig("state", "report", "value")).to eq("no differences\n")
    end

    it "shows the events of a matching comparison, and the Drift half declining", :aggregate_failures do
      json, = diff_answer("a.yaml", "a.yaml")

      expect(json.fetch("events")).to eq(%w[ComparisonRequested ComparisonAnswered TemplatesMatched])
      # The Drift half of the given-gated pair declines by design: shown, but not a failure.
      expect(json.fetch("refused_reactions").map { |r| r["reason"] }).to all(include("Drift refused"))
    end

    it "records templates that differ as drifted, and exits 1 under --wait", :aggregate_failures do
      json, status = diff_answer("a.yaml", "b.yaml")

      expect(status).to eq(1)
      expect(json.dig("state", "status")).to eq("drifted")
      expect(json.dig("state", "report", "value")).to include("~ Bucket (AWS::S3::Bucket)", "BucketName")
      expect(json.fetch("events")).to eq(%w[ComparisonRequested ComparisonAnswered TemplatesDrifted])
    end

    it "writes the report as JSON with --json" do
      json, = diff_answer("a.yaml", "b.yaml", "--json")
      report = JSON.parse(json.dig("state", "report", "value"))

      expect(report.fetch("different")).to be(true)
    end

    it "records a template that is not there as refused, and exits 1 under --wait", :aggregate_failures do
      json, status = answer(["template_comparison.diff", "/no/such/before.yaml", "after=/no/such/after.yaml", "--wait"])

      expect(status).to eq(1)
      expect(json.dig("state", "status")).to eq("refused")
      expect(json.dig("state", "refusal", "value")).to include("does not exist")
    end
  end

  describe "hecks deploy provision" do
    def tenant_args(slug, realm:, schema: slug, database: "hecks_tenants", extra: [])
      ["tenant.provision", dir, "slug=#{slug}", "domain=Scratch", "realm=#{realm}", "schema=#{schema}",
       "database=#{database}", *extra]
    end

    # Each slug is provisioned once in the shared Hecks domain, so every example names its own.
    def provision(slug = "acme") = answer(tenant_args(slug, realm: "Acme", extra: ["--wait"]))

    def declared_facts
      { slug: { value: "declared" }, domain: { value: "Scratch" }, realm: { value: "Declared" },
        schema: { value: "declared" }, database: { value: "hecks_tenants" }, directory: { value: dir } }
    end

    it "records the tenant provisioned, with the events and the output of the overlay it wrote", :aggregate_failures do
      json, status = provision

      expect(status).to eq(0)
      expect(json.dig("state", "status")).to eq("provisioned")
      expect(json.fetch("events")).to eq(%w[TenantProvisionRequested TenantProvisioned TenantRecorded])
      expect(json.dig("state", "output", "value")).to eq("wrote #{File.join(dir, "environments/acme.world")}\n")
    end

    it "writes the tenant's overlay world" do
      provision("overlaid")
      overlay = File.read(File.join(dir, "environments/overlaid.world"))

      expect(overlay).to include('realm "Acme"', 'persisted_by("PostgresEra")', 'database "hecks_tenants"')
    end

    it "registers the tenant in Tenancy" do
      provision("registered")
      tenants = @hecks.registry.repository("Tenancy", @hecks.registry.bluebook("Tenancy").aggregate("Tenant"))

      expect(tenants.find("registered")).not_to be_nil
    end

    it "binds the adapter it is named" do
      answer(tenant_args("bloom", realm: "Bloom", extra: ["adapter=Sqlite", "--wait"]))

      expect(File.read(File.join(dir, "environments/bloom.world"))).to include('persisted_by("Sqlite")')
    end

    it "refuses a slug that is not lowercase before it writes anything", :aggregate_failures do
      out, status = launch(tenant_args("Not_A_Slug", realm: "Acme", schema: "acme"))

      expect(status).to eq(1)
      expect(out).to include("must match")
      expect(Dir.exist?(File.join(dir, "environments"))).to be(false)
    end

    it "provisions a slug whose declaration was only validated by a dry run", :aggregate_failures do
      expect(@hecks.dry_run?("Deploy::Tenant.Provision", **declared_facts)).to be(true)
      json, status = answer(tenant_args("declared", realm: "Declared", extra: ["--wait"]))

      expect(status).to eq(0)
      expect(json.dig("state", "status")).to eq("provisioned")
      expect(File.read(File.join(dir, "environments/declared.world"))).to include('realm "Declared"')
    end

    it "refuses to provision the same slug twice, and points at `reprovision`", :aggregate_failures do
      args = tenant_args("twice", realm: "Twice", extra: ["--wait"])
      answer(args)
      out, status = launch(args)

      expect(status).to eq(1)
      expect(out).to include("already")
    end

    it "writes the overlay again for a tenant that was provisioned, under `reprovision`", :aggregate_failures do
      answer(tenant_args("again", realm: "Again", database: "hecks_first", extra: ["--wait"]))
      json, status = answer(["tenant.reprovision", "to=again", "directory=#{dir}", "database=hecks_second", "--wait"])

      expect(status).to eq(0)
      expect(json.dig("state", "status")).to eq("provisioned")
      expect(File.read(File.join(dir, "environments/again.world"))).to include('database "hecks_second"')
    end
  end

  describe "hecks deploy project, lint and project_oidc" do
    def project_pizzas(*flags) = answer(["recipe.project", "examples/pizzas", *flags, "--wait"])

    it "asks the generator for a domain, with each flag it was given", :aggregate_failures do
      shell = stubbed_shell("wrote deploy/pizzas/template.yaml\n")

      project_pizzas("tenant=acme", "schema=acme", "out=/tmp/pizzas-out", "environment=production")

      expect(shell.command.drop(1)).to eq(%w[--tenant=acme --schema=acme --out=/tmp/pizzas-out
                                             --environment=production examples/pizzas])
    end

    it "keeps what the generator wrote", :aggregate_failures do
      stubbed_shell("wrote deploy/pizzas/template.yaml\n")
      json, status = project_pizzas

      expect(status).to eq(0)
      expect(json.dig("state", "status")).to eq("projected")
      expect(json.dig("state", "output", "value")).to eq("wrote deploy/pizzas/template.yaml\n")
    end

    it "keeps a generator that refused as a faulted recipe with its own sentence, and exits 1 under --wait",
       :aggregate_failures do
      stubbed_shell(["no deployed_to block", 1])
      json, status = project_pizzas

      expect(status).to eq(1)
      expect(json.dig("state", "status")).to eq("faulted")
      expect(json.dig("state", "refusal", "value")).to include("no deployed_to block")
    end

    it "keeps a Makefile that hides a failure as a flagged lint, and exits 1 under --wait", :aggregate_failures do
      stubbed_shell(["1 violation(s) found", 1])

      json, status = answer(["makefile_check.lint", "makefiles=deploy/pizzas/Makefile", "--wait"])

      expect(status).to eq(1)
      expect(json.dig("state", "status")).to eq("flagged")
    end

    it "records clean Makefiles as a clean lint", :aggregate_failures do
      shell = stubbed_shell("hecks deploy lint: no violations found.\n")

      json, status = answer(["makefile_check.lint", "makefiles=a/Makefile,b/Makefile", "--wait"])

      expect(status).to eq(0)
      expect(json.dig("state", "status")).to eq("clean")
      expect(shell.command.drop(1)).to eq(%w[a/Makefile b/Makefile])
    end

    it "projects the manifests of the domains it is named", :aggregate_failures do
      shell = stubbed_shell("  examples/banking/oidc.json  <-  Banking\n")

      json, status = answer(["oidc_manifest.project_oidc", "examples/banking", "--wait"])

      expect(status).to eq(0)
      expect(json.dig("state", "status")).to eq("projected")
      expect(shell.command.drop(1)).to eq(%w[examples/banking])
    end

    it "refuses the lint outside a hecks checkout, where the generators are not", :aggregate_failures do
      Dir.mkdir(File.join(dir, "lib"))
      Hecks::Adapters::Codebase::Tree.root = dir

      json, status = answer(["makefile_check.lint", "makefiles=deploy/pizzas/Makefile", "--wait"])

      expect(status).to eq(1)
      expect(json.dig("state", "refusal", "value")).to include("needs a hecks checkout")
    end

    # A project beside the cwd, with the Hecks tree pointed at a gem directory holding no checkout.
    def install_gem_project
      gem_dir = File.join(dir, "gem")
      project = File.join(dir, "client_#{rand(1_000_000)}")
      FileUtils.mkdir_p(File.join(gem_dir, "lib"))
      FileUtils.cp_r(File.join(InMemoryDomain::ROOT, "examples/pizzas"), project)
      File.write(File.join(project, "bluebook/pizzas.world"), DEPLOY_SPEC_LAMBDA_WORLD)
      Hecks::Adapters::Codebase::Tree.root = gem_dir
      project
    end

    def generate_recipe(project)
      Dir.chdir(dir) { answer(["recipe.project", File.basename(project), "out=generated_recipe", "--wait"]) }
    end

    it "generates a recipe for a project beside the cwd, from an installed gem with no checkout", :aggregate_failures do
      json, status = generate_recipe(install_gem_project)

      expect(json.dig("state", "refusal", "value")).to be_nil
      expect(status).to eq(0)
      expect(json.dig("state", "status")).to eq("projected")
    end

    it "writes the template and a Makefile pinned to the directory it was run from", :aggregate_failures do
      generate_recipe(install_gem_project)

      expect(File.file?(File.join(dir, "generated_recipe/template.yaml"))).to be(true)
      expect(File.read(File.join(dir, "generated_recipe/Makefile"))).to include("ROOT      := #{File.realpath(dir)}")
    end
  end
end
