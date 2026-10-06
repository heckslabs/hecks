require "spec_helper"
require "fileutils"
require "open3"
require "rbconfig"
require "socket"
require "stringio"
require "tmpdir"

# Process-level checks for the stdio MCP doors (`hecks mcp`, `hecks serve_query_ir_mcp`): what
# they refuse, print, and require of a caller. Each runs as a child whose whole program is the
# library entry point the verb calls.
# Identity here is self-asserted only; nothing in this file claims otherwise.
RSpec.describe "the stdio MCP servers" do
  # The programs the two verbs run, by verb name.
  MCP_CHILD_PROGRAMS = {
    "mcp"                => 'require "hecks/cli/mcp"; Hecks::CLI::Mcp.call(ARGV)',
    "serve_query_ir_mcp" => 'require "hecks/cli/serve_query_ir_mcp"; Hecks::CLI::ServeQueryIrMcp.call(ARGV)'
  }.freeze

  def root = File.expand_path("..", __dir__)

  def door = child_program("mcp")

  def query_ir = child_program("serve_query_ir_mcp")

  def initialize_request = { jsonrpc: "2.0", id: 1, method: "initialize" }

  def list_request = { jsonrpc: "2.0", id: 1, method: "tools/list" }

  # @return [Array<String>] the command that starts the verb's server
  def child_program(verb)
    [RbConfig.ruby, "-I", File.join(root, "lib"), "-e", MCP_CHILD_PROGRAMS.fetch(verb), "--"]
  end

  # Runs a server to completion over pipes, feeding it one JSON-RPC request per line.
  def run_over_pipes(script, requests = [], args: [], env: {})
    input = requests.map { |request| "#{JSON.generate(request)}\n" }.join
    out, err, status = Open3.capture3(env, *script, *args, chdir: root, stdin_data: input)
    { out: out, err: err, status: status, responses: out.lines.map { |line| JSON.parse(line) } }
  end

  def tool_call(id, name, arguments)
    { jsonrpc: "2.0", id: id, method: "tools/call", params: { name: name, arguments: arguments } }
  end

  def results_of(run) = run[:responses].to_h { |response| [response["id"], response["result"]] }

  def payload(result) = JSON.parse(result["content"].first["text"])

  # Runs the `hecks mcp` door over the given requests and answers its results by request id.
  def door_results(calls, env:) = results_of(run_over_pipes(door, calls, env: env))

  def state_call(id, domain_name) = tool_call(id, "state", { domain: domain_name, aggregate: "Order", summary: "spec" })

  def query_call(id, args:)
    tool_call(id, "query", { domain: domain, question: "available", summary: "spec", args: args })
  end

  def behaviors_call(id) = tool_call(id, "behaviors", { target: File.join(sandbox_root, domain) })

  # Expects every listed request id to have been refused with all of the given phrases.
  def expect_refused(results, ids, *phrases)
    ids.each do |id|
      expect(results[id]["isError"]).to be true
      expect(payload(results[id])["error"]).to include(*phrases)
    end
  end

  # Runs a server with `socket` as its stdin, which is how an `inetd` or `socat` wrapper starts it.
  def run_over_socket(script, socket)
    out_read, out_write = IO.pipe
    err_read, err_write = IO.pipe
    pid = Process.spawn(*script, chdir: root, in: socket, out: out_write, err: err_write)
    out_write.close
    err_write.close
    _, status = Process.wait2(pid)
    { out: out_read.read, err: err_read.read, status: status }
  ensure
    [out_read, err_read].compact.each(&:close)
  end

  # Yields the accepted end of a TCP connection whose client has sent `request`, and closes the
  # sockets after.
  def with_tcp_pair(request = nil)
    listener = TCPServer.new("127.0.0.1", 0)
    client   = TCPSocket.new("127.0.0.1", listener.addr[1])
    served   = listener.accept
    client.puts(JSON.generate(request)) if request
    yield served
  ensure
    [client, served, listener].compact.each(&:close)
  end

  # Yields the child end of a Unix-domain socket pair whose parent end has sent `request`.
  def with_unix_pair(request)
    parent, child = UNIXSocket.pair
    parent.puts(JSON.generate(request))
    parent.close_write
    yield child
  ensure
    [parent, child].compact.each { |socket| socket.close unless socket.closed? }
  end

  %w[mcp serve_query_ir_mcp].each do |name|
    describe "hecks #{name}" do
      let(:script) { child_program(name) }

      it "starts over pipes with --stdio, answers on stdout with protocol only, and warns on stderr", :aggregate_failures do
        result = run_over_pipes(script, [initialize_request], args: ["--stdio"])

        expect(result[:status]).to be_success
        expect(result[:responses].map { |response| response["result"]["protocolVersion"] }).to eq(["2024-11-05"])
        expect(result[:err]).to include("stdio only", "no authentication")
        expect(result[:out]).not_to include("stdio only")
      end

      it "refuses a network option given as an argument, before answering anything", :aggregate_failures do
        result = run_over_pipes(script, [initialize_request], args: ["--port", "8080"])

        expect(result[:status].exitstatus).to eq(Hecks::McpStdioGuard::EXIT_STATUS)
        expect(result[:err]).to include("refusing to start", "--port")
        expect(result[:out]).to be_empty
      end

      it "refuses a network option given in the environment", :aggregate_failures do
        result = run_over_pipes(script, [initialize_request], env: { "HECKS_MCP_PORT" => "8080" })

        expect(result[:status].exitstatus).to eq(Hecks::McpStdioGuard::EXIT_STATUS)
        expect(result[:err]).to include("HECKS_MCP_PORT")
        expect(result[:out]).to be_empty
      end

      it "refuses to run with a network socket as stdin, the way a socat or inetd wrapper starts it", :aggregate_failures do
        result = with_tcp_pair(initialize_request) { |served| run_over_socket(script, served) }

        expect(result[:status].exitstatus).to eq(Hecks::McpStdioGuard::EXIT_STATUS)
        expect(result[:err]).to include("stdin is a network (IP) socket")
        expect(result[:out]).to be_empty
      end

      it "runs with a Unix-domain socket as stdin, which is what some MCP clients spawn servers over", :aggregate_failures do
        result = with_unix_pair(initialize_request) { |child| run_over_socket(script, child) }

        expect(result[:status]).to be_success
        expect(JSON.parse(result[:out])["result"]["serverInfo"]["name"]).to start_with("hecks-")
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

  describe "hecks mcp" do
    let(:sandbox_root) { Dir.mktmpdir("hecks-mcp-door-root") }
    let(:domain)       { memory_pizzas_under(sandbox_root) }
    let(:run) do
      run_over_pipes(
        door,
        [tool_call(1, "dispatch", { domain: domain, command: "order.create_pizza", summary: "spec", args: {} }),
         tool_call(2, "query", { domain: domain, question: "order.available", summary: "spec" }),
         tool_call(3, "catalog", { domain: "/tmp/outside_the_root" })],
        env: { "HECKS_STOREHOUSE_ROOT" => sandbox_root }
      )
    end

    after { FileUtils.rm_rf(sandbox_root) }

    it "warns, and refuses a role-gated dispatch with no role", :aggregate_failures do
      results = results_of(run)

      expect(results[1]["isError"]).to be true
      expect(payload(results[1])["error"]).to include('requires role: "Chef"', "no caller")
      expect(run[:err]).to include("Identity is self-asserted", "not verified", "no role check at all")
    end

    it "runs a query, and refuses a domain outside the root", :aggregate_failures do
      results = results_of(run)

      expect(results[2]["isError"]).to be false
      expect(results[3]["isError"]).to be true
      expect(results[3]["content"].first["text"]).to include("resolves outside")
    end
  end

  # Reader mode (ADR 0072 decision 2): a spawner narrows the door to reader tools over the
  # domains it names. It limits reach and identifies no one.
  describe "hecks mcp in reader mode" do
    let(:sandbox_root) { Dir.mktmpdir("hecks-mcp-door-reader") }
    let(:domain)       { memory_pizzas_under(sandbox_root) }
    let(:marker)       { File.join(sandbox_root, "unnamed-domain-loaded") }
    let(:reader_env) do
      { "HECKS_STOREHOUSE_ROOT" => sandbox_root, "HECKS_DOOR_TOOLS" => "readers", "HECKS_DOOR_DOMAINS" => domain }
    end

    after { FileUtils.rm_rf(sandbox_root) }

    # A domain under the root whose hecksagon writes `marker` when it is loaded.
    def unnamed_domain
      FileUtils.mkdir_p(File.join(sandbox_root, "unnamed"))
      File.write(File.join(sandbox_root, "unnamed", "unnamed.hecksagon"), "File.write(#{marker.inspect}, 'ran')\n")
      "unnamed"
    end

    def create_pizza_call(id, **extra)
      tool_call(id, "dispatch", { domain: domain, command: "order.create_pizza", summary: "spec", role: "Chef",
                                  args: {} }.merge(extra))
    end

    context "when asked for the tools, catalog, describe and state of a named domain" do
      let(:run) do
        run_over_pipes(
          door,
          [list_request, tool_call(2, "catalog", { domain: domain }), tool_call(3, "describe", { domain: domain }),
           state_call(4, domain)],
          env: reader_env
        )
      end

      it "answers catalog, describe and state for a named domain", :aggregate_failures do
        results = results_of(run)

        expect([2, 3, 4].map { |id| results[id]["isError"] }).to all(be false)
        expect(payload(results[2])["aggregates"].map { |aggregate| aggregate["name"] }).to include("Order")
        expect(payload(results[4])["count"]).to eq(0)
      end

      it "lists only reader tools, and says so on stderr", :aggregate_failures do
        expect(results_of(run)[1]["tools"].map { |tool| tool["name"] }).to match_array(Hecks::Doors::McpDoorScope::READER_TOOLS)
        expect(run[:err]).to include("Reader mode (HECKS_DOOR_TOOLS=readers)", "identifies no one")
        expect(run[:err]).not_to include("anyone who can write to stdin can run it")
      end
    end

    it "refuses dispatch, a dry run and behaviors, naming the mode" do
      calls = [create_pizza_call(1), create_pizza_call(2, dry_run: true), behaviors_call(3)]

      expect_refused(door_results(calls, env: reader_env), [1, 2, 3], "reader mode (HECKS_DOOR_TOOLS=readers)")
    end

    it "refuses a question whose arguments name a path outside the root, or a denied name" do
      calls = [query_call(1, args: { paths: "/etc" }), query_call(2, args: { url: "http://127.0.0.1:1" })]

      expect_refused(door_results(calls, env: reader_env), [1, 2], "argument", "is refused", "reader mode")
    end

    it "refuses a domain it was not given before loading any of its Ruby", :aggregate_failures do
      other = unnamed_domain
      calls = [tool_call(1, "catalog", { domain: other }), tool_call(2, "validate", { domain: other }), state_call(3, other)]

      expect_refused(door_results(calls, env: reader_env), [1, 2, 3], "is refused", "reader mode")
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
      it "refuses to start on #{label}, before answering anything", :aggregate_failures do
        result = run_over_pipes(door, [initialize_request],
                                env: { "HECKS_STOREHOUSE_ROOT" => sandbox_root }.merge(settings))

        expect(result[:status].exitstatus).to eq(Hecks::Doors::McpDoorScope::EXIT_STATUS)
        expect(result[:err]).to include("refusing to start")
        expect(result[:out]).to be_empty
      end
    end
  end

  # What the spec-example commands run in the commands-mode door.
  SPEC_EXAMPLE_RUNS = [
    ["spec/doors/cli_runner_spec.rb", "hands back the domain's own wording, and a non-zero status"],
    ["spec/exe_hecks_spec.rb", "is executable"],
    ["spec/exe_hecks_spec.rb", "hands every name the gem shipped to Hecks::CLI"]
  ].freeze

  # Commands mode (ADR 0089): reader mode plus `dispatch` for a closed list of commands.
  describe "hecks mcp in commands mode" do
    let(:sandbox_root) { Dir.mktmpdir("hecks-mcp-door-commands") }
    let(:domain)       { memory_pizzas_under(sandbox_root) }
    let(:commands_env) do
      { "HECKS_STOREHOUSE_ROOT" => sandbox_root, "HECKS_DOOR_TOOLS" => "commands",
        "HECKS_DOOR_DOMAINS" => domain, "HECKS_DOOR_COMMANDS" => "order.create_pizza" }
    end

    after { FileUtils.rm_rf(sandbox_root) }

    def pizza_args(name) = { name: name, pizza: { price_cents: 1200, size: "large" } }

    def dispatch_call(id, command, **extra)
      tool_call(id, "dispatch", { domain: domain, command: command, summary: "spec", role: "Chef",
                                  args: pizza_args("Margherita") }.merge(extra))
    end

    def tools_in(response) = response["tools"].to_h { |tool| [tool["name"], tool] }

    # The door as it runs the repository's own commands, allowing only `commands`.
    def repository_door_env(commands)
      { "HECKS_STOREHOUSE_ROOT" => root, "HECKS_DOOR_TOOLS" => "commands",
        "HECKS_DOOR_DOMAINS" => "lib/hecks/hecks", "HECKS_DOOR_COMMANDS" => commands }
    end

    def spec_example_calls
      SPEC_EXAMPLE_RUNS.each_with_index.map do |(file, example), index|
        tool_call(index + 1, "dispatch", { command: "test_suite_run.run_spec_example", summary: "spec", role: "Maintainer",
                                           args: { file: file, example: example, run: "door-specs-#{Process.pid}-#{index}" } })
      end
    end

    def check_comments_results
      args = { paths: "lib/hecks/cli", run: "door-settled-#{Process.pid}" }
      call = tool_call(1, "dispatch", { command: "style_run.check_comments", summary: "spec", role: "Maintainer", args: args })
      door_results([call], env: repository_door_env("style_run.check_comments"))
    end

    def optional_domain_calls
      [list_request,
       tool_call(2, "dispatch", { command: "order.create_pizza", summary: "spec", role: "Chef",
                                  args: pizza_args("Margherita") }),
       tool_call(3, "state", { aggregate: "Order", summary: "spec" }),
       dispatch_call(4, "order.create_pizza", domain: "elsewhere")]
    end

    def unlisted_command_calls
      steps = [{ command: "order.create_pizza", args: pizza_args("A") }, { command: "purchase", args: {} }]
      [dispatch_call(1, "purchase"), dispatch_call(2, "add_topping", dry_run: true),
       tool_call(3, "dispatch", { domain: domain, summary: "spec", role: "Chef", steps: steps }), state_call(4, domain)]
    end

    def bad_batch_calls
      steps = [{ command: "order.create_pizza", args: pizza_args("A") },
               { command: "order.create_pizza", args: pizza_args("B").merge("output" => "/tmp/x") }]
      [tool_call(1, "dispatch", { domain: domain, summary: "spec", role: "Chef", steps: steps }), state_call(2, domain)]
    end

    def fingerprint = Hecks::Storehouse.fingerprint(File.join(sandbox_root, domain))

    def fingerprint_after(text)
      File.write(File.join(sandbox_root, domain, "added.txt"), text)
      fingerprint
    end

    context "when listing the tools" do
      let(:run) { run_over_pipes(door, [list_request], env: commands_env) }
      let(:tools) { tools_in(results_of(run)[1]) }

      it "lists the reader tools and dispatch", :aggregate_failures do
        expect(tools.keys).to match_array(Hecks::Doors::McpDoorScope::COMMAND_TOOLS)
        expect(tools).not_to have_key("behaviors")
      end

      it "gives dispatch the allowed commands as an enum", :aggregate_failures do
        properties = tools["dispatch"]["inputSchema"]["properties"]

        expect(properties["command"]["enum"]).to eq(["order.create_pizza"])
        expect(properties["steps"]["items"]["properties"]["command"]["enum"]).to eq(["order.create_pizza"])
      end

      it "describes each allowed command, and says so on stderr", :aggregate_failures do
        expect(tools["dispatch"]["description"])
          .to include("order.create_pizza (role Chef): Put a new pizza on the menu", "Arguments: name*, pizza*",
                      "pass that role as `role`")
        expect(run[:err]).to include("Commands mode (HECKS_DOOR_TOOLS=commands)", "identifies no one")
      end
    end

    context "when the door serves one domain" do
      let(:results) { door_results(optional_domain_calls, env: commands_env) }

      it "makes domain optional, and says so in the schema", :aggregate_failures do
        tools = tools_in(results[1])

        expect(tools["dispatch"]["inputSchema"]["required"]).not_to include("domain")
        expect(tools["state"]["inputSchema"]["properties"]["domain"]["description"]).to include("Optional", domain)
      end

      it "fills the domain in, and still refuses another one", :aggregate_failures do
        expect(payload(results[2])["ok"]).to be true
        expect(payload(results[3])["count"]).to eq(1)
        expect(payload(results[4])["error"]).to include("is refused")
      end
    end

    it "runs one spec example after another in the same door, each answering its own summary" do
      results = door_results(spec_example_calls, env: repository_door_env("test_suite_run.run_spec_example"))

      reports = (1..3).map { |id| payload(results[id]).dig("state", "report", "value").to_s }
      expect(reports).to all(include("1 example, 0 failures"))
    end

    it "answers the record as it stands once the reactions have run, not as the command left it", :aggregate_failures do
      answer = payload(check_comments_results[1])

      expect(answer["ok"]).to be true
      expect(answer["state"]["status"]).to eq("completed")
    end

    it "dispatches an allowed command by its qualified name", :aggregate_failures do
      results = door_results([dispatch_call(1, "order.create_pizza"), dispatch_call(2, "order.create_pizza")], env: commands_env)

      [1, 2].each { |id| expect(payload(results[id])).not_to include("error" => a_string_including("refused")) }
      expect(payload(results[1])["ok"]).to be true
    end

    it "refuses any other command, a dry run of it, and a batch holding it, before running anything", :aggregate_failures do
      results = door_results(unlisted_command_calls, env: commands_env)

      expect_refused(results, [1, 2, 3], "is refused", "commands mode", "order.create_pizza")
      expect(payload(results[4])["count"]).to eq(0)
    end

    it "keeps the domain booted between calls, so a dispatched record is there for the next call", :aggregate_failures do
      results = door_results([dispatch_call(1, "order.create_pizza"), state_call(2, domain)], env: commands_env)

      expect(payload(results[1])["ok"]).to be true
      expect(payload(results[2])["count"]).to eq(1)
    end

    it "fingerprints a domain directory by its files, the same until one is rewritten or added" do
      before = fingerprint

      expect(fingerprint).to eq(before)
    end

    it "changes the fingerprint when a file is added, and again when it is rewritten" do
      before = fingerprint
      added = fingerprint_after("x")

      expect([before, added, fingerprint_after("xy")].uniq.size).to eq(3)
    end

    # An allowed command still takes its arguments by name: a denied name, a path that leaves the
    # root and a ref that reads as a git option are refused before the command runs.
    {
      "a denied argument name"                   => { "output" => "/tmp/anywhere" },
      "a url"                                    => { "url" => "http://127.0.0.1:1" },
      "a location that can name a host"          => { "from" => "git@host:repo" },
      "a path outside the root"                  => { "file" => "/etc/passwd" },
      "a path list with one outside the root"    => { "paths" => "lib,/etc" },
      "a path that climbs out of the root"       => { "file" => "../../../etc/passwd" },
      "a path with a colon, which can be a host" => { "root" => "host:repo" },
      "a path in the nested value form"          => { "file" => { "value" => "/etc/passwd" } },
      "a ref that reads as an option"            => { "ref" => "--output=/tmp/x" }
    }.each do |label, extra|
      it "refuses #{label} on an allowed command, naming the argument", :aggregate_failures do
        args = pizza_args("Margherita").merge(extra)
        results = door_results([dispatch_call(1, "order.create_pizza", args: args)], env: commands_env)

        expect(results[1]["isError"]).to be true
        expect(payload(results[1])["error"]).to include("argument", "is refused", "commands mode", extra.keys.first)
      end
    end

    it "follows a symlink out of the root, so a link inside it does not hide a path outside" do
      File.symlink("/etc", File.join(sandbox_root, "escape"))
      args = pizza_args("Margherita").merge("file" => "escape/passwd")
      results = door_results([dispatch_call(1, "order.create_pizza", args: args)], env: commands_env)

      expect(payload(results[1])["error"]).to include("is refused", "file")
    end

    it "passes a path inside the root and a plain ref on to the command" do
      inside = File.join(sandbox_root, domain, "pizzas.bluebook")
      args = pizza_args("Margherita").merge("file" => inside, "ref" => "origin/main")
      results = door_results([dispatch_call(1, "order.create_pizza", args: args)], env: commands_env)

      expect(payload(results[1])["error"].to_s).not_to include("this door runs in commands mode")
    end

    it "checks the arguments of every step of a batch before any step runs", :aggregate_failures do
      results = door_results(bad_batch_calls, env: commands_env)

      expect(payload(results[1])["error"]).to include("argument", "output")
      expect(payload(results[2])["count"]).to eq(0)
    end

    it "refuses a question whose arguments reach outside the root" do
      results = door_results([query_call(1, args: { paths: "/etc" })], env: commands_env)

      expect(payload(results[1])["error"]).to include("argument", "paths", "is refused")
    end

    it "refuses a command name that resolves to nothing, and still refuses behaviors", :aggregate_failures do
      results = door_results([dispatch_call(1, "no_such_command"), behaviors_call(2)], env: commands_env)

      expect(payload(results[1])["error"]).to include("is refused")
      expect(payload(results[2])["error"]).to include("commands mode (HECKS_DOOR_TOOLS=commands)")
    end

    it "admits nothing for an allowed name that resolves to no command" do
      env = commands_env.merge("HECKS_DOOR_COMMANDS" => "no_such_command")
      results = door_results([dispatch_call(1, "order.create_pizza")], env: env)

      expect(payload(results[1])["error"]).to include("is refused")
    end

    [
      ["commands mode with no commands", { "HECKS_DOOR_TOOLS" => "commands", "HECKS_DOOR_DOMAINS" => "pizzas" }],
      ["commands mode with no domains", { "HECKS_DOOR_TOOLS" => "commands", "HECKS_DOOR_COMMANDS" => "order.create_pizza" }],
      ["an empty command list",
       { "HECKS_DOOR_TOOLS" => "commands", "HECKS_DOOR_DOMAINS" => "pizzas", "HECKS_DOOR_COMMANDS" => " , " }],
      ["commands without commands mode", { "HECKS_DOOR_COMMANDS" => "order.create_pizza" }],
      ["commands in reader mode",
       { "HECKS_DOOR_TOOLS" => "readers", "HECKS_DOOR_DOMAINS" => "pizzas", "HECKS_DOOR_COMMANDS" => "order.create_pizza" }]
    ].each do |label, settings|
      it "refuses to start on #{label}, before answering anything", :aggregate_failures do
        result = run_over_pipes(door, [initialize_request],
                                env: { "HECKS_STOREHOUSE_ROOT" => sandbox_root }.merge(settings))

        expect(result[:status].exitstatus).to eq(Hecks::Doors::McpDoorScope::EXIT_STATUS)
        expect(result[:err]).to include("refusing to start")
        expect(result[:out]).to be_empty
      end
    end
  end

  describe "hecks serve_query_ir_mcp" do
    around do |example|
      Dir.mktmpdir("hecks-mcp-outside") do |dir|
        @outside = dir
        example.run
      end
    end

    # A domains directory outside the project root whose bluebook writes a marker file when loaded.
    def plant_loadable_domain
      FileUtils.mkdir_p(File.join(@outside, "bluebook"))
      marker = File.join(@outside, "loaded")
      File.write(File.join(@outside, "bluebook", "evil.bluebook"), "File.write(#{marker.inspect}, 'ran')\n")
    end

    def query_ir_run(domains, **extra)
      run_over_pipes(query_ir, [tool_call(1, "query_ir_duplicates", { domains: domains, **extra })])
    end

    it "refuses a domains directory outside the project root rather than loading Ruby from it", :aggregate_failures do
      plant_loadable_domain
      result = query_ir_run([@outside]).fetch(:responses).first["result"]

      expect(result["isError"]).to be true
      expect(result["content"].first["text"]).to include("resolves outside")
      expect(File).not_to exist(File.join(@outside, "loaded"))
    end

    it "warns that it asks for no identity, and accepts a domains directory inside the project root", :aggregate_failures do
      run = query_ir_run(["examples/no_such_domain"], include_meta: false)

      expect(run[:responses].first["result"]["isError"]).to be false
      expect(run[:err]).to include("No identity is asked for or checked")
    end
  end

  describe Hecks::McpStdioGuard do
    let(:pipe_in)  { IO.pipe }
    let(:pipe_out) { IO.pipe }
    let(:stderr)   { StringIO.new }

    after { (pipe_in + pipe_out).each { |io| io.close unless io.closed? } }

    def violations(**overrides)
      described_class.violations(argv: [], env: {}, stdin: pipe_in.first, stdout: pipe_out.last, **overrides)
    end

    def start!(**overrides)
      described_class.start!(server: "demo", argv: [], env: {}, stdin: pipe_in.first, stdout: pipe_out.last,
                             stderr: stderr, **overrides)
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

    it "refuses any other HECKS_MCP_ variable, including a non-stdio transport", :aggregate_failures do
      found = violations(env: { "HECKS_MCP_TRANSPORT" => "http", "HECKS_MCP_HOST" => "0.0.0.0", "HOME" => "/x" })

      expect(found.length).to eq(2)
      expect(found.join).to include("HECKS_MCP_TRANSPORT", "HECKS_MCP_HOST")
      expect(found.join).not_to include("HOME")
    end

    it "refuses an IP socket on either stream", :aggregate_failures do
      with_tcp_pair do |served|
        expect(violations(stdin: served).join).to include("stdin is a network")
        expect(violations(stdout: served).join).to include("stdout is a network")
      end
    end

    it "accepts a Unix-domain socket on both streams" do
      left, right = UNIXSocket.pair

      expect(violations(stdin: left, stdout: right)).to eq([])
    ensure
      [left, right].compact.each(&:close)
    end

    it "prefixes every banner line with the server name and puts the server's notes after the common ones", :aggregate_failures do
      lines = described_class.banner(server: "demo", notes: ["extra note"])

      expect(lines).to all(start_with("demo: "))
      expect(lines.last).to eq("demo: extra note")
      expect(lines.first).to include("stdio only")
    end

    it "writes the warning to the stream it is given and exits nothing when the setup is stdio" do
      start!(notes: ["extra"])

      expect(stderr.string).to include("demo: extra")
    end

    it "exits with the guard's status and writes the refusal, not the warning, on a violation", :aggregate_failures do
      expect { start!(argv: ["--port"]) }
        .to raise_error(SystemExit) { |error| expect(error.status).to eq(described_class::EXIT_STATUS) }

      expect(stderr.string).to include("demo: refusing to start")
      expect(stderr.string).not_to include("no authentication")
    end
  end
end
