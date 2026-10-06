require_relative "fenced_owner"

# A scratch Postgres database for a tenant spec: created fresh before the block, owned by the
# non-superuser role PostgresEra boots as, and dropped afterwards.
module TenantScratchDatabase
  # @param name [String] the database to create; named for the spec (and process, where two runs
  #   on one Postgres must never drop each other's)
  # @yieldparam name [String] the created database
  # @return [Object] the block's value
  def with_scratch_database(name)
    drop_scratch_database(name, create: true)
    # Both tenants boot as a non-superuser owner; PostgresEra refuses superusers (fenced_owner.rb).
    FencedOwner.own!(name)
    yield name
  ensure
    drop_scratch_database(name)
  end

  # Drops the database, and creates it again when `create` is set.
  #
  # @param name [String] the database
  # @param create [Boolean] whether to create it after dropping
  # @return [void]
  def drop_scratch_database(name, create: false)
    admin = PG.connect(dbname: "postgres")
    admin.exec("DROP DATABASE IF EXISTS #{name} WITH (FORCE)")
    admin.exec("CREATE DATABASE #{name}") if create
    admin.close
  end
end
