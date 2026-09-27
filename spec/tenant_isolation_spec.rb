require "spec_helper"
require "tmpdir"
require_relative "support/postgres_probe"
require_relative "support/fenced_owner"

# Multitenancy needs no ambient tenant: one boot per tenant, each registered into a shared
# ProjectRegister, keeps data apart. TenantCheck refuses adapters that do not.
RSpec.describe "multitenancy: one boot per tenant, one shared route table" do
  def write(dir, relative, content)
    path = File.join(dir, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  def tenant_bluebook
    <<~BLUEBOOK
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
  end

  # One directory, two tenant overlays (environments/acme.world, bloom.world) overriding realm
  # and persistence settings.
  def write_tenant_domain(dir, adapter:, tenant_settings:)
    write(dir, "tenanted.bluebook", tenant_bluebook)
    write(dir, "tenanted.hecksagon", <<~HECKSAGON)
      Hecks.hecksagon "Tenanted" do
        uses_framework "Governance"
        Tenanted::Widget.persisted_by("#{adapter}")
      end
    HECKSAGON
    write(dir, "context_map.hecksagon", InMemoryDomain::GOVERNANCE_MEMORY_HECKSAGON)
    write(dir, "tenanted.world", <<~WORLD)
      Hecks.world "Tenanted" do
        realm "TenantedDefault"
      end
    WORLD

    tenant_settings.each do |slug, settings|
      body = settings.map { |k, v| "    #{k} #{v.inspect}" }.join("\n")
      write(dir, "environments/#{slug}.world", <<~WORLD)
        Hecks.world "Tenanted" do
          realm "#{slug.capitalize}"
          persisted_by("#{adapter}") do
        #{body}
          end
        end
      WORLD
    end
  end

  def boot_tenant(dir, slug)
    Hecks.boot(dir, environment: slug, install_facade: false)
  end

  # Registers only "Tenanted": `uses_framework "Governance"` also loads Governance, which has no
  # world, so registering it would raise MissingRealm.
  def register_tenant(register, dispatcher, dir)
    register.register([dispatcher.registry.bluebook("Tenanted")], dispatcher.registry, dispatcher, dir)
  end

  it "keeps two tenants' data completely apart on Memory, through one shared route table" do
    Dir.mktmpdir do |dir|
      write_tenant_domain(dir, adapter: "Memory", tenant_settings: { "acme" => {}, "bloom" => {} })

      acme  = boot_tenant(dir, "acme")
      bloom = boot_tenant(dir, "bloom")

      expect { Hecks::Runtime::TenantCheck.refuse_unless_tenant_capable!(acme.registry, "Tenanted") }
        .not_to raise_error
      expect { Hecks::Runtime::TenantCheck.refuse_unless_tenant_capable!(bloom.registry, "Tenanted") }
        .not_to raise_error

      register = Hecks::Bluebook::ProjectRegister.new
      register_tenant(register, acme, dir)
      register_tenant(register, bloom, dir)

      router = Hecks::Router.new(register)

      router.dispatch("Acme::Tenanted::Widget.Make", ref: { value: "only-acme-has-this" })

      acme_widgets  = router.query("Acme::Tenanted::Widget.all")
      bloom_widgets = router.query("Bloom::Tenanted::Widget.all")

      expect(acme_widgets.map { |w| w[:ref][:value] }).to eq(["only-acme-has-this"])
      expect(bloom_widgets).to eq([])
    end
  end

  it "refuses to trust a domain for more than one tenant when its bound adapter is not tenant_capable?" do
    Dir.mktmpdir do |dir|
      # Postgres (no era, no schema story) never declares tenant_capable?.
      write_tenant_domain(dir, adapter: "Postgres", tenant_settings: { "acme" => { database: "whatever" } })
      # Hecks.boot would connect; check the gate against the loaded registry instead.
      registry = Hecks::Runtime::Registry.new(root: dir)
      Hecks.with_registry(registry) do
        Kernel.load(InMemoryDomain::EXTRACTION_PORT)
        Kernel.load(InMemoryDomain::PRISM_ADAPTER)
        Kernel.load(File.join(dir, "tenanted.bluebook"))
        Kernel.load(File.join(dir, "tenanted.hecksagon"))
      end

      expect { Hecks::Runtime::TenantCheck.refuse_unless_tenant_capable!(registry, "Tenanted") }
        .to raise_error(Hecks::Runtime::WiringError, /not tenant_capable\?/)
    end
  end

  # Drives the real integration point, ProjectRegister#register: a directory's first registration
  # is never refused; the second is refused before its routes merge into the shared table.
  def load_bare_registry(dir, realm)
    registry = Hecks::Runtime::Registry.new(root: dir)
    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(File.join(dir, "tenanted.bluebook"))
      Kernel.load(File.join(dir, "tenanted.hecksagon"))
      Kernel.load(File.join(dir, "tenanted.world"))
      Kernel.load(File.join(dir, "environments/#{realm.downcase}.world"))
    end
    registry
  end

  it "refuses a domain's SECOND registration into a shared route table when its bound adapter " \
     "is not tenant_capable?, but never touches its first" do
    Dir.mktmpdir do |dir|
      # Postgres never declares tenant_capable?; this skips Hecks.boot, so nothing connects.
      write_tenant_domain(dir, adapter: "Postgres", tenant_settings: { "acme" => {}, "bloom" => {} })

      acme_registry  = load_bare_registry(dir, "Acme")
      bloom_registry = load_bare_registry(dir, "Bloom")

      register = Hecks::Bluebook::ProjectRegister.new
      acme_dispatcher  = Hecks::Runtime::Dispatcher.new(acme_registry)
      bloom_dispatcher = Hecks::Runtime::Dispatcher.new(bloom_registry)

      expect { register.register([acme_registry.bluebook("Tenanted")], acme_registry, acme_dispatcher, dir) }
        .not_to raise_error

      expect { register.register([bloom_registry.bluebook("Tenanted")], bloom_registry, bloom_dispatcher, dir) }
        .to raise_error(Hecks::Runtime::WiringError, /not tenant_capable\?/)

      expect(register.include?("Acme::Tenanted::Widget.Make")).to be true
      expect(register.include?("Bloom::Tenanted::Widget.Make")).to be false
    end
  end

  # One database proves isolation both through dispatch/query and through direct SQL, so the
  # create/drop and tenant boots are paid once.
  # rubocop:disable-next RSpec/ExampleLength
  it "keeps two tenants' data completely apart on real PostgresEra, in genuinely separate schemas", :io do
    skip "no local Postgres reachable" unless PostgresProbe.available?

    db = "hecks_tenant_isolation_spec"
    admin = PG.connect(dbname: "postgres")
    admin.exec("DROP DATABASE IF EXISTS #{db} WITH (FORCE)")
    admin.exec("CREATE DATABASE #{db}")
    admin.close
    # Both tenants boot as a non-superuser owner; PostgresEra refuses superusers (fenced_owner.rb).
    FencedOwner.own!(db)

    # No CREATE SCHEMA: PostgresEra creates a declared schema on connect, and this pins that.

    begin
      Dir.mktmpdir do |dir|
        write_tenant_domain(
          dir, adapter:         "PostgresEra",
               tenant_settings: {
                 "acme"  => { database: FencedOwner.url(db), schema: "tenant_acme" },
                 "bloom" => { database: FencedOwner.url(db), schema: "tenant_bloom" }
               }
        )

        acme  = boot_tenant(dir, "acme")
        bloom = boot_tenant(dir, "bloom")

        expect { Hecks::Runtime::TenantCheck.refuse_unless_tenant_capable!(acme.registry, "Tenanted") }
          .not_to raise_error

        register = Hecks::Bluebook::ProjectRegister.new
        register_tenant(register, acme, dir)
        register_tenant(register, bloom, dir)

        router = Hecks::Router.new(register)
        router.dispatch("Acme::Tenanted::Widget.Make", ref: { value: "acme-only-real-postgres" })

        expect(router.query("Acme::Tenanted::Widget.all").map { |w| w[:ref][:value] }).to eq(["acme-only-real-postgres"])
        expect(router.query("Bloom::Tenanted::Widget.all")).to eq([])

        # Direct SQL against tenant_bloom bypasses the runtime. The table is found by its `_head`
        # suffix (Lineage#head_view): the catalog has no ordering, and PostgresEra's bookkeeping
        # tables each hold a legitimate row.
        direct = PG.connect(dbname: db)
        direct.exec("SET search_path TO tenant_bloom")
        table = direct.exec("SELECT table_name FROM information_schema.tables WHERE table_schema = 'tenant_bloom'")
                      .map { |row| row["table_name"] }.find { |name| name.end_with?("_head") }
        expect(table).not_to be_nil, "PostgresEra never created an aggregate head table in tenant_bloom's own schema at all"
        rows = direct.exec("SELECT count(*) FROM #{table}")
        expect(rows.first["count"]).to eq("0")
        direct.close
      end
    ensure
      admin = PG.connect(dbname: "postgres")
      admin.exec("DROP DATABASE IF EXISTS #{db} WITH (FORCE)")
      admin.close
    end
  end
end
