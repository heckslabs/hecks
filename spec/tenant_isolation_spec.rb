require "spec_helper"
require "tmpdir"
require_relative "support/postgres_probe"
require_relative "support/fenced_owner"
require_relative "support/tenant_scratch_database"

# Multitenancy needs no ambient tenant: one boot per tenant, each registered into a shared
# ProjectRegister, keeps data apart. TenantCheck refuses adapters that do not.
RSpec.describe "multitenancy: one boot per tenant, one shared route table" do
  include TenantScratchDatabase

  TENANT_ISOLATION_BLUEBOOK = <<~BLUEBOOK.freeze
    Hecks.bluebook "Tenanted" do
      vision "one aggregate, enough to prove two tenant boots never see each other's rows"
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

  TENANT_ISOLATION_HECKSAGON = <<~HECKSAGON.freeze
    Hecks.hecksagon "Tenanted" do
      attaches "Governance"
      Tenanted::Widget.persisted_by("%<adapter>s")
    end
  HECKSAGON

  TENANT_ISOLATION_WORLD = <<~WORLD.freeze
    Hecks.world "Tenanted" do
      realm "TenantedDefault"
    end
  WORLD

  TENANT_ISOLATION_OVERLAY = <<~WORLD.freeze
    Hecks.world "Tenanted" do
      realm "%<realm>s"
      persisted_by("%<adapter>s") do
    %<body>s
      end
    end
  WORLD

  # A scratch directory for each example, named by `dir`.
  around do |example|
    Dir.mktmpdir do |scratch|
      @dir = scratch
      example.run
    end
  end

  attr_reader :dir

  def write(relative, content)
    path = File.join(dir, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  # One directory, two tenant overlays (environments/acme.world, bloom.world) overriding realm
  # and persistence settings.
  def write_tenant_domain(adapter:, tenant_settings:)
    write("tenanted.bluebook", TENANT_ISOLATION_BLUEBOOK)
    write("tenanted.hecksagon", format(TENANT_ISOLATION_HECKSAGON, adapter: adapter))
    write("context_map.hecksagon", InMemoryDomain::GOVERNANCE_MEMORY_HECKSAGON)
    write("tenanted.world", TENANT_ISOLATION_WORLD)
    tenant_settings.each { |slug, settings| write_overlay(slug, adapter, settings) }
  end

  def write_overlay(slug, adapter, settings)
    body = settings.map { |k, v| "    #{k} #{v.inspect}" }.join("\n")
    write("environments/#{slug}.world", format(TENANT_ISOLATION_OVERLAY, realm: slug.capitalize, adapter: adapter, body: body))
  end

  def boot_tenant(slug) = Hecks.boot(dir, environment: slug, install_doors: false)

  # Registers only "Tenanted": `attaches "Governance"` also loads Governance, which has no
  # world, so registering it would raise MissingRealm.
  def register_tenant(register, dispatcher)
    register.register([dispatcher.registry.bluebook("Tenanted")], dispatcher.registry, dispatcher, dir)
  end

  def tenant_router(*tenants)
    register = Hecks::Bluebook::ProjectRegister.new
    tenants.each { |tenant| register_tenant(register, tenant) }
    Hecks::Router.new(register)
  end

  def widget_refs(router, tenant) = router.query("#{tenant}::Tenanted::Widget.all").map { |w| w[:ref][:value] }

  def expect_tenant_capable(runtime)
    expect { Hecks::Runtime::TenantCheck.refuse_unless_tenant_capable!(runtime.registry, "Tenanted") }.not_to raise_error
  end

  def memory_tenants = { "acme" => {}, "bloom" => {} }

  it "accepts two Memory tenants of one domain as tenant_capable" do
    write_tenant_domain(adapter: "Memory", tenant_settings: memory_tenants)

    expect_tenant_capable(boot_tenant("acme"))
    expect_tenant_capable(boot_tenant("bloom"))
  end

  it "keeps two tenants' data completely apart on Memory, through one shared route table", :aggregate_failures do
    write_tenant_domain(adapter: "Memory", tenant_settings: memory_tenants)
    router = tenant_router(boot_tenant("acme"), boot_tenant("bloom"))
    router.dispatch("Acme::Tenanted::Widget.Make", ref: { value: "only-acme-has-this" })

    expect(widget_refs(router, "Acme")).to eq(["only-acme-has-this"])
    expect(router.query("Bloom::Tenanted::Widget.all")).to eq([])
  end

  # Hecks.boot would connect; the gate is checked against a registry that only loads the files.
  def load_tenanted_registry(*files)
    registry = Hecks::Runtime::Registry.new(root: dir)
    Hecks.with_registry(registry) do
      [InMemoryDomain::EXTRACTION_PORT, InMemoryDomain::PRISM_ADAPTER, *files.map { |file| File.join(dir, file) }]
        .each { |file| Kernel.load(file) }
    end
    registry
  end

  it "refuses to trust a domain for more than one tenant when its bound adapter is not tenant_capable?" do
    # Postgres (no era, no schema story) never declares tenant_capable?.
    write_tenant_domain(adapter: "Postgres", tenant_settings: { "acme" => { database: "whatever" } })
    registry = load_tenanted_registry("tenanted.bluebook", "tenanted.hecksagon")

    expect { Hecks::Runtime::TenantCheck.refuse_unless_tenant_capable!(registry, "Tenanted") }
      .to raise_error(Hecks::Runtime::WiringError, /not tenant_capable\?/)
  end

  # Drives the real integration point, ProjectRegister#register: a directory's first registration
  # is never refused; the second is refused before its routes merge into the shared table.
  def load_bare_registry(realm)
    load_tenanted_registry("tenanted.bluebook", "tenanted.hecksagon", "tenanted.world",
                           "environments/#{realm.downcase}.world")
  end

  def register_bare(register, registry)
    register.register([registry.bluebook("Tenanted")], registry, Hecks::Runtime::Dispatcher.new(registry), dir)
  end

  # Postgres never declares tenant_capable?; bare registries skip Hecks.boot, so nothing connects.
  def write_unsafe_tenant_domain = write_tenant_domain(adapter: "Postgres", tenant_settings: memory_tenants)

  it "never touches a domain's FIRST registration into a shared route table when its adapter is not tenant_capable?",
     :aggregate_failures do
    write_unsafe_tenant_domain
    register = Hecks::Bluebook::ProjectRegister.new

    expect { register_bare(register, load_bare_registry("Acme")) }.not_to raise_error
    expect(register.include?("Acme::Tenanted::Widget.Make")).to be true
  end

  it "refuses a domain's SECOND registration into a shared route table when its adapter is not tenant_capable?",
     :aggregate_failures do
    write_unsafe_tenant_domain
    register = Hecks::Bluebook::ProjectRegister.new.tap { |shared| register_bare(shared, load_bare_registry("Acme")) }

    expect { register_bare(register, load_bare_registry("Bloom")) }
      .to raise_error(Hecks::Runtime::WiringError, /not tenant_capable\?/)
    expect(register.include?("Bloom::Tenanted::Widget.Make")).to be false
  end

  # One database proves isolation both through dispatch/query and through direct SQL.
  context "when bound to real PostgresEra", :io do
    around do |example|
      next example.run unless PostgresProbe.available?

      # Named for the process, so two runs on one Postgres never drop each other's database.
      with_scratch_database("hecks_tenant_isolation_spec_#{Process.pid}") do |db|
        @db = db
        example.run
      end
    end

    before { skip "no local Postgres reachable" unless PostgresProbe.available? }

    def write_postgres_tenant_domain
      url = FencedOwner.url(@db)
      write_tenant_domain(adapter: "PostgresEra", tenant_settings: {
                            "acme"  => { database: url, schema: "tenant_acme" },
                            "bloom" => { database: url, schema: "tenant_bloom" }
                          })
    end

    # The aggregate's table in tenant_bloom's own schema, found by its `_head` suffix
    # (Lineage#head_view): the catalog has no ordering, and PostgresEra's bookkeeping tables each
    # hold a legitimate row.
    def bloom_head_table(direct)
      tables = direct.exec("SELECT table_name FROM information_schema.tables WHERE table_schema = 'tenant_bloom'")
      tables.map { |row| row["table_name"] }.find { |name| name.end_with?("_head") }
    end

    # Direct SQL against tenant_bloom bypasses the runtime.
    def bloom_head_row_count
      direct = PG.connect(dbname: @db)
      direct.exec("SET search_path TO tenant_bloom")
      table = bloom_head_table(direct)
      expect(table).not_to be_nil, "PostgresEra never created an aggregate head table in tenant_bloom's own schema at all"
      direct.exec("SELECT count(*) FROM #{table}").first["count"]
    ensure
      direct&.close
    end

    it "accepts the tenant as tenant_capable" do
      write_postgres_tenant_domain

      expect_tenant_capable(boot_tenant("acme"))
    end

    it "keeps two tenants' data completely apart on real PostgresEra", :aggregate_failures do
      write_postgres_tenant_domain
      router = tenant_router(boot_tenant("acme"), boot_tenant("bloom"))
      router.dispatch("Acme::Tenanted::Widget.Make", ref: { value: "acme-only-real-postgres" })

      expect(widget_refs(router, "Acme")).to eq(["acme-only-real-postgres"])
      expect(router.query("Bloom::Tenanted::Widget.all")).to eq([])
    end

    # No CREATE SCHEMA: PostgresEra creates a declared schema on connect, and this pins that.
    it "keeps the other tenant's own schema empty of the first tenant's rows, in genuinely separate schemas" do
      write_postgres_tenant_domain
      router = tenant_router(boot_tenant("acme"), boot_tenant("bloom"))
      router.dispatch("Acme::Tenanted::Widget.Make", ref: { value: "acme-only-real-postgres" })

      expect(bloom_head_row_count).to eq("0")
    end
  end
end
