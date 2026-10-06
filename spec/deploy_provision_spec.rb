require "tmpdir"
require "fileutils"
require "open3"
require "rbconfig"
require "hecks/ports/persistence/plugins/era"
require_relative "support/postgres_probe"
require_relative "support/fenced_owner"

# `hecks deploy provision` (Hecks::Tools::TenantProvisioning) runs as a subprocess against a
# tmpdir fixture, and what it generated is read back.
RSpec.describe "hecks deploy provision", :io do
  # The child's whole program: the tool the launcher's `deploy provision` runs. A prefixed
  # constant name: a bare one collides with another spec's (caught by load_hygiene_spec.rb).
  TENANT_CHILD = 'require "hecks/tools"; Hecks::Tools.script("project_tenant", ARGV)'.freeze
  # Named for the process, so two runs on one Postgres never drop each other's database.
  DB = "hecks_project_tenant_spec_#{Process.pid}".freeze
  # The overlay binds the database by URL as a non-superuser owner: PostgresEra refuses to boot
  # as a superuser (see support/fenced_owner.rb).
  DB_URL = FencedOwner.url(DB)

  PROVISION_SCRATCH_BLUEBOOK = <<~BLUEBOOK.freeze
    Hecks.bluebook "Scratch" do
      vision "one aggregate, enough to exercise tenant provisioning end to end"
      core

      aggregate "Widget" do
        description "a widget"
        identified_by :ref

        value_object "Ref" do
          attribute :value, String
          invariant("a widget has a ref") { !value.to_s.empty? }
        end

        attribute :ref, Ref

        command "Make" do
          role "Someone"
          goal "make a widget"
          attribute :ref, Ref
          emits "WidgetMade"
        end

        query "All" do
        end
      end
    end
  BLUEBOOK

  PROVISION_SCRATCH_HECKSAGON = <<~HECKSAGON.freeze
    Hecks.hecksagon "Scratch" do
      attaches "Governance"
      Scratch::Widget.persisted_by("PostgresEra")
    end
  HECKSAGON

  PROVISION_SCRATCH_WORLD = <<~WORLD.freeze
    Hecks.world "Scratch" do
      realm "ScratchDefault"
    end
  WORLD

  def fixture(dir)
    File.write(File.join(dir, "scratch.bluebook"), PROVISION_SCRATCH_BLUEBOOK)
    File.write(File.join(dir, "scratch.hecksagon"), PROVISION_SCRATCH_HECKSAGON)
    File.write(File.join(dir, "context_map.hecksagon"), InMemoryDomain::GOVERNANCE_POSTGRES_ERA_HECKSAGON)
    File.write(File.join(dir, "scratch.world"), PROVISION_SCRATCH_WORLD)
    File.write(File.join(dir, "governance.world"), InMemoryDomain.governance_postgres_era_world(DB_URL))
  end

  def run_project_tenant(dir, slug, **opts)
    args = [RbConfig.ruby, "-I", File.join(InMemoryDomain::ROOT, "lib"), "-e", TENANT_CHILD, "--", dir, slug]
    opts.each { |k, v| args << "--#{k}=#{v}" }
    Open3.capture3(*args, chdir: InMemoryDomain::ROOT)
  end

  before(:context) do
    skip_message = "no local Postgres reachable" unless PostgresProbe.available?
    @skip = skip_message
    next if skip_message

    admin = PG.connect(dbname: "postgres")
    admin.exec("DROP DATABASE IF EXISTS #{DB} WITH (FORCE)")
    admin.exec("CREATE DATABASE #{DB}")
    admin.close
    FencedOwner.own!(DB)
  end

  after(:context) do
    next if @skip

    admin = PG.connect(dbname: "postgres")
    admin.exec("DROP DATABASE IF EXISTS #{DB} WITH (FORCE)")
    admin.close
  end

  before { skip @skip if @skip }

  # The fixture project in a scratch directory for each example, named by `dir`.
  around do |example|
    Dir.mktmpdir do |scratch|
      @dir = scratch
      fixture(scratch)
      example.run
    end
  end

  attr_reader :dir

  def provision_tenant(slug, realm: slug.capitalize)
    run_project_tenant(dir, slug, domain: "Scratch", realm: realm, schema: slug, database: DB_URL)
  end

  def boot_tenant(slug) = Hecks.boot(dir, environment: slug, install_doors: false)

  def router_over(*tenants)
    register = Hecks::Bluebook::ProjectRegister.new
    tenants.each { |tenant| register.register([tenant.registry.bluebook("Scratch")], tenant.registry, tenant, dir) }
    Hecks::Router.new(register)
  end

  it "validates, provisions the schema, and boots for real", :aggregate_failures do
    out, err, status = provision_tenant("acme")

    expect(status).to be_success, "stdout: #{out}\nstderr: #{err}"
    expect(out).to include("wrote #{File.join(dir, "environments/acme.world")}", 'booted Scratch for tenant "acme"',
                           "tenant_capable?")
  end

  it "writes the overlay for the tenant it provisions" do
    provision_tenant("acme")
    overlay = File.read(File.join(dir, "environments/acme.world"))

    expect(overlay).to include('realm "Acme"', "database \"#{DB_URL}\"", 'schema   "acme"')
  end

  it "is idempotent — a second run for the same tenant is a safe no-op, not an error" do
    provision_tenant("acme")
    _out, _err, status = provision_tenant("acme")

    expect(status).to be_success
  end

  it "keeps two tenants it provisions completely apart, through the real overlays it wrote", :aggregate_failures do
    ["acme", "bloom"].each { |slug| provision_tenant(slug) }
    router = router_over(boot_tenant("acme"), boot_tenant("bloom"))
    router.dispatch("Acme::Scratch::Widget.Make", ref: { value: "acme-provisioned-for-real" })

    expect(router.query("Acme::Scratch::Widget.all").map { |w| w[:ref][:value] }).to eq(["acme-provisioned-for-real"])
    expect(router.query("Bloom::Scratch::Widget.all")).to eq([])
  end

  it "refuses a malformed tenant before writing or connecting to anything", :aggregate_failures do
    _out, err, status = run_project_tenant(dir, "Not A Slug", domain: "Scratch", realm: "Bad", schema: "acme", database: DB_URL)

    expect(status).not_to be_success
    expect(err).to include("is invalid")
    expect(File.exist?(File.join(dir, "environments/not a slug.world"))).to be false
  end
end
