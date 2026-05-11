# HecksMysql
#
# MySQL persistence extension for Hecks domains. Auto-wires when
# present in the Gemfile. Uses Sequel with the mysql2 driver to connect
# to a MySQL database and swap in SQL-backed repository adapters for
# all aggregates.
#
# Connection parameters are read from environment variables:
#   HECKS_DB_HOST     -- database host (default: "localhost")
#   HECKS_DB_NAME     -- database name (default: the domain's gem_name)
#   HECKS_DB_USER     -- database user (default: "root")
#   HECKS_DB_PASSWORD -- database password (default: nil)
#
# Future gem: hecks_mysql
#
#   # Gemfile
#   gem "cats_domain"
#   gem "hecks_mysql"   # auto-wires MySQL
#
require "hecks_persist"

Hecks.describe_extension(:mysql,
  description: "MySQL persistence via Sequel",
  adapter_type: :driven,
  config: { host: { default: "localhost", desc: "DB host" }, database: { default: nil, desc: "DB name" } },
  wires_to: :repository)

# Register the MySQL extension. On boot:
# 1. Requires the Sequel library
# 2. Connects to MySQL using environment variables for host, database, user,
#    and password (with sensible defaults)
# 3. Delegates to Hecks::Boot::SqlBoot.setup to create SQL-backed repository
#    adapters for each aggregate
# 4. Swaps the default memory adapters with the SQL adapters in the runtime
#
# @param domain_mod [Module] the domain module constant (e.g. CatsDomain)
# @param domain [Hecks::Domain] the parsed domain definition
# @param runtime [Hecks::Runtime] the runtime instance whose adapters will be swapped
Hecks.register_extension(:mysql) do |domain_mod, domain, runtime|
  require "sequel"
  db = Sequel.connect(adapter: :mysql2,
    host:     ENV.fetch("HECKS_DB_HOST", "localhost"),
    database: ENV.fetch("HECKS_DB_NAME", domain.gem_name),
    user:     ENV.fetch("HECKS_DB_USER", "root"),
    password: ENV.fetch("HECKS_DB_PASSWORD", nil))
  adapters = Hecks::Boot::SqlBoot.setup(domain, db)
  adapters.each { |name, repo| runtime.swap_adapter(name, repo) }
end
