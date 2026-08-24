require "spec_helper"
require "tmpdir"
require_relative "support/postgres_probe"

# FUZZED, NOT HAND-PICKED — tenant_isolation_spec.rb proves isolation
# for one sequential write each; this proves it across many random,
# INTERLEAVED writes to two LIVE tenants at once, across many seeds.
# Interleaving is the part sequential testing can't convincingly rule
# out: a connection or piece of ambient state accidentally shared
# between two boots would most plausibly show up as tenant B seeing
# something tenant A just wrote a moment before it, not as a clean
# before/after leak.
#
# NOT built on Fuzzing::SequenceGenerator/Replay — both are correct and
# heavily used for what they're FOR (generate-a-sequence-then-discard,
# or replay-a-sequence-then-discard; see isolated_boot.rb's own
# header), but neither exposes a live dispatcher after running: the
# boot happens INSIDE `IsolatedBoot.call { |copy| ... }` and the tmpdir
# — and the runtime built on it — is gone the moment that block
# returns. This property needs TWO dispatchers alive across the WHOLE
# interleaved run, then queried at the end, which is a different shape
# from either class's own contract. Retrofitting shared, heavily-relied
# -on fuzzer infrastructure to support a second shape was a bigger,
# riskier change than writing this small, self-contained generator —
# same technique (Random.new(seed), many seeds, real dispatch), a
# fresh instance of it.
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

  # A REAL, INTERLEAVED RANDOM RUN — every one of `steps` iterations
  # flips a coin (seeded, deterministic) for WHICH live tenant gets the
  # next write, mints a fresh ref, dispatches it for real, and records
  # which tenant it went to. Returns the two expected partitions so the
  # caller can check the ACTUAL query results against them.
  def interleave(dispatchers, seed:, steps:)
    random = Random.new(seed)
    expected = dispatchers.keys.to_h { |slug| [slug, []] }

    steps.times do |i|
      slug = dispatchers.keys[random.rand(dispatchers.size)]
      ref = "seed#{seed}-step#{i}-#{random.hex(4)}"
      dispatchers.fetch(slug).dispatch("Fuzzed::Widget.Make", ref: { value: ref })
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
          "acme"  => Hecks.boot(dir, environment: "acme", install_facade: false),
          "bloom" => Hecks.boot(dir, environment: "bloom", install_facade: false)
        }

        expected = interleave(dispatchers, seed: seed, steps: 40)

        expected.each do |slug, refs|
          expect(actual_refs(dispatchers.fetch(slug)).sort).to eq(refs.sort),
                                                               "seed #{seed}: tenant #{slug} expected exactly #{refs.sort.inspect}"
        end
      end
    end
  end

  it "keeps two real PostgresEra tenants' interleaved writes exactly partitioned, across several seeds", io: true do
    skip "no local Postgres reachable" unless PostgresProbe.available?

    db = "hecks_tenant_isolation_fuzz_spec"
    admin = PG.connect(dbname: "postgres")
    admin.exec("DROP DATABASE IF EXISTS #{db} WITH (FORCE)")
    admin.exec("CREATE DATABASE #{db}")
    admin.close

    begin
      (1..4).each do |seed|
        Dir.mktmpdir do |dir|
          write_domain(
            dir, adapter:         "PostgresEra",
                 tenant_settings: {
                   "acme"  => { database: db, schema: "fuzz_acme_#{seed}" },
                   "bloom" => { database: db, schema: "fuzz_bloom_#{seed}" }
                 }
          )

          dispatchers = {
            "acme"  => Hecks.boot(dir, environment: "acme", install_facade: false),
            "bloom" => Hecks.boot(dir, environment: "bloom", install_facade: false)
          }

          expected = interleave(dispatchers, seed: seed, steps: 25)

          expected.each do |slug, refs|
            expect(actual_refs(dispatchers.fetch(slug)).sort).to eq(refs.sort),
                                                                 "seed #{seed}: tenant #{slug} expected exactly #{refs.sort.inspect}"
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
