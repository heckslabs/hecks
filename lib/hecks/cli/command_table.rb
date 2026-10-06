module Hecks
  module CLI
    # One subcommand: a one-line summary, its usage line, the file that holds it and the
    # call that runs it (given the argv after the name, its program name and its own name).
    Command = Struct.new(:summary, :usage, :file, :run)

    # Every subcommand, in the order the help lists them.
    COMMANDS = {
      "run"              => Command.new(
        "Dispatch a verb, or run a JSON step list, against a domain.",
        "hecks run [domain] <verb [name=value …] | script.json | - | '{\"steps\":[…]}'>",
        "cli/run",
        ->(argv, program, _name) { Run.call(argv, program: program) }
      ),
      "docs"             => Command.new(
        "Print a domain's usage document, projected from its bluebook.",
        "hecks docs [domain-path] [aggregate]",
        "cli/document",
        ->(argv, program, name) { Document.call(argv, projection: name.to_sym, program: program, root: Dir.pwd) }
      ),
      "narrate"          => Command.new(
        "Print a domain read back in English, projected from its bluebook.",
        "hecks narrate [domain-path] [aggregate]",
        "cli/document",
        ->(argv, program, name) { Document.call(argv, projection: name.to_sym, program: program, root: Dir.pwd) }
      ),
      "ir"               => Command.new(
        "Print a booted domain's IR as JSON.",
        "hecks ir <domain> [--translations] | hecks ir --meta",
        "cli/ir",
        ->(argv, program, _name) { Ir.call(argv, program: program) }
      ),
      "stores"           => Command.new(
        "Print every aggregate's current records as JSON.",
        "hecks stores <domain>",
        "cli/stores",
        ->(argv, program, _name) { Stores.call(argv, program: program) }
      ),
      "model_check"      => Command.new(
        "Statically check a domain's IR for dead states and unreachable steps.",
        "hecks model_check [--strict] [--profile client] [--wait] [<domain> …]",
        "cli/model_check",
        ->(argv, program, _name) { ModelCheck.call(argv, program: program, root: checkout_root) }
      ),
      "smoke_test"       => Command.new(
        "Boot a domain and dispatch every declared command and report once.",
        "hecks smoke_test [domain]",
        "cli/smoke_test",
        ->(argv, _program, _name) { SmokeTest.call(argv, root: Dir.pwd) }
      ),
      "project_diagrams" => Command.new(
        "Write a domain's Mermaid diagrams under ./docs/generated/diagrams/ (positional form only).",
        "hecks project_diagrams <domain-path> <ChapterName>  (writes) | " \
        "hecks project_diagrams domain=<path> chapter=<Name>  (prints; writes nothing)",
        "cli/project_diagrams",
        ->(argv, program, _name) { ProjectDiagrams.call(argv, program: program, root: Dir.pwd) }
      ),
      "project_cli"      => Command.new(
        "Write a command-line launcher beside each domain, named after its bluebook.",
        "hecks project_cli [domain-path …]",
        "cli/project_cli",
        ->(argv, program, _name) { ProjectCli.call(argv, program: program, root: Dir.pwd, remove_stale_bin: false) }
      ),
      "mcp"              => Command.new(
        "Serve the MCP door over stdio (no authentication; stdio only).",
        "hecks mcp [--stdio]",
        "cli/mcp",
        ->(argv, _program, _name) { Mcp.call(argv) }
      )
    }.freeze
  end
end
