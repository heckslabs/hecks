require "pg"

# A deployment's app role for the PostgresEra specs: a non-owner `LOGIN` role, the only kind of
# connection the era write fence acts on, and a way to run one statement as it.
#
# The spec that includes this names the database and the role:
#
#     def app_role_database = "hecks_some_spec"
#     def app_role_name = "hecks_some_spec_app"
module EraAppRole
  # Yields a connection, and closes it after. Takes a conninfo string when connecting by URL,
  # or the `PG.connect` options.
  #
  # @return [Object] what the block answered
  def with_pg(*, **)
    db = PG.connect(*, **)
    yield db
  ensure
    db&.close
  end

  # Drops the spec's app role and everything it owns, and makes it again with the grants an app
  # needs.
  #
  # @return [void]
  def reset_app_role! = reset_role!(app_role_name)

  # Drops `role` and everything it owns, and makes it again with the grants an app needs.
  #
  # @param role [String] the role's name
  # @return [void]
  def reset_role!(role)
    drop_role_ownership(role)
    with_pg(dbname: "postgres") do |admin|
      admin.exec("DROP ROLE IF EXISTS #{role}")
      admin.exec("CREATE ROLE #{role} LOGIN")
    end
    grant_role(role)
  end

  # Runs `sql` as the spec's app role.
  #
  # @param sql [String] the statement
  # @return [Symbol, String] `:allowed`, or the refusal's message
  def as_app_role(sql) = as_role(app_role_name, sql)

  # Runs `sql` as `role`.
  #
  # @param role [String] the role's name
  # @param sql [String] the statement
  # @return [Symbol, String] `:allowed`, or the refusal's message
  def as_role(role, sql)
    db = PG.connect(dbname: app_role_database, user: role)
    db.exec(sql)
    :allowed
  rescue PG::Error => e
    e.message.strip
  ensure
    db&.close
  end

  private

  def drop_role_ownership(role)
    with_pg(dbname: app_role_database) { |db| db.exec("DROP OWNED BY #{role}") }
  rescue PG::Error
    nil
  end

  def grant_role(role)
    with_pg(dbname: app_role_database) do |db|
      db.exec("GRANT CONNECT ON DATABASE #{app_role_database} TO #{role}")
      db.exec("GRANT USAGE ON SCHEMA public TO #{role}")
    end
  end
end
