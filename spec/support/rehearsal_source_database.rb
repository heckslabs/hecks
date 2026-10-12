require "open3"
require "pg"
require_relative "fenced_owner"

# The shop as its previous release held it, written to a throwaway Postgres database and dumped to
# a file: era 1 minted and one widget stored. A rehearsal restores that dump.
#
# `schema:` holds the lineage in that schema instead of `public`, as a shared database does.
module RehearsalSourceDatabase
  module_function

  # @param shop [String] a copy of the shop (`RehearsalShop.copy_to`)
  # @param source [String] the name of the database to make, and drop afterwards
  # @param dump [String] where the custom-format dump is written
  # @param schema [String, nil] the schema the lineage is held in
  # @param widgets [Boolean] whether the widget is stored
  # @return [void]
  def build(shop:, source:, dump:, schema: nil, widgets: true)
    create(source)
    hold_previous_era(shop, source, schema, widgets)
    _out, err, status = Open3.capture3("pg_dump", "--format=custom", "--file", dump, "--dbname", source)
    raise "pg_dump failed: #{err}" unless status.success?
  end

  # @param source [String] the database to drop
  # @return [void]
  def drop(source)
    admin = PG.connect(dbname: "postgres")
    admin.exec("DROP DATABASE IF EXISTS #{source} WITH (FORCE)")
    admin.close
  end

  # @api private
  def create(source)
    admin = PG.connect(dbname: "postgres")
    admin.exec("DROP DATABASE IF EXISTS #{source} WITH (FORCE)")
    admin.exec("CREATE DATABASE #{source}")
    admin.close
    FencedOwner.own!(source)
  end

  # @api private
  def hold_previous_era(shop, source, schema, widgets)
    text = File.read(File.join(shop, "rehearsal", "previous.bluebook"))
    registry = load_previous(text)
    bluebook = registry.bluebooks.values.first
    settings = { database: FencedOwner.url(source), domain: "Shop" }
    settings[:schema] = schema if schema
    Hecks::Adapters::PostgresEra::LineageManager.check!(registry: registry, bluebook: bluebook,
                                                        current_text: text, settings: settings)
    store(bluebook, settings) if widgets
  end

  # @api private
  def store(bluebook, settings)
    aggregate = bluebook.aggregate("Widget")
    adapter = Hecks::Adapters::PostgresEra.new(aggregate: aggregate, settings: settings)
    adapter.save(Hecks::Runtime::Instance.new(aggregate: aggregate, id: "w1",
                                              state: { sku: { "value" => "w1" }, size: { "value" => "small" } }))
  end

  # @api private
  def load_previous(text)
    registry = Hecks::Runtime::Registry.new
    loading = Hecks::Ports::Loading.bootstrap
    Hecks.with_registry(registry) do
      loading.load_library
      Kernel.eval(text, TOPLEVEL_BINDING, "previous.bluebook", 1)
    end
    registry
  end
end
