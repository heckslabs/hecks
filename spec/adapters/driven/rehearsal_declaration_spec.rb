require "spec_helper"
require_relative "../../../lib/hecks/hecks/adapters/rehearsal"

# What a subject's `rehearsed_by` may say, and what is refused before anything is touched.
RSpec.describe Hecks::Adapters::Rehearsal::Declaration do
  def world(**settings) = Struct.new(:settings) { def for_verb(_verb) = settings }.new(settings)

  def declare(**settings) = described_class.from_world(world(**settings), "/domain/bluebook")

  it "reads a postgres copy named by an environment variable", :aggregate_failures do
    declaration = declare(adapter: "Postgres", connection_env: "SHOP_REHEARSAL_URL", mode: "readonly_copy")

    expect(declaration.kind).to eq("postgres")
    expect(declaration.drop_after).to be(true)
  end

  it "reads a dump relative to the bluebook directory" do
    declaration = declare(adapter: "Postgres", connection_env: "X", dump: "../dumps/shop.dump")

    expect(declaration.dump).to eq("/domain/dumps/shop.dump")
  end

  it "takes the mode a dump implies" do
    expect(declare(adapter: "Postgres", connection_env: "X", dump: "d.dump").mode).to eq("dump")
  end

  it "reads the schema and the environment the world names", :aggregate_failures do
    declaration = declare(adapter: "Postgres", connection_env: "X", dump: "d.dump", schema: "shop", environment: "staging")

    expect(declaration.schema).to eq("shop")
    expect(declaration.environment).to eq("staging")
  end

  it "leaves the schema and the environment to a default when the world names none", :aggregate_failures do
    declaration = declare(adapter: "Postgres", connection_env: "X", dump: "d.dump")

    expect(declaration.schema).to be_nil
    expect(declaration.environment).to be_nil
  end

  it "refuses a schema that is not a name" do
    expect { declare(adapter: "Postgres", connection_env: "X", schema: "a b; drop") }
      .to raise_error(Hecks::Adapters::Rehearsal::Refused, /schema "a b; drop" is not a name/)
  end

  it "refuses a world with no `rehearsed_by`" do
    expect { declare }.to raise_error(Hecks::Adapters::Rehearsal::Refused, /declares no `rehearsed_by`/)
  end

  it "refuses a literal connection, so a world holds no secret" do
    expect { declare(adapter: "Postgres", connection_env: "X", database: "postgres://u:p@h/db") }
      .to raise_error(Hecks::Adapters::Rehearsal::Refused, /never the value/)
  end

  it "refuses a postgres copy that names no environment variable" do
    expect { declare(adapter: "Postgres") }.to raise_error(Hecks::Adapters::Rehearsal::Refused, /needs `connection_env`/)
  end

  it "refuses a store the language does not name" do
    expect { declare(adapter: "Cassandra") }.to raise_error(Hecks::Adapters::Rehearsal::Refused, /the stores are/)
  end

  it "refuses a readonly_copy of a memory store" do
    expect { declare(adapter: "Memory", mode: "readonly_copy") }
      .to raise_error(Hecks::Adapters::Rehearsal::Refused, /postgres mode/)
  end

  describe "the server a connection names" do
    let(:variable) { "HECKS_REHEARSAL_SPEC_REMOTE" }

    after { ENV.delete(variable) }

    it "is refused when it is not this machine", :aggregate_failures do
      ENV[variable] = "postgres://rehearsal@db.example.com/shop"

      expect { declare(adapter: "Postgres", connection_env: variable).connection }
        .to raise_error(Hecks::Adapters::Rehearsal::Refused, /not this machine/)
    end

    it "is admitted when the world says allow_remote" do
      ENV[variable] = "postgres://rehearsal@db.example.com/shop"

      expect(declare(adapter: "Postgres", connection_env: variable, allow_remote: true).connection).to include("db.example.com")
    end

    it "is admitted on localhost or a socket", :aggregate_failures do
      ENV[variable] = "postgres://rehearsal@localhost/shop"
      expect(declare(adapter: "Postgres", connection_env: variable).connection).to include("localhost")
      ENV[variable] = "postgres:///postgres"
      expect(declare(adapter: "Postgres", connection_env: variable).connection).to eq("postgres:///postgres")
    end
  end

  it "refuses a connection whose variable is unset" do
    declaration = declare(adapter: "Postgres", connection_env: "HECKS_REHEARSAL_SPEC_UNSET_VARIABLE")

    expect { declaration.connection }.to raise_error(Hecks::Adapters::Rehearsal::Refused, /is not set/)
  end
end
