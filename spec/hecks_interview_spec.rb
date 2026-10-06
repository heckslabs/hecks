require "spec_helper"
require "open3"
require "rbconfig"
require "tmpdir"
require "fileutils"

# `hecks interview` through the generated launcher (ADR 0088), with the agent left out: the same
# session, typed findings, no model. The agent path is covered by interview_session_spec.rb with a
# fake agent.
RSpec.describe "hecks interview" do
  KEYS = ["Books, each with an ISBN.", "thing", "Book", "isbn", "", "We shelve a new book.", "action", "Shelve", "Book",
          "BookShelved", "y", "", "done"].freeze

  # No database is reachable and no environment is chosen: the launcher must run this on
  # Memory itself.
  def interview(dir, keys, *words)
    env = { "HECKS_ENVIRONMENT" => nil, "PGHOST" => "/nonexistent-postgres-socket-dir", "PGPORT" => "1" }
    Open3.capture3(env, RbConfig.ruby, File.join(InMemoryDomain::ROOT, "exe/hecks"), "interview", "Lending",
                   "--no-ai", "--expert=Maria", "--adapter=Memory", *words, stdin_data: "#{keys.join("\n")}\n", chdir: dir)
  end

  def written(dir) = Dir.glob("**/*", File::FNM_DOTMATCH, base: dir).select { |path| File.file?(File.join(dir, path)) }.sort

  let(:dir) { Dir.mktmpdir }

  after { FileUtils.rm_rf(dir) }

  def lending_bluebook = File.join(dir, "lending/bluebook/lending.bluebook")

  # Interviews, lets the developer edit the bluebook by hand, then interviews again.
  def reinterview_after_edit
    interview(dir, KEYS)
    File.write(lending_bluebook, "# edited by hand\n")
    interview(dir, KEYS)
  end

  it "holds the interview and prints no journal record", :aggregate_failures do
    out, err, status = interview(dir, KEYS)

    expect(status).to be_success, err
    expect(out).to include("hecks docs lending/bluebook", "hecks console subject=lending")
    expect(out).not_to include('"status"')
  end

  it "writes the first domain and its record", :aggregate_failures do
    interview(dir, KEYS)

    expect(written(dir)).to eq(%w[lending/bluebook/lending.bluebook lending/bluebook/lending.world lending/interviews/INT-1.md])
    expect(File.read(lending_bluebook)).to include('aggregate "Book" do')
  end

  it "leaves a hand-edited domain untouched when it interviews again", :aggregate_failures do
    _out, err, status = reinterview_after_edit

    expect(status).to be_success, err
    expect(File.read(lending_bluebook)).to eq("# edited by hand\n")
  end

  it "writes the next interview's record, with proposed additions, when the domain exists", :aggregate_failures do
    out, = reinterview_after_edit

    expect(File.read(File.join(dir, "lending/interviews/INT-2.md"))).to include("## Proposed additions")
    expect(out).to include("merge the proposed additions")
  end

  it "writes nothing when the developer quits", :aggregate_failures do
    _out, _err, status = interview(dir, ["Books.", "", "quit"])

    expect(status).to be_success
    expect(written(dir)).to be_empty
  end

  it "writes nothing when the input ends before there is enough", :aggregate_failures do
    _out, _err, status = interview(dir, ["Books."])

    expect(status).to be_success
    expect(written(dir)).to be_empty
  end

  it "refuses an unknown adapter and says why", :aggregate_failures do
    _out, err, status = interview(dir, KEYS, "--adapter=Nope")

    expect(status.exitstatus).to eq(1)
    expect(err).to include('unknown adapter "Nope"')
    expect(written(dir)).to be_empty
  end
end
