require "json"
require "open3"
require "stringio"
require "tmpdir"

# Runs the MCP server the way `.mcp.json` does, in a child process, and reads what it answered.
# The goldens in spec/fixtures/mcp_light were written by the server before it loaded lazily.
module McpLightHelper
  ROOT_MARKER = "<ROOT>".freeze

  MODES = {
    "unrestricted" => {},
    "readers"      => { "HECKS_SERVER_TOOLS" => "readers", "HECKS_SERVER_DOMAINS" => "examples/pizzas" },
    "commands"     => { "HECKS_SERVER_TOOLS" => "commands", "HECKS_SERVER_DOMAINS" => "examples/pizzas",
                        "HECKS_SERVER_COMMANDS" => "Order.create_pizza!,Order.purchase!" }
  }.freeze

  REQUESTS = [
    { "jsonrpc" => "2.0", "id" => 1, "method" => "initialize", "params" => {} },
    { "jsonrpc" => "2.0", "id" => 2, "method" => "ping" },
    { "jsonrpc" => "2.0", "id" => 3, "method" => "tools/list" }
  ].freeze

  # Reports, after the server ends, whether the framework loaded and the process's resident memory.
  CHILD = <<~RUBY.freeze
    require "hecks/tools/mcp"
    at_exit do
      kb = `ps -o rss= -p \#{Process.pid}`.to_i
      $stderr.puts "probe framework=\#{defined?(Hecks::Assembly) ? 1 : 0} rss_kb=\#{kb}"
    end
    Hecks::Tools::Mcp.call(ARGV)
  RUBY

  # The same probe around the query-ir server.
  QUERY_IR_CHILD = CHILD.sub('require "hecks/tools/mcp"', 'require "hecks/tools/serve_query_ir_mcp"')
                        .sub("Hecks::Tools::Mcp.call(ARGV)", "Hecks::Tools::ServeQueryIrMcp.call(ARGV)").freeze

  def repo_root = File.expand_path("../..", __dir__)

  # Starts the query-ir server on `requests` and returns [stdout, probe].
  def run_query_ir(requests = REQUESTS)
    out, err, = Open3.capture3("ruby", "-I", "lib", "-e", QUERY_IR_CHILD, "--", stdin_data: lines_of(requests),
                                                                                chdir:      repo_root)
    [out, probe_of(err)]
  end

  def golden(mode) = File.read(File.join(repo_root, "spec/fixtures/mcp_light/#{mode}.jsonl"))

  def lines_of(requests) = requests.map { |request| JSON.generate(request) }.join("\n") << "\n"

  # Starts the server on `requests`, with the mode's environment, and returns [stdout, probe].
  def run_server(mode, requests = REQUESTS)
    out, err, = run_raw(MODES.fetch(mode), requests)
    [out.gsub(repo_root, ROOT_MARKER), probe_of(err)]
  end

  # Starts the server with exactly these extra variables on `requests` (text or request hashes) and
  # returns [stdout, stderr, status], so a refusal at start can be seen as the client would.
  def run_raw(env, requests = REQUESTS)
    input = requests.is_a?(String) ? requests : lines_of(requests)
    scrubbed = { "HECKS_CACHE_DIR" => cache_dir, "CLAUDE_CODE_AGENT" => nil }
    out, err, status = Open3.capture3(scrubbed.merge(env), "ruby", "-I", "lib", "-e", CHILD, "--",
                                      stdin_data: input, chdir: repo_root)
    [out, err, status]
  end

  # The cache directory a child server uses: the specs' own when set, else a scratch one.
  def cache_dir = ENV["HECKS_CACHE_DIR"] || (@scratch_cache ||= Dir.mktmpdir("mcp-light-cache"))

  # Whether `ps` can report a process's resident memory here, as the memory examples need.
  def rss_readable? = !IO.popen(["ps", "-o", "rss=", "-p", Process.pid.to_s], err: File::NULL, &:read).to_s.strip.empty?

  def probe_of(err)
    found = err.match(/probe framework=(\d) rss_kb=(\d+)/)
    { framework: found && found[1] == "1", rss_mb: found && (found[2].to_i / 1024.0) }
  end

  # The same replies from this process, which has the framework loaded.
  def replies_in_process(mode)
    mcp = Hecks::Adapters::Driving::Mcp
    mcp.instance_variable_set(:@scope, Hecks::Adapters::Driving::McpScope.from_env(MODES.fetch(mode)))
    capture_stdout { REQUESTS.each { |request| mcp.handle(request) } }.gsub(repo_root, ROOT_MARKER)
  ensure
    mcp.instance_variable_set(:@scope, nil)
  end

  def capture_stdout
    original = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original
  end
end
