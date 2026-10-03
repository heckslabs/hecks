require "spec_helper"
require "open3"
require "rbconfig"
require "tmpdir"

# `hecks interview` through the generated launcher (ADR 0088), with the AI left out: the same session,
# typed findings, no model. The AI path is covered by interview_session_spec.rb with a fake agent.
RSpec.describe "hecks interview" do
  KEYS = ["Books, each with an ISBN.", "thing", "Book", "isbn", "", "We shelve a new book.", "action", "Shelve", "Book",
          "BookShelved", "y", "", "done"].freeze

  # No database is reachable and no environment is chosen: the launcher must run this on Memory itself.
  def interview(dir, keys, *words)
    env = { "HECKS_ENVIRONMENT" => nil, "PGHOST" => "/nonexistent-postgres-socket-dir", "PGPORT" => "1" }
    Open3.capture3(env, RbConfig.ruby, File.join(InMemoryDomain::ROOT, "exe/hecks"), "interview", "Lending",
                   "--no-ai", "--expert=Maria", "--adapter=Memory", *words, stdin_data: "#{keys.join("\n")}\n", chdir: dir)
  end

  def written(dir) = Dir.glob("**/*", File::FNM_DOTMATCH, base: dir).select { |path| File.file?(File.join(dir, path)) }.sort

  it "holds the interview, writes the first domain and its record, and prints no journal record" do
    Dir.mktmpdir do |dir|
      out, err, status = interview(dir, KEYS)

      expect(status).to be_success, err
      expect(written(dir)).to eq(%w[lending/bluebook/lending.bluebook lending/bluebook/lending.world lending/interviews/INT-1.md])
      expect(out).to include("hecks docs lending/bluebook", "hecks console subject=lending")
      expect(out).not_to include('"status"')
      expect(File.read(File.join(dir, "lending/bluebook/lending.bluebook"))).to include('aggregate "Book" do')
    end
  end

  it "writes only the next interview's record, with proposed additions, when the domain exists" do
    Dir.mktmpdir do |dir|
      interview(dir, KEYS)
      bluebook = File.join(dir, "lending/bluebook/lending.bluebook")
      File.write(bluebook, "# edited by hand\n")

      out, err, status = interview(dir, KEYS)

      expect(status).to be_success, err
      expect(File.read(bluebook)).to eq("# edited by hand\n")
      expect(File.read(File.join(dir, "lending/interviews/INT-2.md"))).to include("## Proposed additions")
      expect(out).to include("merge the proposed additions")
    end
  end

  it "writes nothing when the developer quits, and nothing when the input ends before there is enough" do
    Dir.mktmpdir do |dir|
      _out, _err, status = interview(dir, ["Books.", "", "quit"])
      expect(status).to be_success
      _out, _err, status = interview(dir, ["Books."])
      expect(status).to be_success
      expect(written(dir)).to be_empty
    end
  end

  it "refuses an unknown adapter and says why" do
    Dir.mktmpdir do |dir|
      _out, err, status = interview(dir, KEYS, "--adapter=Nope")

      expect(status.exitstatus).to eq(1)
      expect(err).to include('unknown adapter "Nope"')
      expect(written(dir)).to be_empty
    end
  end
end
