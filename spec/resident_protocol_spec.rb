require "spec_helper"
require "stringio"
require "tmpdir"
require "hecks/tools/project_cli"
require "hecks/adapters/driving/resident/client"
require "hecks/adapters/driving/resident/fingerprint"

# The pieces of the resident that need no process: what its client and it say to each other,
# where its files live, which lines never go to it, how it notices that its code changed, and
# which launchers carry the probe (ADR 0201).
RSpec.describe "the resident's protocol" do
  let(:resident) { Hecks::Adapters::Driving::Resident }

  describe "the wire" do
    let(:request) do
      { argv: ["RedFlag.status", "a b"], env: { "A" => "1", "B" => "x=y\nz" }, cwd: "/tmp", script: "/c/exe/hecks" }
    end

    def round_trip(sent)
      io = StringIO.new
      resident::Wire.write_request(io, sent)
      resident::Wire.read_request(StringIO.new(io.string))
    end

    it "carries the arguments, the environment, the directory and the script unchanged" do
      expect(round_trip(request)).to eq(request)
    end

    it "refuses a request that stops short" do
      expect { resident::Wire.read_request(StringIO.new("20\0only\0")) }.to raise_error(EOFError)
    end

    it "reads one reply line at a time and nil once the other end has gone" do
      io = StringIO.new("go\nstatus:3\n")
      expect([io, io, io].map { |stream| resident::Wire.read_reply(stream) }).to eq(["go", "status:3", nil])
    end
  end

  describe "the paths" do
    around do |example|
      Dir.mktmpdir("hrp") do |dir|
        @dir = dir
        saved = ENV.fetch("HECKS_CACHE_DIR", nil)
        ENV["HECKS_CACHE_DIR"] = dir
        example.run
      ensure
        ENV["HECKS_CACHE_DIR"] = saved
      end
    end

    it "keeps a checkout's files under the cache directory the specs redirect", :aggregate_failures do
      paths = resident::Paths
      expect(paths.directory).to eq(File.join(@dir, "resident"))
      expect([paths.socket("/c"), paths.lock("/c"), paths.pid("/c")].map { |file| File.dirname(file) }.uniq)
        .to eq([paths.directory])
    end

    it "names a checkout's files the same way every time and another checkout's differently" do
      expect([resident::Paths.socket("/a"), resident::Paths.socket("/a")].uniq.size)
        .to eq(1).and(satisfy { resident::Paths.socket("/a") != resident::Paths.socket("/b") })
    end

    it "does not use a socket path longer than the system allows", :aggregate_failures do
      expect(resident::Paths.usable?("/c")).to be(true)
      ENV["HECKS_CACHE_DIR"] = File.join(@dir, "x" * 120)
      expect(resident::Paths.usable?("/c")).to be(false)
    end

    it "finds the checkout above a launcher's exe directory" do
      script = File.expand_path("../exe/hecks", __dir__)
      expect(resident::Paths.root_for(script)).to eq(File.realpath(File.expand_path("..", __dir__)))
    end
  end

  describe "the lines the launcher keeps for itself" do
    def bypassed?(*argv)
      saved = ARGV.dup
      ARGV.replace(argv)
      resident::Client.bypass?
    ensure
      ARGV.replace(saved)
    end

    around do |example|
      saved = ENV.fetch("HECKS_NO_RESIDENT", nil)
      ENV.delete("HECKS_NO_RESIDENT")
      example.run
    ensure
      ENV["HECKS_NO_RESIDENT"] = saved
    end

    it "runs a terminal line, a long-lived one and a streamed one itself", :aggregate_failures do
      expect(%w[console interview init mcp console!].map { |word| bypassed?(word) }).to all(be(true))
      expect(bypassed?("Operation.follow", "--stream")).to be(true)
    end

    it "sends an ordinary line to the resident" do
      expect(bypassed?("RedFlag.status")).to be(false)
    end

    it "keeps every line for itself when HECKS_NO_RESIDENT is set, and none when it is 0", :aggregate_failures do
      ENV["HECKS_NO_RESIDENT"] = "1"
      expect(bypassed?("RedFlag.status")).to be(true)
      ENV["HECKS_NO_RESIDENT"] = "0"
      expect(bypassed?("RedFlag.status")).to be(false)
    end
  end

  describe "the fingerprint" do
    around do |example|
      Dir.mktmpdir("hecks-resident-fingerprint") do |root|
        @root = root
        FileUtils.mkdir_p(File.join(root, "lib/hecks"))
        File.write(File.join(root, "lib/hecks/a.rb"), "A = 1\n")
        example.run
      end
    end

    let(:fingerprint) { resident::Fingerprint.new(@root) }

    it "is the same while nothing changes" do
      first = fingerprint.current
      expect(fingerprint.current).to eq(first)
    end

    it "changes when a file under lib changes size, appears or goes", :aggregate_failures do
      before = fingerprint.current
      File.write(File.join(@root, "lib/hecks/a.rb"), "A = 22\n")
      resized = fingerprint.current
      File.write(File.join(@root, "lib/hecks/b.rb"), "")
      expect([resized != before, fingerprint.current != resized]).to eq([true, true])
    end

    it "changes when the file's modification time moves with its size unchanged" do
      before = fingerprint.current
      File.utime(Time.now + 60, Time.now + 60, File.join(@root, "lib/hecks/a.rb"))
      expect(fingerprint.current).not_to eq(before)
    end

    def watch_outside_lib
      outside = File.join(@root, "qa")
      FileUtils.mkdir_p(outside)
      fingerprint.watch(outside)
      outside
    end

    it "reads a domain directory outside lib once told to watch it" do
      before = fingerprint.current
      File.write(File.join(watch_outside_lib, "x.bluebook"), "")
      expect(fingerprint.current).not_to eq(before)
    end

    it "reads the lockfile at the checkout's root" do
      before = fingerprint.current
      File.write(File.join(@root, "Gemfile.lock"), "")
      expect(fingerprint.current).not_to eq(before)
    end
  end

  describe "which launchers carry the probe" do
    def launcher(**options)
      Hecks::Tools::ProjectCli.launcher("lib/hecks/hecks", "Hecks", "hecks project_cli", **options)
    end

    it "is in the first lines of an executable launcher, before the gems are chosen", :aggregate_failures do
      text = launcher(executable: "exe/hecks")
      expect(text).to include("Hecks::Adapters::Driving::Resident::Client.run(__FILE__)")
      expect(text.index("Resident::Client.run")).to be < text.index("bundler/setup")
    end

    it "is not in a launcher that sits beside a client's domain" do
      expect(launcher).not_to include("Resident")
    end

    it "is in the committed exe/hecks, which is what the generator writes" do
      expect(File.read(File.expand_path("../exe/hecks", __dir__))).to include("Resident::Client.run(__FILE__)")
    end
  end
end
