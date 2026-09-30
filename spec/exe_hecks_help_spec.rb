require "spec_helper"
require "open3"
require "rbconfig"

# Usage is projected from the bluebook alone: `exe/hecks` answers it without binding the Hecks
# domain's persistence adapter, so a machine with no Postgres (or a gem without `pg`) still
# reads the help. The child runs with no `HECKS_ENVIRONMENT` and a Postgres address nothing
# listens on; a bound PostgresEra would fail there.
RSpec.describe "exe/hecks usage without an adapter", :io do
  let(:exe) { File.expand_path("../exe/hecks", __dir__) }
  let(:env) do
    { "HECKS_ENVIRONMENT" => nil, "PGHOST" => "127.0.0.1", "PGPORT" => "1", "PGPASSWORD" => nil,
      "LC_ALL" => "C.UTF-8" }
  end

  def hecks(*argv) = Open3.capture3(env, RbConfig.ruby, exe, *argv)

  [
    [],
    ["--help"],
    ["help"],
    ["propose", "--help"],
    ["deploy", "--help"],
    ["ask", "word_status", "--help"]
  ].each do |argv|
    it "answers `hecks #{argv.join(' ')}` with no adapter bound" do
      out, err, status = hecks(*argv)

      expect(status).to be_success, "failed:\n#{err}"
      expect(out).to include("hecks")
      expect(err).not_to match(/cannot (open|bind)|PG::|PostgresEra|password|connect/i)
    end
  end

  it "answers an unknown verb's hint without binding an adapter" do
    out, err, status = hecks("no_such_verb")

    expect(status).not_to be_success
    expect(err).to include("no such verb: no_such_verb")
    expect(err).not_to match(/cannot (open|bind)|PG::|PostgresEra|password/i)
    expect(out).to eq("")
  end

  it "answers the same text in memory as with the adapter unreachable" do
    memory, = Open3.capture3(env.merge("HECKS_ENVIRONMENT" => "memory"), RbConfig.ruby, exe, "--help")
    bare, = hecks("--help")

    expect(bare).to eq(memory)
  end
end
