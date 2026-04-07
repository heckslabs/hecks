Hecks::CLI.register_command(:generate_migrations, "Generate SQL migrations from domain changes",
  options: {
    domain:  { type: :string, desc: "Domain gem name or path" },
    version: { type: :string, desc: "Domain version" }
  }
) do

  domain = resolve_domain_option
  next unless domain

  register_sql_strategy = lambda do
    unless Hecks::Migrations::MigrationStrategy.for(:sql)
      Hecks::Migrations::MigrationStrategy.register(:sql, Hecks::Migrations::Strategies::SqlStrategy)
    end
  end

  snapshot_path = Hecks::Migrations::DomainSnapshot::DEFAULT_PATH
  old_domain = Hecks::Migrations::DomainSnapshot.load(path: snapshot_path)
  changes = Hecks::Migrations::DomainDiff.call(old_domain, domain)

  if changes.empty?
    say "Domain is up to date — no migrations needed.", :green
    next
  end

  register_sql_strategy.call
  files = Hecks::Migrations::MigrationStrategy.run_all(changes, output_dir: ".")

  if files.empty?
    say "No migration files generated.", :yellow
    next
  end

  files.each do |f|
    say "Generated #{f}", :green
    File.read(f).each_line { |line| say "  #{line.rstrip}", :cyan }
  end

  Hecks::Migrations::DomainSnapshot.save(domain, path: snapshot_path)
  say "Saved domain snapshot to #{snapshot_path}", :green
end

Hecks::CLI.register_command(:generate_sql, "Generate SQL schema and adapters",
  options: {
    domain:  { type: :string, desc: "Domain gem name or path" },
    version: { type: :string, desc: "Domain version" }
  }
) do

  domain = resolve_domain_option
  next unless domain
  mod = domain_module_name(domain.name)
  gem_name = domain.gem_name

  migration_gen = Hecks::Generators::SQL::SqlMigrationGenerator.new(domain)
  FileUtils.mkdir_p("db")
  File.write("db/schema.sql", migration_gen.generate)
  say "Generated db/schema.sql", :green

  gem_dir = gem_name
  if Dir.exist?(gem_dir)
    domain.aggregates.each do |agg|
      adapter_gen = Hecks::Generators::SQL::SqlAdapterGenerator.new(agg, domain_module: mod)
      path = File.join(gem_dir, "lib/#{gem_name}/adapters/#{domain_snake_name(agg.name)}_sql_repository.rb")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, adapter_gen.generate)
      say "Generated #{path}", :green
    end
  else
    say "Domain gem not found at #{gem_dir}/. Run 'hecks build' first.", :yellow
  end
end

Hecks::CLI.register_command(:db_migrate, "Run pending Hecks SQL migrations",
  options: {
    database: { type: :string, desc: "SQLite database path" }
  }
) do
  build_connection = lambda do
    db_path = options[:database]
    if defined?(::ActiveRecord)
      next ActiveRecord::Base.connection
    end
    unless db_path
      say "No --database specified and ActiveRecord not available.", :red
      next nil
    end
    require "sqlite3"
    db = SQLite3::Database.new(db_path)
    wrapper = Object.new
    wrapper.define_singleton_method(:execute) { |sql| db.execute(sql) }
    wrapper
  end

  connection = build_connection.call
  next unless connection
  runner = Hecks::Migrations::MigrationRunner.new(connection: connection)
  applied = runner.run_all
  if applied.empty?
    say "No pending migrations.", :green
  else
    applied.each { |f| say "Applied #{f}", :green }
  end
end
