require "socket"
require "json"
require "tmpdir"
require "hecks/ports/persistence/plugins/era/expected_era"
require "hecks/cli/check_era"

# The era check (Hecks::CLI::CheckEra) and the library under it, against a stub host that serves
# `GET /version` the way rust/host's `version_router` does. The stub is a
# bare TCPServer on an ephemeral port: it answers one canned response per
# connection and records what was requested.
RSpec.describe "the era check", :io do
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

  def assess(url, list, timeout: 2) = Hecks::CLI::CheckEra.assess(url, list, timeout: timeout)

  def unreachable = Hecks::Runtime::EraCheck::ExpectedEra::Unreachable

  def bad_response = Hecks::Runtime::EraCheck::ExpectedEra::BadResponse

  # Assesses a host reporting `reported_era` against an allow-list file holding `list_text`.
  def assessed(list_text, reported_era = "199b08")
    with_host(body: version_body(reported_era)) do |host|
      with_list(list_text) { |list| yield host, assess(host.url, list) }
    end
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
    it "adds /version to a base URL and leaves a /version URL alone", :aggregate_failures do
      expect(era_check.version_url("https://host.example")).to eq("https://host.example/version")
      expect(era_check.version_url("https://host.example/")).to eq("https://host.example/version")
      expect(era_check.version_url("https://host.example/version")).to eq("https://host.example/version")
    end
  end

  describe "against a host" do
    it "finds the reported era on the list", :aggregate_failures do
      assessed("# eras\n199b08\n") do |host, finding|
        expect(finding.verdict.status).to eq(:match)
        expect(finding.line).to include("199b08")
        expect(host.requests.first).to eq("GET /version HTTP/1.1")
      end
    end

    it "finds the reported era off the list", :aggregate_failures do
      assessed("aaa111\nbbb222\n") do |_host, finding|
        expect(finding.verdict.status).to eq(:mismatch)
        expect(finding.verdict).not_to be_ok
        expect(finding.line).to include("199b08", "aaa111, bbb222")
      end
    end

    it "only checks that an era is reported when the list names none", :aggregate_failures do
      assessed("# nothing listed\n") do |_host, finding|
        expect(finding.verdict.status).to eq(:unlisted)
        expect(finding.verdict).to be_ok
        expect(finding.line).to include("lists no era")
      end
    end

    it "accepts the /version URL itself" do
      with_host(body: version_body("199b08")) do |host|
        with_list("199b08\n") do |list|
          expect(assess("#{host.url}/version", list).verdict.status).to eq(:match)
        end
      end
    end

    it "refuses a host that answers something other than 200" do
      with_host(status: 502, body: "bad gateway") do |host|
        with_list("199b08\n") do |list|
          expect { assess(host.url, list) }.to raise_error(unreachable, /502/)
        end
      end
    end

    it "refuses a body that is not a version document" do
      with_host(body: "<html>not json</html>") do |host|
        with_list("199b08\n") do |list|
          expect { assess(host.url, list) }.to raise_error(bad_response, /JSON version document/)
        end
      end
    end

    it "refuses a document that carries no era" do
      with_host(body: JSON.generate("build" => "2.5.1")) do |host|
        with_list("199b08\n") do |list|
          expect { assess(host.url, list) }.to raise_error(bad_response, /no era/)
        end
      end
    end

    it "refuses a host nothing is listening on" do
      port = with_host(&:port)
      with_list("199b08\n") do |list|
        expect { assess("http://127.0.0.1:#{port}", list) }.to raise_error(unreachable, /could not be reached/)
      end
    end
  end

  describe "a missing allow-list file" do
    it "is refused before the host is asked" do
      with_host(body: version_body) do |host|
        expect { assess(host.url, "/no/such/expected-era") }.to raise_error(Errno::ENOENT)
      end
    end
  end
end
