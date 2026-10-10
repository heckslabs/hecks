require "spec_helper"
require "tmpdir"
require_relative "support/postgres_probe"
require_relative "support/fenced_owner"
require_relative "support/tenant_scratch_database"

# Interleaved random writes to two live tenants, across many seeds, must stay partitioned.
# Shared ambient state would show as tenant B seeing what tenant A just wrote.
RSpec.describe "multitenancy: interleaved random writes stay isolated" do
  include TenantScratchDatabase

  TENANT_FUZZ_BLUEBOOK = <<~BLUEBOOK.freeze
    Hecks.bluebook "Fuzzed" do
      vision "one aggregate, enough to interleave random writes across two live tenants"
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

  TENANT_FUZZ_HECKSAGON = <<~HECKSAGON.freeze
    Hecks.hecksagon "Fuzzed" do
      attaches "Governance"
      Fuzzed::Widget.persisted_by("%<adapter>s")
    end
  HECKSAGON

  TENANT_FUZZ_WORLD = <<~WORLD.freeze
    Hecks.world "Fuzzed" do
      realm "FuzzedDefault"
    end
  WORLD

  TENANT_FUZZ_OVERLAY = <<~WORLD.freeze
    Hecks.world "Fuzzed" do
      realm "%<realm>s"
      persisted_by("%<adapter>s") do
    %<body>s
      end
    end
  WORLD

  def write(dir, relative, content)
    path = File.join(dir, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  def write_overlay(dir, slug, adapter, settings)
    body = settings.map { |k, v| "    #{k} #{v.inspect}" }.join("\n")
    write(dir, "environments/#{slug}.world", format(TENANT_FUZZ_OVERLAY, realm: slug.capitalize, adapter: adapter, body: body))
  end

  def write_domain(dir, adapter:, tenant_settings:)
    write(dir, "fuzzed.bluebook", TENANT_FUZZ_BLUEBOOK)
    write(dir, "fuzzed.hecksagon", format(TENANT_FUZZ_HECKSAGON, adapter: adapter))
    write(dir, "context_map.hecksagon", InMemoryDomain::GOVERNANCE_MEMORY_HECKSAGON)
    write(dir, "fuzzed.world", TENANT_FUZZ_WORLD)
    tenant_settings.each { |slug, settings| write_overlay(dir, slug, adapter, settings) }
  end

  # Not built on Fuzzing::SequenceGenerator/Replay: they discard the runtime when IsolatedBoot
  # returns, and this needs two live dispatchers queried at the end.
  # Each step picks a tenant with a seeded coin, dispatches Make, and returns the expected refs.
  def interleave(dispatchers, seed:, steps:)
    random = Random.new(seed)
    expected = dispatchers.keys.to_h { |slug| [slug, []] }

    steps.times do |i|
      slug = dispatchers.keys[random.rand(dispatchers.size)]
      ref = "seed#{seed}-step#{i}-#{random.hex(4)}"
      dispatchers.fetch(slug).dispatch_flat("Fuzzed::Widget.Make", ref: { value: ref })
      expected[slug] << ref
    end

    expected
  end

  def actual_refs(dispatcher)
    dispatcher.query("Fuzzed::Widget.All").map { |w| w[:ref][:value] }
  end

  def boot_tenants(dir)
    { "acme"  => Hecks.boot(dir, environment: "acme", install_driving: false),
      "bloom" => Hecks.boot(dir, environment: "bloom", install_driving: false) }
  end

  # One line for each tenant whose rows after the interleaved writes are not exactly its own.
  def partition_mismatches(seed:, steps:, adapter:, tenant_settings:)
    Dir.mktmpdir do |dir|
      write_domain(dir, adapter: adapter, tenant_settings: tenant_settings)
      dispatchers = boot_tenants(dir)
      interleave(dispatchers, seed: seed, steps: steps).filter_map do |slug, refs|
        actual = actual_refs(dispatchers.fetch(slug)).sort
        "seed #{seed}: tenant #{slug} expected exactly #{refs.sort.inspect}, got #{actual.inspect}" unless actual == refs.sort
      end
    end
  end

  it "keeps two Memory tenants' interleaved writes exactly partitioned, across many seeds" do
    (1..12).each do |seed|
      mismatches = partition_mismatches(seed: seed, steps: 40, adapter: "Memory",
                                        tenant_settings: { "acme" => {}, "bloom" => {} })

      expect(mismatches).to be_empty
    end
  end

  # One scratch Postgres database for all seeds; per-seed create/drop would cost more than it buys.
  context "when bound to real PostgresEra", :io do
    around do |example|
      next example.run unless PostgresProbe.available?

      with_scratch_database("hecks_tenant_isolation_fuzz_spec") do |db|
        @db = db
        example.run
      end
    end

    before { skip "no local Postgres reachable" unless PostgresProbe.available? }

    def postgres_tenants(seed)
      url = FencedOwner.url(@db)
      { "acme"  => { database: url, schema: "fuzz_acme_#{seed}" },
        "bloom" => { database: url, schema: "fuzz_bloom_#{seed}" } }
    end

    it "keeps two real PostgresEra tenants' interleaved writes exactly partitioned, across several seeds" do
      (1..4).each do |seed|
        mismatches = partition_mismatches(seed: seed, steps: 25, adapter: "PostgresEra", tenant_settings: postgres_tenants(seed))

        expect(mismatches).to be_empty
      end
    end
  end
end
