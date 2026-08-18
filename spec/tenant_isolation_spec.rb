require "spec_helper"
require "tmpdir"
require_relative "support/postgres_probe"

# THE ARCHITECTURAL FINDING THIS SPEC PROVES, END TO END: hosting
# multitenancy needs no ambient "current tenant" thread-local and no
# adapter-level connection cache — `Bluebook::ProjectRegister` already
# resolves an address's REALM to a DISPATCHER at registration time, and
# each registered entry already carries its own boot's own Registry,
# Dispatcher, and adapter instances. So booting the SAME domain
# directory once PER TENANT, each with its own `environment:` overlay
# (realm + persistence settings, both built in the previous slice —
# see Runtime::Loader.boot's own comment), and registering every boot
# into ONE shared ProjectRegister, gives real, physical multitenancy
# through mechanisms that already existed and were already tested for
# something else (Router's realm-keyed dispatch, PostgresEra's `schema:`
# Storehouse isolation) before this spec ever ran.
#
# Runtime::TenantCheck#tenant_capable? is the one genuinely new piece:
# the gate that refuses to trust this pattern for a domain bound to an
# adapter that does NOT keep two boots' data apart (a hypothetical
# adapter with process-wide state, or one with no per-boot isolation
# setting at all).
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

  # ONE DIRECTORY, TWO TENANT OVERLAYS — `environments/acme.world` and
  # `environments/bloom.world` each override realm (and, for the real
  # Postgres example below, persistence settings) the SAME WAY a host's
  # generated tenant overlay would (Q9's own `Deploy::Tenant` world-
  # projector, not yet built, would generate exactly these files).
  def write_tenant_domain(dir, adapter:, tenant_settings:)
    write(dir, "tenanted.bluebook", tenant_bluebook)
    write(dir, "tenanted.hecksagon", <<~HECKSAGON)
      Hecks.hecksagon "Tenanted" do
        uses_framework "Governance"
        Tenanted::Widget.persisted_by("#{adapter}")
      end
    HECKSAGON
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

  # A SHARED ProjectRegister, fed by more than one boot — the same
  # object Bluebook::ProjectLoader#load already builds, just called by
  # hand here rather than through directory discovery (ProjectLoader
  # assumes one boot per discovered directory; a real multi-tenant
  # loader that calls this once per known tenant is later work — Q9's
  # own Deploy::Tenant, not yet built — this proves the primitive it
  # would be built on).
  # ONLY "Tenanted" — not every bluebook this registry loaded. `uses_framework
  # "Governance"` pulls Governance's own bluebook into the SAME registry, and
  # nothing here declares a `Hecks.world "Governance"` (this fixture never
  # needs Governance addressable through the router at all), so registering
  # every bluebook the registry knows about would raise MissingRealm for it.
  def register_tenant(register, dispatcher, dir)
    register.register([dispatcher.registry.bluebook("Tenanted")], dispatcher.registry, dispatcher, dir)
  end

  it "keeps two tenants' data completely apart on Memory, through one shared route table" do
    Dir.mktmpdir do |dir|
      write_tenant_domain(dir, adapter: "Memory", tenant_settings: { "acme" => {}, "bloom" => {} })

      acme  = boot_tenant(dir, "acme")
      bloom = boot_tenant(dir, "bloom")

      # NEITHER refuses — Memory is tenant_capable? by construction.
      expect { Hecksagain::Runtime::TenantCheck.refuse_unless_tenant_capable!(acme.registry, "Tenanted") }
        .not_to raise_error
      expect { Hecksagain::Runtime::TenantCheck.refuse_unless_tenant_capable!(bloom.registry, "Tenanted") }
        .not_to raise_error

      register = Hecksagain::Bluebook::ProjectRegister.new
      register_tenant(register, acme, dir)
      register_tenant(register, bloom, dir)

      router = Hecksagain::Router.new(register)

      router.dispatch("Acme::Tenanted::Widget.Make", ref: { value: "only-acme-has-this" })

      acme_widgets  = router.query("Acme::Tenanted::Widget.all")
      bloom_widgets = router.query("Bloom::Tenanted::Widget.all")

      expect(acme_widgets.map { |w| w[:ref][:value] }).to eq(["only-acme-has-this"])
      expect(bloom_widgets).to eq([])
    end
  end

  it "refuses to trust a domain for more than one tenant when its bound adapter is not tenant_capable?" do
    Dir.mktmpdir do |dir|
      # `Postgres` (no era, no schema story) never declares
      # tenant_capable? — the exact adapter this gate exists to catch.
      write_tenant_domain(dir, adapter: "Postgres", tenant_settings: { "acme" => { database: "whatever" } })
      # `Hecks.boot` itself would try to connect; the gate is checked
      # against the BUILDER's own binds directly, before any adapter is
      # ever instantiated, the same way refuse_ungoverned_roles! checks
      # a merged hecksagon without needing a live repository either.
      registry = Hecksagain::Runtime::Registry.new(root: dir)
      Hecks.with_registry(registry) do
        Kernel.load(InMemoryDomain::EXTRACTION_PORT)
        Kernel.load(InMemoryDomain::PRISM_ADAPTER)
        Kernel.load(File.join(dir, "tenanted.bluebook"))
        Kernel.load(File.join(dir, "tenanted.hecksagon"))
      end

      expect { Hecksagain::Runtime::TenantCheck.refuse_unless_tenant_capable!(registry, "Tenanted") }
        .to raise_error(Hecksagain::Runtime::WiringError, /not tenant_capable\?/)
    end
  end

  it "keeps two tenants' data completely apart on real PostgresEra, in genuinely separate schemas", io: true do
    skip "no local Postgres reachable" unless PostgresProbe.available?

    db = "hecksagain_tenant_isolation_spec"
    admin = PG.connect(dbname: "postgres")
    admin.exec("DROP DATABASE IF EXISTS #{db} WITH (FORCE)")
    admin.exec("CREATE DATABASE #{db}")
    admin.close

    # NO CREATE SCHEMA HERE — deliberately. PostgresEra#connect_for
    # itself now creates a declared `schema:` idempotently on connect
    # (found needing exactly this the first time this spec ran); this
    # boots straight into schemas nobody has created yet, proving that
    # self-healing rather than working around its absence.

    begin
      Dir.mktmpdir do |dir|
        write_tenant_domain(
          dir, adapter:         "PostgresEra",
               tenant_settings: {
                 "acme"  => { database: db, schema: "tenant_acme" },
                 "bloom" => { database: db, schema: "tenant_bloom" }
               }
        )

        acme  = boot_tenant(dir, "acme")
        bloom = boot_tenant(dir, "bloom")

        expect { Hecksagain::Runtime::TenantCheck.refuse_unless_tenant_capable!(acme.registry, "Tenanted") }
          .not_to raise_error

        register = Hecksagain::Bluebook::ProjectRegister.new
        register_tenant(register, acme, dir)
        register_tenant(register, bloom, dir)

        router = Hecksagain::Router.new(register)
        router.dispatch("Acme::Tenanted::Widget.Make", ref: { value: "acme-only-real-postgres" })

        expect(router.query("Acme::Tenanted::Widget.all").map { |w| w[:ref][:value] }).to eq(["acme-only-real-postgres"])
        expect(router.query("Bloom::Tenanted::Widget.all")).to eq([])

        # THE SCHEMAS ARE REAL, NOT JUST LOGICALLY DISJOINT — a direct
        # query against tenant_bloom's own schema, bypassing the runtime
        # entirely, confirms the table itself holds nothing. Found by
        # name via information_schema rather than hardcoded — this is
        # deliberately not asserting PostgresEra's own storage_name
        # convention, only that whichever table holds the AGGREGATE'S
        # OWN data (not any of PostgresEra's own bookkeeping tables) in
        # acme's write ended up empty in bloom's own schema.
        #
        # NOT `.first` on the unfiltered list — found live, the flaky
        # way: `information_schema.tables` makes no ordering guarantee,
        # and this schema also holds hecks_eras/hecks_era_texts/hecks_
        # backfill_progress, each carrying its own legitimate 1-row
        # bookkeeping entry PostgresEra provisions for EVERY schema it
        # touches, tenant write or not. Whichever one the catalog
        # happened to return first was failing this exact assertion on
        # real, correct isolation — `widget_head` itself was empty the
        # whole time. `_head` is the one naming shape only an
        # aggregate's own data table has (`Lineage#head_view`) — no
        # bookkeeping table ends in it, and `_head_snapshot_<era>`
        # doesn't either, so this still isn't the storage_name
        # convention itself, only the shape every aggregate's head
        # shares regardless of what it's actually called.
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
