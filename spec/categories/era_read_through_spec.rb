require "spec_helper"
require "tmpdir"
require "fileutils"
require "hecks/fuzzing"
require_relative "../support/scratch_postgres"

# Records written under the era fixtures' `base` shape, read back after the bluebook moves to
# each other fixture. A store that holds eras reads a `same_*` shape through unchanged and
# refuses to boot a `bump_*` shape no translation edge covers, so no record is ever read under a
# shape it was not written in. A store with no eras reads a `same_*` or additive shape through
# unchanged; it never refuses drift (spec/runtime/era_check_spec.rb).
RSpec.describe "every era fixture, read through from its base", :aggregate_failures do
  # The fixtures a store with no eras reads through unchanged: the same shape, or one only added to.
  ADDITIVE_ERA_FIXTURES = %w[same_behavior same_reordered bump_new_attribute].freeze

  ERA_SCRATCH_DB = "hecks_era_read_through_spec".freeze

  def self.fixtures_dir = File.join(InMemoryDomain::ROOT, "spec/fixtures/eras")

  def self.fixtures = Dir[File.join(fixtures_dir, "*.bluebook")].map { |path| File.basename(path, ".bluebook") }.sort - ["base"]

  # A domain directory holding `base` bound through a hecksagon, so a boot can rebind its store.
  def base_domain(tmp)
    dir = File.join(tmp, "shaped", "bluebook")
    FileUtils.mkdir_p(dir)
    FileUtils.cp(File.join(self.class.fixtures_dir, "base.bluebook"), File.join(dir, "shaped.bluebook"))
    File.write(File.join(dir, "shaped.hecksagon"), %(Hecks.hecksagon "Shaped" do\n#{bindings}end\n))
    File.dirname(dir)
  end

  def bindings = %w[Customer Account].map { |name| %(  Shaped::#{name}.persisted_by("Memory")\n) }.join

  # Each record `base` holds, written straight through its repository: no command creates a
  # Customer, so an Account's required reference could not be set by dispatch.
  def write_records(runtime)
    save(runtime, "Customer", "Ada", full_name: { value: "Ada" })
    save(runtime, "Account", "a1", number: { value: "a1" }, balance: { cents: 100, currency: "USD" },
                                   tags: [{ value: "vip" }], customer: "Ada", status: "open")
    save(runtime, "Account", "a2", number: { value: "a2" }, balance: { cents: 5, currency: "EUR" },
                                   tags: [], customer: "Ada", status: "closed")
  end

  def save(runtime, name, id, state)
    aggregate = runtime.registry.bluebook("Shaped").aggregate(name)
    runtime.registry.repository("Shaped",
                                aggregate).save(Hecks::Runtime::Instance.new(aggregate: aggregate, id: id, state: state))
  end

  # `[written, read]` records, or `[written, error]` when the moved shape refuses to boot. The
  # moved bluebook takes a fresh file name: the predicate extractor caches source by path.
  def read_through(fixture, **store)
    Dir.mktmpdir do |tmp|
      Hecks::Fuzzing::IsolatedBoot.call(base_domain(tmp), **store) do |copy|
        written = records(Hecks.boot(copy, environment: nil).tap { |runtime| write_records(runtime) })
        move_shape(copy, fixture)
        [written, reboot(copy)]
      end
    end
  end

  def move_shape(copy, fixture)
    FileUtils.rm(File.join(copy, "bluebook", "shaped.bluebook"))
    FileUtils.cp(File.join(self.class.fixtures_dir, "#{fixture}.bluebook"), File.join(copy, "bluebook", "#{fixture}.bluebook"))
  end

  def reboot(copy)
    records(Hecks.boot(copy, environment: nil))
  rescue Hecks::Runtime::WiringError => e
    e
  end

  # `read` cut back to the records and fields `written` holds: a shape that only adds a field
  # reads it as well, and that is not a change to what was written.
  def as_written(read, written)
    written.to_h { |key, fields| [key, read.fetch(key, {}).slice(*fields.keys)] }
  end

  def records(runtime)
    JSON.parse(JSON.generate(Hecks::Runtime::Value.materialize(Hecks::Fuzzing::Replay.snapshot_instances(runtime))))
  end

  ADDITIVE_ERA_FIXTURES.each do |fixture|
    it "reads every field written under base through #{fixture} unchanged on a store with no eras" do
      written, read = read_through(fixture, adapter: :sqlite)
      expect(as_written(read, written)).to eq(written)
    end
  end

  describe "on a store that holds eras", :io do
    before(:context) do
      skip "no reachable Postgres" unless PostgresProbe.available?
      ScratchPostgres.create([ERA_SCRATCH_DB], fenced: true)
    end

    after(:context) { ScratchPostgres.drop([ERA_SCRATCH_DB]) if PostgresProbe.available? }

    def era_read_through(fixture)
      read_through(fixture, adapter: :postgres_era, database: ERA_SCRATCH_DB, schema: "era_#{fixture}")
    end

    fixtures.each do |fixture|
      if fixture.start_with?("same_")
        it "reads every record written under base through #{fixture} unchanged" do
          written, read = era_read_through(fixture)
          expect(read).to eq(written)
        end
      else
        it "refuses to boot #{fixture} without a translation edge, reading no record under it" do
          expect(era_read_through(fixture).last).to be_a(Hecks::Runtime::WiringError)
            .and have_attributes(message: /no translation edge covers it/)
        end
      end
    end
  end
end
