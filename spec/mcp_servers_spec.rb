require "spec_helper"
require "fileutils"
require "open3"
require "rbconfig"
require "socket"
require "stringio"
require "tmpdir"

# The two stdio MCP servers, `bin/hecks_mcp_door` and `bin/hecks_query_ir_mcp`, as
# processes: what they refuse to start as, what they print, and what a caller who
# supplies no identity gets. The bus's own rules are in `spec/storehouse_spec.rb`; this
# file proves the same refusals reach a caller of the real door, and that the
# transport gate in `Hecks::McpStdioGuard` holds. Identity here is self-asserted, and
# nothing in this file claims otherwise.
RSpec.describe "the stdio MCP servers" do
  let(:root)               { File.expand_path("..", __dir__) }
  let(:door)               { File.join(root, "bin/hecks_mcp_door") }
  let(:query_ir)           { File.join(root, "bin/hecks_query_ir_mcp") }
  let(:initialize_request) { { jsonrpc: "2.0", id: 1, method: "initialize" } }

  # Runs a server to completion over pipes, feeding it one JSON-RPC request per line.
  def run_over_pipes(script, requests = [], args: [], env: {})
    input = requests.map { |request| "#{JSON.generate(request)}\n" }.join
    out, err, status = Open3.capture3(env, RbConfig.ruby, script, *args, chdir: root, stdin_data: input)
    { out: out, err: err, status: status, responses: out.lines.map { |line| JSON.parse(line) } }
  end

  def tool_call(id, name, arguments)
    { jsonrpc: "2.0", id: id, method: "tools/call", params: { name: name, arguments: arguments } }
  end

  # Runs a server with `socket` as its stdin, which is how an `inetd` or `socat` wrapper starts it.
  def run_over_socket(script, socket)
    out_read, out_write = IO.pipe
    err_read, err_write = IO.pipe
    pid = Process.spawn(RbConfig.ruby, script, chdir: root, in: socket, out: out_write, err: err_write)
    out_write.close
    err_write.close
    _, status = Process.wait2(pid)
    { out: out_read.read, err: err_read.read, status: status }
  ensure
    [out_read, err_read].compact.each(&:close)
  end

  %w[hecks_mcp_door hecks_query_ir_mcp].each do |name|
    describe "bin/#{name}" do
      let(:script) { File.join(root, "bin", name) }

      it "starts over pipes with --stdio, answers on stdout with protocol only, and warns on stderr" do
        result = run_over_pipes(script, [initialize_request], args: ["--stdio"])

        expect(result[:status]).to be_success
        expect(result[:responses].length).to eq(1)
        expect(result[:responses].first["result"]["protocolVersion"]).to eq("2024-11-05")
        expect(result[:err]).to include("stdio only")
        expect(result[:err]).to include("no authentication")
        expect(result[:out]).not_to include("stdio only")
      end

      it "refuses a network option given as an argument, before answering anything" do
        result = run_over_pipes(script, [initialize_request], args: ["--port", "8080"])

        expect(result[:status].exitstatus).to eq(Hecks::McpStdioGuard::EXIT_STATUS)
        expect(result[:err]).to include("refusing to start")
        expect(result[:err]).to include("--port")
        expect(result[:out]).to be_empty
      end

      it "refuses a network option given in the environment" do
        result = run_over_pipes(script, [initialize_request], env: { "HECKS_MCP_PORT" => "8080" })

        expect(result[:status].exitstatus).to eq(Hecks::McpStdioGuard::EXIT_STATUS)
        expect(result[:err]).to include("HECKS_MCP_PORT")
        expect(result[:out]).to be_empty
      end

      it "refuses to run with a network socket as stdin, the way a socat or inetd wrapper starts it" do
        listener = TCPServer.new("127.0.0.1", 0)
        client   = TCPSocket.new("127.0.0.1", listener.addr[1])
        served   = listener.accept
        client.puts(JSON.generate(initialize_request))

        result = run_over_socket(script, served)

        expect(result[:status].exitstatus).to eq(Hecks::McpStdioGuard::EXIT_STATUS)
        expect(result[:err]).to include("stdin is a network (IP) socket")
        expect(result[:out]).to be_empty
      ensure
        [client, served, listener].compact.each(&:close)
      end

      it "runs with a Unix-domain socket as stdin, which is what some MCP clients spawn servers over" do
        parent, child = UNIXSocket.pair
        parent.puts(JSON.generate(initialize_request))
        parent.close_write

        result = run_over_socket(script, child)

        expect(result[:status]).to be_success
        expect(JSON.parse(result[:out])["result"]["serverInfo"]["name"]).to start_with("hecks-")
      ensure
        [parent, child].compact.each { |socket| socket.close unless socket.closed? }
      end
    end
  end

  describe "bin/hecks_mcp_door" do
    it "warns, refuses a role-gated dispatch with no role, runs a query, and refuses a domain outside the root" do
      run = run_over_pipes(
        door,
        [tool_call(1, "dispatch", { domain: "examples/pizzas", command: "create_pizza",
                                         summary: "spec", args: {} }),
         tool_call(2, "query", { domain: "examples/pizzas", question: "available", summary: "spec" }),
         tool_call(3, "catalog", { domain: "/tmp/outside_the_root" })]
      )
      results = run[:responses].to_h { |response| [response["id"], response["result"]] }
      refusal = JSON.parse(results[1]["content"].first["text"])

      expect(results[1]["isError"]).to be true
      expect(refusal["error"]).to include('requires role: "Chef"', "no caller")
      expect(results[2]["isError"]).to be false
      expect(results[3]["isError"]).to be true
      expect(results[3]["content"].first["text"]).to include("resolves outside")
      expect(run[:err]).to include("Identity is self-asserted", "not verified", "no role check at all")
    end
  end

  describe "bin/hecks_query_ir_mcp" do
    it "refuses a domains directory outside the project root rather than loading Ruby from it" do
      outside = Dir.mktmpdir("hecks-mcp-outside")
      marker  = File.join(outside, "loaded")
      FileUtils.mkdir_p(File.join(outside, "bluebook"))
      File.write(File.join(outside, "bluebook", "evil.bluebook"), "File.write(#{marker.inspect}, 'ran')\n")

      response = run_over_pipes(query_ir, [tool_call(1, "query_ir_duplicates", { domains: [outside] })])
                 .fetch(:responses).first

      expect(response["result"]["isError"]).to be true
      expect(response["result"]["content"].first["text"]).to include("resolves outside")
      expect(File).not_to exist(marker)
    ensure
      FileUtils.rm_rf(outside)
    end

    it "warns that it asks for no identity, and accepts a domains directory inside the project root" do
      run = run_over_pipes(
        query_ir,
        [tool_call(1, "query_ir_duplicates", { domains: ["examples/no_such_domain"], include_meta: false })]
      )

      expect(run[:responses].first["result"]["isError"]).to be false
      expect(run[:err]).to include("No identity is asked for or checked")
    end
  end

  describe Hecks::McpStdioGuard do
    let(:pipe_in)  { IO.pipe }
    let(:pipe_out) { IO.pipe }

    after { (pipe_in + pipe_out).each { |io| io.close unless io.closed? } }

    def violations(**overrides)
      described_class.violations(argv: [], env: {}, stdin: pipe_in.first, stdout: pipe_out.last, **overrides)
    end

    it "finds no violation for pipes, no arguments and no options" do
      expect(violations).to eq([])
    end

    it "accepts --stdio and HECKS_MCP_TRANSPORT=stdio" do
      expect(violations(argv: ["--stdio"], env: { "HECKS_MCP_TRANSPORT" => "stdio" })).to eq([])
    end

    it "names every unaccepted argument" do
      expect(violations(argv: ["--http", "--bind=0.0.0.0"]).length).to eq(2)
    end

    it "refuses any other HECKS_MCP_ variable, including a non-stdio transport" do
      found = violations(env: { "HECKS_MCP_TRANSPORT" => "http", "HECKS_MCP_HOST" => "0.0.0.0", "HOME" => "/x" })

      expect(found.length).to eq(2)
      expect(found.join).to include("HECKS_MCP_TRANSPORT", "HECKS_MCP_HOST")
      expect(found.join).not_to include("HOME")
    end

    it "refuses an IP socket on either stream" do
      listener = TCPServer.new("127.0.0.1", 0)
      client   = TCPSocket.new("127.0.0.1", listener.addr[1])
      served   = listener.accept

      expect(violations(stdin: served).join).to include("stdin is a network")
      expect(violations(stdout: served).join).to include("stdout is a network")
    ensure
      [client, served, listener].compact.each(&:close)
    end

    it "accepts a Unix-domain socket on both streams" do
      left, right = UNIXSocket.pair

      expect(violations(stdin: left, stdout: right)).to eq([])
    ensure
      [left, right].compact.each(&:close)
    end

    it "prefixes every banner line with the server name and puts the server's notes after the common ones" do
      lines = described_class.banner(server: "demo", notes: ["extra note"])

      expect(lines).to all(start_with("demo: "))
      expect(lines.last).to eq("demo: extra note")
      expect(lines.first).to include("stdio only")
    end

    it "writes the warning to the stream it is given and exits nothing when the setup is stdio" do
      stderr = StringIO.new

      described_class.start!(server: "demo", notes: ["extra"], argv: [], env: {}, stdin: pipe_in.first,
                             stdout: pipe_out.last, stderr: stderr)

      expect(stderr.string).to include("demo: extra")
    end

    it "exits with the guard's status and writes the refusal, not the warning, on a violation" do
      stderr = StringIO.new

      expect do
        described_class.start!(server: "demo", argv: ["--port"], env: {}, stdin: pipe_in.first,
                               stdout: pipe_out.last, stderr: stderr)
      end.to raise_error(SystemExit) { |error| expect(error.status).to eq(described_class::EXIT_STATUS) }

      expect(stderr.string).to include("demo: refusing to start")
      expect(stderr.string).not_to include("no authentication")
    end
  end
end
