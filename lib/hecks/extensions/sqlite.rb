# HecksSqlite
#
# SQLite persistence extension for Hecks domains. Auto-wires when present
# in the Gemfile -- no configuration needed. Uses Sequel with the sqlite3
# driver to create an in-memory SQLite database and swap in SQL-backed
# repository adapters for all aggregates.
#
# This is the simplest persistence extension: just add the gem and all
# aggregates automatically persist to SQLite. Ideal for development,
# testing, and small production deployments.
#
# Future gem: hecks_sqlite
#
#   # Gemfile
#   gem "cats_domain"
#   gem "hecks_sqlite"   # that's it -- SQLite auto-wires
#
require "hecks_persist"

Hecks.describe_extension(:sqlite,
  description: "SQLite persistence via Sequel",
  adapter_type: :driven,
  config: { database: { default: ":memory:", desc: "Database path" } },
  wires_to: :repository)

# Register the SQLite extension. On boot:
# 1. Requires the Sequel and sqlite3 libraries
# 2. Creates an in-memory SQLite database via Sequel.sqlite
# 3. Delegates to Hecks::Boot::SqlBoot.setup to create SQL-backed
#    repository adapters (creates tables and maps aggregates)
# 4. Swaps the default memory adapters with the SQL adapters in the runtime
#
# @param domain_mod [Module] the domain module constant (e.g. CatsDomain)
# @param domain [Hecks::Domain] the parsed domain definition
# @param runtime [Hecks::Runtime] the runtime instance whose adapters will be swapped
Hecks.register_extension(:sqlite) do |domain_mod, domain, runtime|
  require "sequel"
  require "sqlite3"
  world = Hecks.respond_to?(:last_world) ? Hecks.last_world : nil
  config = world&.config_for(:sqlite) || {}
  db_path = config[:database]
  db = db_path ? Sequel.sqlite(db_path) : Sequel.sqlite
  adapters = Hecks::Boot::SqlBoot.setup(domain, db)
  adapters.each { |name, repo| runtime.swap_adapter(name, repo) }
end
