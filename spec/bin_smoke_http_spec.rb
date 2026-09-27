require "open3"
require "tmpdir"
require "openssl"
require "socket"
require "json"

# bin/smoke_http against a fake receiver on a local port. The fake verifies
# signatures the way a real receiver does, so the script's checks are proven both
# to pass a correct receiver and to catch one that verifies badly.
RSpec.describe "bin/smoke_http", :io do
  SMOKE_HTTP_SCRIPT = File.join(InMemoryDomain::ROOT, "bin/smoke_http").freeze
  SMOKE_HTTP_SECRET = "webhook-secret".freeze

  # A minimal HTTP/1.1 server on a thread: `handler` answers [status, body] for each
  # parsed request, and `seen` collects what was delivered.
  class FakeReceiver
    attr_reader :port, :seen

    def initialize(&handler)
      @handler = handler
      @seen = []
      @server = TCPServer.new("127.0.0.1", 0)
      @port = @server.addr[1]
      @thread = Thread.new { serve }
    end

    def stop
      @thread.kill
      @server.close
    end

    private

    def serve
      loop { Thread.new(@server.accept) { |client| answer(client) } }
    rescue IOError
      nil
    end

    def answer(client)
      request = read_request(client)
      @seen << request
      status, body = @handler.call(request)
      client.write("HTTP/1.1 #{status} X\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
    ensure
      client.close
    end

    def read_request(client)
      method, target, = client.gets.split
      headers = {}
      while (line = client.gets) && line != "\r\n"
        name, value = line.chomp.split(": ", 2)
        headers[name.downcase] = value
      end
      body = client.read(headers.fetch("content-length", "0").to_i)
      { method: method, target: target, headers: headers, body: body }
    end
  end

  def hmac(text, secret = SMOKE_HTTP_SECRET)
    OpenSSL::HMAC.hexdigest("SHA256", secret, text)
  end

  # Whether the header carries a valid signature for the body under the scheme.
  def verified?(request, scheme:, header: "x-signature")
    value = request[:headers][header]
    return false unless value

    case scheme
    when "timestamped"
      stamp = value[/t=(\d+)/, 1]
      stamp && value[/v1=(\h+)/, 1] == hmac("#{stamp}.#{request[:body]}")
    when "sha256" then value == "sha256=#{hmac(request[:body])}"
    else value == hmac(request[:body])
    end
  end

  # A correct receiver: refuses bad signatures with 400, counts each distinct event
  # once however often it is delivered, and reports the count on GET /state.
  def correct_receiver(scheme: "timestamped", header: "x-signature", counting: true)
    events = []
    FakeReceiver.new do |request|
      case [request[:method], request[:target]]
      when ["GET", "/health"] then [200, "ok"]
      when ["GET", "/state"] then [200, JSON.generate(count: events.size)]
      when ["POST", "/hooks"]
        next [400, "bad signature"] unless verified?(request, scheme: scheme, header: header)

        id = JSON.parse(request[:body])["id"]
        events << id unless counting && events.include?(id)
        [200, "ok"]
      else [404, "no"]
      end
    end
  end

  def run_script(receiver, *args, secret: SMOKE_HTTP_SECRET)
    env = { "SMOKE_WEBHOOK_SECRET" => secret }
    Open3.capture3(env, SMOKE_HTTP_SCRIPT, "--url", "http://127.0.0.1:#{receiver.port}", "--path", "/hooks", *args)
  end

  around do |example|
    @receiver = nil
    example.run
    @receiver&.stop
  end

  it "passes a receiver that verifies signatures and treats a repeat delivery as idempotent" do
    @receiver = correct_receiver
    stdout, stderr, status = run_script(@receiver, "--health-path", "/health", "--state-path", "/state")

    expect(stderr).to eq("")
    expect(status).to be_success
    expect(stdout).to include("SMOKE HTTP PASSED")
    expect(stdout.scan("... ok").size).to eq(6)
  end

  it "delivers the signed payload twice and the bad ones once each" do
    @receiver = correct_receiver
    run_script(@receiver)

    posts = @receiver.seen.select { |request| request[:method] == "POST" }
    expect(posts.size).to eq(5)
    expect(posts.count { |request| verified?(request, scheme: "timestamped") }).to eq(2)
  end

  %w[sha256 hex].each do |scheme|
    it "signs with the #{scheme} scheme when asked to" do
      @receiver = correct_receiver(scheme: scheme, header: "x-hub-signature")
      stdout, _stderr, status = run_script(@receiver, "--scheme", scheme, "--header", "X-Hub-Signature")

      expect(status).to be_success, stdout
    end
  end

  it "takes the payload from a file" do
    @receiver = correct_receiver
    Dir.mktmpdir do |dir|
      file = File.join(dir, "event.json")
      File.write(file, JSON.generate(id: "from-file", type: "x"))
      _stdout, _stderr, status = run_script(@receiver, "--payload-file", file)

      expect(status).to be_success
    end
    expect(@receiver.seen.map { |request| request[:body] }).to include(JSON.generate(id: "from-file", type: "x"))
  end

  it "fails a receiver that accepts a delivery it should have refused" do
    @receiver = FakeReceiver.new { |_request| [200, "ok"] }
    stdout, _stderr, status = run_script(@receiver)

    expect(status.exitstatus).to eq(1)
    expect(stdout).to include("a delivery with no signature is refused... FAILED")
    expect(stdout).to include("a delivery signed with the wrong secret is refused... FAILED")
    expect(stdout).to include("a delivery whose body changed after signing is refused... FAILED")
    expect(stdout).to include("a correctly signed delivery is accepted... ok")
    expect(stdout).to include("SMOKE HTTP FAILED (3)")
  end

  it "fails a receiver that counts a repeated delivery twice" do
    @receiver = correct_receiver(counting: false)
    stdout, _stderr, status = run_script(@receiver, "--state-path", "/state")

    expect(status.exitstatus).to eq(1)
    expect(stdout).to include("the state changed on a repeated delivery")
    expect(stdout).to include("SMOKE HTTP FAILED (1)")
  end

  it "fails a receiver that errors on a repeated delivery, and one whose health route is down" do
    seen_signed = 0
    @receiver = FakeReceiver.new do |request|
      next [503, "down"] if request[:target] == "/health"

      good = verified?(request, scheme: "timestamped")
      seen_signed += 1 if good
      next [400, ""] unless good

      seen_signed > 1 ? [500, "duplicate"] : [200, ""]
    end
    stdout, _stderr, status = run_script(@receiver, "--health-path", "/health")

    expect(status.exitstatus).to eq(1)
    expect(stdout).to include("GET /health answers 200... FAILED: expected 200, got 503")
    expect(stdout).to include("accepted again, not an error... FAILED: expected 2xx, got 500")
  end

  it "runs every check even when the first ones fail" do
    @receiver = FakeReceiver.new { |_request| [500, "broken"] }
    stdout, _stderr, status = run_script(@receiver)

    expect(status.exitstatus).to eq(1)
    expect(stdout).to include("SMOKE HTTP FAILED (5)")
  end

  it "refuses to run without a secret, a path, or with an unknown scheme" do
    stdout, stderr, status = Open3.capture3({ "SMOKE_WEBHOOK_SECRET" => "" }, SMOKE_HTTP_SCRIPT, "--path", "/hooks")
    expect(status).not_to be_success
    expect(stdout).to eq("")
    expect(stderr).to include("no signing secret")

    _stdout, stderr, status = Open3.capture3({ "SMOKE_WEBHOOK_SECRET" => "s" }, SMOKE_HTTP_SCRIPT)
    expect(status).not_to be_success
    expect(stderr).to include("no webhook path")

    _stdout, stderr, status = Open3.capture3({ "SMOKE_WEBHOOK_SECRET" => "s" }, SMOKE_HTTP_SCRIPT,
                                             "--path", "/x", "--scheme", "md5")
    expect(status).not_to be_success
    expect(stderr).to include("unknown scheme \"md5\"")
  end
end
