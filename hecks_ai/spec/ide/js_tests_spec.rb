# Hecks IDE JavaScript Tests — Headless
#
# Starts IDE server, opens page in headless Chrome, triggers test:run
# via /bus, polls /console/log for results. All 26 JS tests must pass.
#
require "net/http"
require "json"
require "timeout"

RSpec.describe "IDE JavaScript tests (headless)", :slow do
  let(:port) { 5099 }
  let(:base) { "http://localhost:#{port}" }

  around do |example|
    gem_dir = File.expand_path("../../..", __dir__)
    @server_pid = spawn(
      "ruby",
      "-I#{gem_dir}/hecks_ai/lib",
      "-I#{gem_dir}/hecks_workshop/lib",
      "-I#{gem_dir}/bluebook/lib",
      "-I#{gem_dir}/hecksties/lib",
      "-I#{gem_dir}/hecksagon/lib",
      "-I#{gem_dir}/lib",
      "-e", "require 'hecks_ai/ide/server'; Hecks::AI::IDE::Server.new(project_dir: '#{gem_dir}', port: #{port}).run",
      [:out, :err] => "/dev/null"
    )

    wait_for_server
    example.run
  ensure
    Process.kill(:TERM, @chrome_pid) rescue nil if @chrome_pid
    Process.kill(:TERM, @server_pid) rescue nil
    Process.wait(@server_pid) rescue nil
  end

  it "serves valid JS" do
    js = Net::HTTP.get(URI("#{base}/ide.js"))
    File.write("/tmp/hecks_ide_check.js", js)
    result = `node --check /tmp/hecks_ide_check.js 2>&1`
    expect($?.success?).to be(true), "JS syntax error: #{result}"
  end

  it "passes all 26 JS tests in headless Chrome" do
    # Launch headless Chrome
    @chrome_pid = spawn(
      "google-chrome", "--headless", "--disable-gpu", "--no-sandbox",
      "--remote-debugging-port=0", "#{base}/",
      [:out, :err] => "/dev/null"
    ) rescue spawn(
      "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
      "--headless", "--disable-gpu", "--no-sandbox",
      "#{base}/",
      [:out, :err] => "/dev/null"
    )

    # Wait for page to load and boot
    sleep 3

    # Trigger tests via bus
    post_json("#{base}/bus", event: "test:run")

    # Poll console log for results
    result_line = nil
    Timeout.timeout(30) do
      loop do
        sleep 1
        logs = get_json("#{base}/console/log")["logs"] || []
        result_line = logs.find { |l| l.include?("IDE Tests:") && l.include?("passed") }
        break if result_line
      end
    end

    expect(result_line).to include("passed")
    expect(result_line).not_to include("failed") unless result_line.include?("0 failed")

    # Extract counts
    match = result_line.match(/(\d+)\/(\d+) passed/)
    if match
      passed, total = match[1].to_i, match[2].to_i
      expect(passed).to eq(total), "#{total - passed} tests failed: #{result_line}"
    end
  end

  it "all endpoints respond" do
    %w[/ /ide.js /bluebooks /sessions /docs /context].each do |path|
      resp = Net::HTTP.get_response(URI("#{base}#{path}"))
      expect(resp.code).to eq("200"), "#{path} returned #{resp.code}"
    end
  end

  private

  def wait_for_server
    10.times do
      Net::HTTP.get(URI("#{base}/"))
      return
    rescue Errno::ECONNREFUSED
      sleep 0.5
    end
    raise "Server didn't start"
  end

  def post_json(url, **data)
    uri = URI(url)
    req = Net::HTTP::Post.new(uri, "Content-Type" => "application/json")
    req.body = JSON.generate(data)
    Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(req) }
  end

  def get_json(url)
    JSON.parse(Net::HTTP.get(URI(url)))
  end
end
