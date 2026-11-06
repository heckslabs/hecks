require "hecks"
require "hecks/ports/persistence/plugins/era"
require "open3"
require "tmpdir"
require_relative "../../../support/postgres_probe"
require_relative "../../../support/scratch_postgres"

# A dump of a lineage restores: `pg_restore` refreshes a materialized view built on a
# `hecks_tr_*` function with an empty search path, and the function still finds its sibling.
RSpec.describe "PostgresRevisions transform functions across pg_dump and pg_restore", :io do
  SOURCE_DB = "hecks_transform_restore_source_spec".freeze
  TARGET_DB = "hecks_transform_restore_target_spec".freeze

  scratch_postgres SOURCE_DB, TARGET_DB

  before do
    db = PG.connect(dbname: SOURCE_DB)
    Hecks::Adapters::PostgresRevisions::Lineage::TransformSql::ALL.each { |sql| db.exec(sql) }
    db.exec(<<~SQL)
      CREATE TABLE journal (state jsonb);
      INSERT INTO journal VALUES ('{"keep": 1, "gone": 2}');
      CREATE MATERIALIZED VIEW dropped AS SELECT hecks_tr_drop(state, ARRAY['gone']) AS state FROM journal;
    SQL
    db.close
  end

  def run!(*command)
    output, status = Open3.capture2e(*command)
    raise "#{command.first} failed: #{output}" unless status.success?
  end

  # Dumps the source database and restores the dump into the target, as a rehearsal copy is made.
  def dump_and_restore!
    Dir.mktmpdir do |dir|
      dump = File.join(dir, "lineage.dump")
      run!("pg_dump", "-Fc", "-f", dump, SOURCE_DB)
      run!("pg_restore", "--no-owner", "--no-privileges", "-d", TARGET_DB, dump)
    end
  end

  def restored_state
    db = PG.connect(dbname: TARGET_DB)
    db.exec("SELECT state FROM dropped").first["state"]
  ensure
    db&.close
  end

  it "restores a view that reads through hecks_tr_drop" do
    dump_and_restore!
    expect(restored_state).to eq('{"keep": 1}')
  end
end
