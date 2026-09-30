require "spec_helper"
require "tmpdir"
require_relative "support/postgres_probe"
require_relative "support/fenced_owner"

# Interleaved random writes to two live tenants, across many seeds, must stay partitioned.
# Shared ambient state would show as tenant B seeing what tenant A just wrote.
RSpec.describe "multitenancy: interleaved random writes stay isolated" do
  def write(dir, relative, content)
    path = File.join(dir, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  def fixture_bluebook
    <<~BLUEBOOK
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
  end

  def write_domain(dir, adapter:, tenant_settings:)
    write(dir, "fuzzed.bluebook", fixture_bluebook)
    write(dir, "fuzzed.hecksagon", <<~HECKSAGON)
      Hecks.hecksagon "Fuzzed" do
        uses_framework "Governance"
        Fuzzed::Widget.persisted_by("#{adapter}")
      end
    HECKSAGON
    write(dir, "context_map.hecksagon", InMemoryDomain::GOVERNANCE_MEMORY_HECKSAGON)
    write(dir, "fuzzed.world", <<~WORLD)
      Hecks.world "Fuzzed" do
        realm "FuzzedDefault"
      end
    WORLD

    tenant_settings.each do |slug, settings|
      body = settings.map { |k, v| "    #{k} #{v.inspect}" }.join("\n")
      write(dir, "environments/#{slug}.world", <<~WORLD)
        Hecks.world "Fuzzed" do
          realm "#{slug.capitalize}"
          persisted_by("#{adapter}") do
        #{body}
          end
        end
      WORLD
    end
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

  it "keeps two Memory tenants' interleaved writes exactly partitioned, across many seeds" do
    (1..12).each do |seed|
      Dir.mktmpdir do |dir|
        write_domain(dir, adapter: "Memory", tenant_settings: { "acme" => {}, "bloom" => {} })

        dispatchers = {
          "acme"  => Hecks.boot(dir, environment: "acme", install_doors: false),
          "bloom" => Hecks.boot(dir, environment: "bloom", install_doors: false)
        }

        expected = interleave(dispatchers, seed: seed, steps: 40)

        expected.each do |slug, refs|
          expect(actual_refs(dispatchers.fetch(slug)).sort).to eq(refs.sort),
                                                               "seed #{seed}: tenant #{slug} expected exactly " \
                                                               "#{refs.sort.inspect}"
        end
      end
    end
  end

  # One scratch Postgres database for all seeds; per-seed create/drop would cost more than it buys.
  # rubocop:disable-next RSpec/ExampleLength
  it "keeps two real PostgresEra tenants' interleaved writes exactly partitioned, across several seeds", :io do
    skip "no local Postgres reachable" unless PostgresProbe.available?

    db = "hecks_tenant_isolation_fuzz_spec"
    admin = PG.connect(dbname: "postgres")
    admin.exec("DROP DATABASE IF EXISTS #{db} WITH (FORCE)")
    admin.exec("CREATE DATABASE #{db}")
    admin.close
    # every tenant boots as a non-superuser owner (see support/fenced_owner.rb)
    FencedOwner.own!(db)

    begin
      (1..4).each do |seed|
        Dir.mktmpdir do |dir|
          write_domain(
            dir, adapter:         "PostgresEra",
                 tenant_settings: {
                   "acme"  => { database: FencedOwner.url(db), schema: "fuzz_acme_#{seed}" },
                   "bloom" => { database: FencedOwner.url(db), schema: "fuzz_bloom_#{seed}" }
                 }
          )

          dispatchers = {
            "acme"  => Hecks.boot(dir, environment: "acme", install_doors: false),
            "bloom" => Hecks.boot(dir, environment: "bloom", install_doors: false)
          }

          expected = interleave(dispatchers, seed: seed, steps: 25)

          expected.each do |slug, refs|
            expect(actual_refs(dispatchers.fetch(slug)).sort).to eq(refs.sort),
                                                                 "seed #{seed}: tenant #{slug} expected exactly " \
                                                                 "#{refs.sort.inspect}"
          end
        end
      end
    ensure
      admin = PG.connect(dbname: "postgres")
      admin.exec("DROP DATABASE IF EXISTS #{db} WITH (FORCE)")
      admin.close
    end
  end
end
