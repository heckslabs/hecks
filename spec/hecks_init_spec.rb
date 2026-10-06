require "spec_helper"
require "open3"
require "rbconfig"
require "tmpdir"

# `hecks init` through the generated launcher (ADR 0087): a stub is written from a clean
# directory with no environment variable and no database, nothing is ever replaced, and a refusal
# says why and exits 1.
RSpec.describe "hecks init" do
  # No database is reachable, and no environment is chosen: the launcher must pick Memory for itself.
  def init(dir, *words)
    env = { "HECKS_ENVIRONMENT" => nil, "PGHOST" => "/nonexistent-postgres-socket-dir", "PGPORT" => "1" }
    Open3.capture3(env, RbConfig.ruby, File.join(InMemoryDomain::ROOT, "exe/hecks"), "init", *words, chdir: dir)
  end

  def written(dir) = Dir.glob("**/*", File::FNM_DOTMATCH, base: dir).select { |path| File.file?(File.join(dir, path)) }.sort

  let(:dir) { Dir.mktmpdir }

  after { FileUtils.rm_rf(dir) }

  # The path of a Lending stub that was written and then edited by hand.
  def edited_lending_bluebook
    init(dir, "Lending")
    File.join(dir, "lending/bluebook/lending.bluebook").tap { |path| File.write(path, "# edited by hand\n") }
  end

  it "writes a stub, says what to type next, and prints no record", :aggregate_failures do
    out, err, status = init(dir, "Lending")

    expect(status).to be_success, err
    expect(written(dir)).to eq(%w[lending/.gitignore lending/bluebook/lending.bluebook lending/bluebook/lending.world])
    expect(out).to include("hecks docs lending/bluebook", "hecks console subject=lending")
    expect(out).not_to include('"status"')
  end

  it "takes the adapter and the directory as flags", :aggregate_failures do
    _out, err, status = init(dir, "Shop", "--adapter=Postgres", "--dir=shop-app")

    expect(status).to be_success, err
    expect(written(dir)).to include("shop-app/bluebook/environments/memory.world", "shop-app/bluebook/shop.world")
  end

  it "replaces nothing: a second run is refused, names the files, and leaves them as they were", :aggregate_failures do
    bluebook = edited_lending_bluebook

    _out, err, status = init(dir, "Lending")

    expect(status.exitstatus).to eq(1)
    expect(err).to include("nothing written; already there", "lending/bluebook/lending.bluebook")
    expect(File.read(bluebook)).to eq("# edited by hand\n")
  end

  it "refuses an unknown adapter, and writes nothing", :aggregate_failures do
    _out, err, status = init(dir, "Cafe", "--adapter=Nope")

    expect(status.exitstatus).to eq(1)
    expect(err).to include('unknown adapter "Nope"')
    expect(written(dir)).to be_empty
  end

  it "refuses a name that is not a capitalised word, and writes nothing", :aggregate_failures do
    _out, err, status = init(dir, "cafe")

    expect(status.exitstatus).to eq(1)
    expect(err).to include("DomainName.value must match")
    expect(written(dir)).to be_empty
  end
end
