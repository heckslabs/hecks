# = Cross-Target Parity Spec
#
# Builds the Pizzas domain into both Ruby (static) and Go targets, boots both
# HTTP servers, runs the same command sequence against each via browser-style
# form submission, fetches /_events from each, and asserts that the normalized
# event name lists are identical.
#
# Tagged :parity — excluded from the default sub-second RSpec run.
# Run explicitly:
#   bundle exec rspec hecksties/spec/cross_target_parity_spec.rb --tag parity
#
require "spec_helper"
require "net/http"
require "uri"
require "json"
require "tmpdir"
require "fileutils"

# Load static targets (not in the default bundle path)
$LOAD_PATH.unshift(File.expand_path("../../hecks_targets/ruby/lib", __dir__))
$LOAD_PATH.unshift(File.expand_path("../../hecks_targets/go/lib", __dir__))
require "hecks_static"
require "go_hecks"

def normalize_events(json)
  json.map { |e| e["name"] }.sort
end

def free_port
  require "socket"
  s = TCPServer.new(0)
  port = s.addr[1]
  s.close
  port
end

def wait_for_server(url, timeout: 20)
  deadline = Time.now + timeout
  uri = URI(url)
  loop do
    Net::HTTP.get_response(uri)
    return true
  rescue Errno::ECONNREFUSED, Errno::ECONNRESET, EOFError, Net::ReadTimeout
    raise "Server at #{url} did not start in #{timeout}s" if Time.now > deadline
    sleep 0.5
  end
end

# Browser-style form submission: GET the form page, parse the action URL,
# POST form-urlencoded data. Handles route differences between Ruby (/submit)
# and Go (direct POST) transparently.
def submit_form(base_url, form_path, params)
  html = Net::HTTP.get(URI("#{base_url}#{form_path}"))
  action = html.match(/<form[^>]*action="([^"]*)"/)&.captures&.first
  raise "No form action found at #{form_path} on #{base_url}" unless action
  Net::HTTP.post_form(URI("#{base_url}#{action}"), params)
end

def run_command_sequence(base_url)
  submit_form(base_url, "/pizzas/create_pizza/new",
              "name" => "Margherita", "description" => "Classic tomato and mozzarella")
  submit_form(base_url, "/pizzas/create_pizza/new",
              "name" => "Pepperoni", "description" => "Spicy pepperoni")
  submit_form(base_url, "/pizzas/create_pizza/new",
              "name" => "Veggie", "description" => "Garden fresh")
end

def fetch_events(base_url)
  uri = URI("#{base_url}/_events")
  req = Net::HTTP::Get.new(uri)
  req["Accept"] = "application/json"
  res = Net::HTTP.start(uri.host, uri.port) { |h| h.request(req) }
  JSON.parse(res.body)
rescue => e
  raise "Failed to fetch /_events from #{base_url}: #{e.message}"
end

RSpec.describe "Cross-target behavioral parity: Ruby vs Go", :parity do
  before(:all) do
    skip "go not installed" unless system("which go > /dev/null 2>&1")

    bluebook = File.join(__dir__, "../../examples/pizzas/PizzasBluebook")
    domain = eval(File.read(bluebook), TOPLEVEL_BINDING, bluebook, 1)

    @ruby_dir = Dir.mktmpdir("hecks-ruby-parity-")
    @go_dir   = Dir.mktmpdir("hecks-go-parity-")

    ruby_root = Hecks.build_static(domain, output_dir: @ruby_dir, smoke_test: false)
    go_root   = Hecks.build_go(domain, output_dir: @go_dir, smoke_test: false)

    # Build Go binary for fast startup (tidy first to resolve go.sum)
    @go_bin = File.join(@go_dir, "pizzas_server")
    system("go", "mod", "tidy", chdir: go_root, out: "/dev/null", err: "/dev/null")
    ok = system("go", "build", "-o", @go_bin, "./cmd/pizzas/", chdir: go_root)
    skip "go build failed" unless ok && File.exist?(@go_bin)

    @ruby_port = free_port
    @go_port   = free_port

    ruby_bin = File.join(ruby_root, "bin", "pizzas")
    @ruby_pid = spawn(RbConfig.ruby, ruby_bin, "serve", @ruby_port.to_s,
                      out: "/dev/null", err: "/dev/null")
    go_views  = File.join(go_root, "views")
    @go_pid   = spawn({ "VIEWS_DIR" => go_views }, @go_bin, @go_port.to_s,
                      out: "/dev/null", err: "/dev/null", in: "/dev/null")

    wait_for_server("http://localhost:#{@ruby_port}/")
    wait_for_server("http://localhost:#{@go_port}/")
  end

  after(:all) do
    [@ruby_pid, @go_pid].each do |pid|
      next unless pid
      Process.kill("TERM", pid) rescue nil
      Process.wait(pid) rescue nil
    end
    FileUtils.rm_rf(@ruby_dir) if @ruby_dir
    FileUtils.rm_rf(@go_dir)   if @go_dir
  end

  it "produces identical event name lists after the same command sequence" do
    ruby_base = "http://localhost:#{@ruby_port}"
    go_base   = "http://localhost:#{@go_port}"

    run_command_sequence(ruby_base)
    run_command_sequence(go_base)

    ruby_events = fetch_events(ruby_base)
    go_events   = fetch_events(go_base)

    ruby_names = normalize_events(ruby_events)
    go_names   = normalize_events(go_events)

    expect(ruby_names).not_to be_empty, "Ruby server produced no events"
    expect(go_names).not_to be_empty,   "Go server produced no events"
    expect(ruby_names).to eq(go_names)
  end
end
