require "hecks"
require "hecks/ports/persistence/plugins/era"
require_relative "era_registry_loading"
require_relative "../../lib/hecks/hecks/adapters/journal_store"

# The first-era hold a database needs before any boot can read it: the steps the `hold_first`
# command's apply makes (provision the lineage, hold era 1, provision its read side). A boot never
# holds an era, so a spec that reads a fresh database holds it here first, then boots.
module FirstEraHold
  include EraRegistryLoading

  # @param url [String] the database URL the lineage lives in
  # @param domain [String] the domain's declared name
  # @param source [String] the bluebook source the first era freezes
  # @param schema [String, nil] the schema the lineage is held in
  # @param role [String, nil] the app role to grant, as the world's `role:` names it
  # @return [void]
  def hold_first_era!(url:, domain:, source:, schema: nil, role: nil)
    bluebook = load_registry(source).bluebooks.values.first
    db = Hecks::Adapters::PostgresEra.connect_for(domain, { database: url, schema: schema }.compact)
    lineage = Hecks::Adapters::PostgresEra::Lineage.new(db, domain)
    lineage.ensure_base!
    lineage.hold_first!(source, projection: Hecks::Runtime::StorageShape.project(bluebook))
    lineage.provision_first_era!(bluebook.aggregates, role: role)
  ensure
    db&.close
  end

  # Holds era 1 for every bluebook a domain directory loads, each frozen as its own source text,
  # the steps `hold_first` makes for one. A domain that already holds an era is left alone. The
  # world's `stored_as` names apply first, so a renamed aggregate's heads sit under its
  # storage name.
  #
  # @param directory [String] the domain's `bluebook/` directory
  # @param url [String] the database URL the lineage lives in
  # @param schema [String, nil] the schema the lineage is held in
  # @return [void]
  def hold_domain_eras!(directory:, url:, schema: nil)
    held = Hecks::Adapters::JournalStore::HeldDomain.open(directory, mode: :bare)
    held.registry.apply_world_names!
    held.registry.bluebooks.each_value do |bluebook|
      source = Hecks::Runtime::EraCheck.source_text_for(bluebook, held.directory, registry: held.registry)
      hold_bluebook_era!(url, bluebook, source, schema)
    end
  end

  # Holds era 1 of a domain directory in each tenant schema, as `hold_domain_eras!` does for one.
  #
  # @param directory [String] the domain's `bluebook/` directory
  # @param url [String] the database URL the lineages live in
  # @param schemas [Array<String>] the tenants' schemas
  # @return [void]
  def hold_tenant_eras!(directory:, url:, schemas:)
    schemas.each { |schema| hold_domain_eras!(directory: directory, url: url, schema: schema) }
  end

  # Holds era 1 for a bluebook a spec declared in code, which has no source file to freeze: the
  # era holds its name as text and its storage-shape projection, which is what a boot compares.
  #
  # @param bluebook [Hecks::Bluebook::Declaration] the declared domain
  # @param url [String] the database URL the lineage lives in
  # @param schema [String, nil] the schema the lineage is held in
  # @return [void]
  def hold_declared_era!(bluebook, url:, schema: nil)
    hold_bluebook_era!(url, bluebook, "Hecks.bluebook #{bluebook.name.inspect}\n", schema)
  end

  private

  def hold_bluebook_era!(url, bluebook, source, schema = nil)
    db = Hecks::Adapters::PostgresEra.connect_for(bluebook.name, { database: url, schema: schema }.compact)
    lineage = Hecks::Adapters::PostgresEra::Lineage.new(db, bluebook.name)
    lineage.ensure_base!
    return if lineage.eras.any?

    lineage.hold_first!(source, projection: Hecks::Runtime::StorageShape.project(bluebook))
    lineage.provision_first_era!(bluebook.aggregates)
  ensure
    db&.close
  end
end
