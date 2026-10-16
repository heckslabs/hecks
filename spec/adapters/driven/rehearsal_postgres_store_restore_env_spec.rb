require "spec_helper"
require_relative "../../../lib/hecks/hecks/adapters/rehearsal/postgres_store"

# A restore runs `pg_restore` or `psql` with PG* variables built from the server URL the world's
# environment variable holds. The URL names only part of the connection (often just the database),
# so the rest must come from the ambient environment, and an empty part must not hide it.
RSpec.describe Hecks::Adapters::Rehearsal::PostgresStore do
  let(:declaration) { Struct.new(:connection, :connection_env, :mode).new(connection, "SERVER", "dump") }

  def restore_env = described_class.new(declaration, "run").send(:restore_env)

  context "when the URL names only a database" do
    let(:connection) { "postgres:///postgres" }

    it "sets none of the connection variables, so the ambient PGHOST, PGUSER and PGPASSWORD apply" do
      expect(restore_env).to eq({})
    end
  end

  context "when the URL names the whole server" do
    let(:connection) { "postgres://rehearser:s3cret@db.internal:6543/postgres" }

    it "sets each variable it names" do
      expect(restore_env).to eq("PGHOST" => "db.internal", "PGPORT" => "6543", "PGUSER" => "rehearser",
                                "PGPASSWORD" => "s3cret")
    end
  end

  context "when the URL names a host but no credentials" do
    let(:connection) { "postgres://localhost/postgres" }

    it "sets the host alone" do
      expect(restore_env).to eq("PGHOST" => "localhost")
    end
  end
end
