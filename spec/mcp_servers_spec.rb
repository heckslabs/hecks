require "spec_helper"
require "fileutils"
require "open3"
require "rbconfig"
require "socket"
require "stringio"
require "tmpdir"

# Process-level checks for the stdio MCP doors (bin/hecks_mcp_door,
# bin/hecks_query_ir_mcp): what they refuse, print, and require of a caller.
# Identity here is self-asserted only; nothing in this file claims otherwise.
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

  # Copies the pizzas example under root_dir, rebound from PostgresEra to Memory, so
  # the door examples below need no database to prove the door's refusals and framing.
  def memory_pizzas_under(root_dir)
    target = File.join(root_dir, "pizzas")
    FileUtils.cp_r(File.join(root, "examples/pizzas/bluebook"), target)
    FileUtils.rm_f(File.join(target, "pizzas.world"))
    hecksagon = File.join(target, "pizzas.hecksagon")
    File.write(hecksagon, File.read(hecksagon).gsub('persisted_by("PostgresEra")', 'persisted_by("Memory")'))
    "pizzas"
  end

  describe "bin/hecks_mcp_door" do
    let(:sandbox_root) { Dir.mktmpdir("hecks-mcp-door-root") }

    after { FileUtils.rm_rf(sandbox_root) }

    it "warns, refuses a role-gated dispatch with no role, runs a query, and refuses a domain outside the root" do
      domain = memory_pizzas_under(sandbox_root)
      run = run_over_pipes(
        door,
        [tool_call(1, "dispatch", { domain: domain, command: "create_pizza", summary: "spec", args: {} }),
         tool_call(2, "query", { domain: domain, question: "available", summary: "spec" }),
         tool_call(3, "catalog", { domain: "/tmp/outside_the_root" })],
        env: { "HECKS_STOREHOUSE_ROOT" => sandbox_root }
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

  # Reader mode (ADR 0072 decision 2): a spawner narrows the door to reader tools over the
  # domains it names. It limits reach and identifies no one.
  describe "bin/hecks_mcp_door in reader mode" do
    let(:sandbox_root) { Dir.mktmpdir("hecks-mcp-door-reader") }
    let(:domain)       { memory_pizzas_under(sandbox_root) }
    let(:marker)       { File.join(sandbox_root, "unnamed-domain-loaded") }
    let(:reader_env) do
      { "HECKS_STOREHOUSE_ROOT" => sandbox_root, "HECKS_DOOR_TOOLS" => "readers", "HECKS_DOOR_DOMAINS" => domain }
    end

    after { FileUtils.rm_rf(sandbox_root) }

    def results_of(run) = run[:responses].to_h { |response| [response["id"], response["result"]] }

    def payload(result) = JSON.parse(result["content"].first["text"])

    # A domain under the root whose hecksagon writes `marker` when it is loaded.
    def unnamed_domain
      FileUtils.mkdir_p(File.join(sandbox_root, "unnamed"))
      File.write(File.join(sandbox_root, "unnamed", "unnamed.hecksagon"), "File.write(#{marker.inspect}, 'ran')\n")
      "unnamed"
    end

    it "answers catalog, describe and state for a named domain, lists only reader tools, and says so on stderr" do
      run = run_over_pipes(
        door,
        [{ jsonrpc: "2.0", id: 1, method: "tools/list" },
         tool_call(2, "catalog", { domain: domain }),
         tool_call(3, "describe", { domain: domain }),
         tool_call(4, "state", { domain: domain, aggregate: "Order", summary: "spec" })],
        env: reader_env
      )
      results = results_of(run)

      expect(results[1]["tools"].map { |tool| tool["name"] }).to match_array(Hecks::McpDoorScope::READER_TOOLS)
      expect([2, 3, 4].map { |id| results[id]["isError"] }).to all(be false)
      expect(payload(results[2])["aggregates"].map { |aggregate| aggregate["name"] }).to include("Order")
      expect(payload(results[4])["count"]).to eq(0)
      expect(run[:err]).to include("Reader mode (HECKS_DOOR_TOOLS=readers)", "identifies no one")
      expect(run[:err]).not_to include("anyone who can write to stdin can run it")
    end

    it "refuses dispatch, a dry run and behaviors, naming the mode" do
      results = results_of(run_over_pipes(
                             door,
                             [tool_call(1, "dispatch", { domain: domain, command: "create_pizza", summary: "spec",
                                                         role: "Chef", args: {} }),
                              tool_call(2, "dispatch", { domain: domain, command: "create_pizza", summary: "spec",
                                                         role: "Chef", args: {}, dry_run: true }),
                              tool_call(3, "behaviors", { target: File.join(sandbox_root, domain) })],
                             env: reader_env
                           ))

      [1, 2, 3].each do |id|
        expect(results[id]["isError"]).to be true
        expect(payload(results[id])["error"]).to include("reader mode (HECKS_DOOR_TOOLS=readers)")
      end
    end

    it "refuses a domain it was not given before loading any of its Ruby" do
      other   = unnamed_domain
      results = results_of(run_over_pipes(
                             door,
                             [tool_call(1, "catalog", { domain: other }),
                              tool_call(2, "validate", { domain: other }),
                              tool_call(3, "state", { domain: other, aggregate: "Order", summary: "spec" })],
                             env: reader_env
                           ))

      [1, 2, 3].each do |id|
        expect(results[id]["isError"]).to be true
        expect(payload(results[id])["error"]).to include("is refused", "reader mode")
      end
      expect(File).not_to exist(marker)
    end

    it "loads that same domain on an unrestricted door, which is what the refusal above prevents" do
      other = unnamed_domain
      run_over_pipes(door, [tool_call(1, "catalog", { domain: other })],
                     env: { "HECKS_STOREHOUSE_ROOT" => sandbox_root })

      expect(File).to exist(marker)
    end

    {
      "an unknown mode"                 => { "HECKS_DOOR_TOOLS" => "all", "HECKS_DOOR_DOMAINS" => "pizzas" },
      "reader mode with no domains"     => { "HECKS_DOOR_TOOLS" => "readers" },
      "domains without reader mode"     => { "HECKS_DOOR_DOMAINS" => "pizzas" },
      "an unknown HECKS_DOOR_ name"     => { "HECKS_DOOR_TOKEN" => "x" },
      "a named domain outside the root" => { "HECKS_DOOR_TOOLS" => "readers", "HECKS_DOOR_DOMAINS" => "/tmp/elsewhere" }
    }.each do |label, settings|
      it "refuses to start on #{label}, before answering anything" do
        result = run_over_pipes(door, [initialize_request],
                                env: { "HECKS_STOREHOUSE_ROOT" => sandbox_root }.merge(settings))

        expect(result[:status].exitstatus).to eq(Hecks::McpDoorScope::EXIT_STATUS)
        expect(result[:err]).to include("refusing to start")
        expect(result[:out]).to be_empty
      end
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
