require "hecks"
require "hecks/ports/persistence/plugins/era"
require_relative "era_registry_loading"

# The first-era hold a database needs before any boot can read it: the steps the `hold_first`
# command's apply makes (provision the lineage, hold era 1, provision its read side). A boot never
# holds an era, so a spec that reads a fresh database holds it here first, then boots.
module FirstEraHold
  include EraRegistryLoading

  # @param url [String] the database URL the lineage lives in
  # @param domain [String] the domain's declared name
  # @param source [String] the bluebook source the first era freezes
  # @return [void]
  def hold_first_era!(url:, domain:, source:)
    bluebook = load_registry(source).bluebooks.values.first
    db = Hecks::Adapters::PostgresEra.connect_for(domain, { database: url })
    lineage = Hecks::Adapters::PostgresEra::Lineage.new(db, domain)
    lineage.ensure_base!
    lineage.hold_first!(source, projection: Hecks::Runtime::StorageShape.project(bluebook))
    lineage.provision_first_era!(bluebook.aggregates)
  ensure
    db&.close
  end
end
