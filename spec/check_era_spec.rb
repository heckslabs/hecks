require "socket"
require "json"
require "tmpdir"
require "open3"
require "rbconfig"
require "hecks/ports/persistence/plugins/era/expected_era"

# `hecks check_era` (Hecks::CLI::CheckEra) and the library under it, against a stub host that serves
# `GET /version` the way rust/host's `version_router` does. The stub is a
# bare TCPServer on an ephemeral port: it answers one canned response per
# connection and records what was requested.
RSpec.describe "hecks check_era", :io do
  def era_check = Hecks::Runtime::EraCheck::ExpectedEra

  # A stub host answering every request with `status` and `body`.
  class CheckEraStubHost
    attr_reader :port, :requests

    def initialize(status: 200, body: nil)
      @status = status
      @body = body
      @requests = []
      @server = TCPServer.new("127.0.0.1", 0)
      @port = @server.addr[1]
      @thread = Thread.new { serve }
    end

    def url = "http://127.0.0.1:#{port}"

    def stop
      @thread.kill
      @server.close
    end

    private

    def serve
      loop do
        client = @server.accept
        @requests << client.gets.to_s.strip
        while (line = client.gets) && line != "\r\n"; end
        head = "HTTP/1.1 #{@status} X\r\nContent-Type: application/json\r\nContent-Length: #{@body.to_s.bytesize}\r\n"
        client.write("#{head}Connection: close\r\n\r\n#{@body}")
        client.close
      end
    end
  end

  def root = File.expand_path("..", __dir__)

  def version_body(era = "199b08") = JSON.generate("era" => era, "ir_hash" => "a" * 64, "build" => "2.5.1")

  def with_host(**options)
    host = CheckEraStubHost.new(**options)
    yield host
  ensure
    host&.stop
  end

  def with_list(text)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "expected-era")
      File.write(path, text)
      yield path
    end
  end

  # The child's whole program: the library entry point that `hecks check_era` runs.
  def run(*args)
    entry = '$LOAD_PATH.unshift(File.join(Dir.pwd, "lib")); require "hecks/cli/check_era"; ' \
            "exit Hecks::CLI::CheckEra.run(ARGV)"
    Open3.capture3(RbConfig.ruby, "-e", entry, "--", *args, chdir: root)
  end

  describe "the allow-list file" do
    it "reads one era per line, ignoring comments and blanks" do
      text = "# header\n\naaa111\n  bbb222  \n# gone\nccc333 # trailing note\n"

      expect(era_check.parse(text)).to eq(%w[aaa111 bbb222 ccc333])
    end

    it "lists no era for a file of only comments" do
      expect(era_check.parse("# nothing yet\n\n")).to eq([])
    end
  end

  describe "the version URL" do
    it "adds /version to a base URL and leaves a /version URL alone" do
      expect(era_check.version_url("https://host.example")).to eq("https://host.example/version")
      expect(era_check.version_url("https://host.example/")).to eq("https://host.example/version")
      expect(era_check.version_url("https://host.example/version")).to eq("https://host.example/version")
    end
  end

  describe "against a host" do
    it "exits 0 when the reported era is on the list" do
      with_host(body: version_body("199b08")) do |host|
        with_list("# eras\n199b08\n") do |list|
          stdout, _stderr, status = run(host.url, list)

          expect(status.exitstatus).to eq(0)
          expect(stdout).to include("199b08")
          expect(host.requests.first).to eq("GET /version HTTP/1.1")
        end
      end
    end

    it "exits 1 when the reported era is not on the list" do
      with_host(body: version_body("199b08")) do |host|
        with_list("aaa111\nbbb222\n") do |list|
          _stdout, stderr, status = run(host.url, list)

          expect(status.exitstatus).to eq(1)
          expect(stderr).to include("199b08", "aaa111, bbb222")
        end
      end
    end

    it "only checks that an era is reported when the list names none" do
      with_host(body: version_body("199b08")) do |host|
        with_list("# nothing listed\n") do |list|
          stdout, _stderr, status = run(host.url, list)

          expect(status.exitstatus).to eq(0)
          expect(stdout).to include("lists no era")
        end
      end
    end

    it "accepts the /version URL itself" do
      with_host(body: version_body("199b08")) do |host|
        with_list("199b08\n") do |list|
          _stdout, _stderr, status = run("#{host.url}/version", list)

          expect(status.exitstatus).to eq(0)
        end
      end
    end

    it "exits 3 when the host answers something other than 200" do
      with_host(status: 502, body: "bad gateway") do |host|
        with_list("199b08\n") do |list|
          _stdout, stderr, status = run(host.url, list)

          expect(status.exitstatus).to eq(3)
          expect(stderr).to include("502")
        end
      end
    end

    it "exits 3 when the body is not a version document" do
      with_host(body: "<html>not json</html>") do |host|
        with_list("199b08\n") do |list|
          _stdout, _stderr, status = run(host.url, list)

          expect(status.exitstatus).to eq(3)
        end
      end
    end

    it "exits 3 when the document carries no era" do
      with_host(body: JSON.generate("build" => "2.5.1")) do |host|
        with_list("199b08\n") do |list|
          _stdout, stderr, status = run(host.url, list)

          expect(status.exitstatus).to eq(3)
          expect(stderr).to include("no era")
        end
      end
    end

    it "exits 3 when nothing is listening" do
      port = with_host(&:port)
      with_list("199b08\n") do |list|
        _stdout, _stderr, status = run("http://127.0.0.1:#{port}", list, "--timeout=2")

        expect(status.exitstatus).to eq(3)
      end
    end
  end

  describe "usage" do
    it "exits 2 when the allow-list file does not exist" do
      with_host(body: version_body) do |host|
        _stdout, stderr, status = run(host.url, "/no/such/expected-era")

        expect(status.exitstatus).to eq(2)
        expect(stderr).to include("cannot read")
      end
    end

    it "exits 2 without both arguments" do
      _stdout, stderr, status = run("http://127.0.0.1:1")

      expect(status.exitstatus).to eq(2)
      expect(stderr).to include("usage")
    end
  end
end
