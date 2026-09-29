# frozen_string_literal: true

require "yaml"

module Hecks
  # The 2.10 notices for what changes in hecks 3.0.0 (ADR 0080): every `bin/` script is removed
  # and becomes a command on the Hecks domain, and `exe/hecks` takes new argument forms.
  #
  # Notices go to stderr, and only to a terminal, so piped output, CI logs and the MCP stdio
  # doors never see them. `HECKS_NO_3_0_NOTICE` silences them everywhere.
  module ThreeZero
    # Each script name mapped to the 3.0 form that replaces it.
    FORMS = YAML.safe_load_file(File.join(__dir__, "three_zero/forms.yml")).freeze

    # `exe/hecks` routes whose script has another name.
    ROUTE_SCRIPTS = { "mcp" => "hecks_mcp_door" }.freeze

    # Where a generated deploy file can call a script: `bin/<name>` in a Makefile or a shell script.
    DEPLOY_FILE = %r{(\A|/)(Makefile|[^/]+\.(?:mk|sh))\z}

    module_function

    # Tells a person at a terminal what a `bin/` script becomes in 3.0.0.
    #
    # @param script [String] the script's name, as under `bin/`
    # @param io [IO] where the notice goes
    # @param env [Hash{String => String}] the environment, read for `HECKS_NO_3_0_NOTICE`
    # @return [void]
    def notice(script, io: $stderr, env: ENV)
      form = FORMS[script]
      return unless form && show?(io, env)

      io.puts "hecks: bin/#{script} is removed in 3.0.0; it becomes `#{form}` (ADR 0080)."
    end

    # Tells a person at a terminal the 3.0.0 form of an `exe/hecks` route, which keeps its name.
    #
    # @param route [String] the route, as typed after `hecks`
    # @param io [IO] where the notice goes
    # @param env [Hash{String => String}] the environment, read for `HECKS_NO_3_0_NOTICE`
    # @return [void]
    def route_notice(route, io: $stderr, env: ENV)
      form = FORMS[ROUTE_SCRIPTS.fetch(route, route)]
      return unless form && show?(io, env)

      io.puts "hecks: from 3.0.0 this is `#{form}` (ADR 0080)."
    end

    # Adds a comment naming the 3.0.0 form of every `bin/` script a generated deploy file calls.
    #
    # @param files [Hash{String => String}] generated files, keyed by relative path
    # @return [Hash{String => String}] the same map, with a comment added to each file that calls one
    def annotate_deploy_files(files)
      files.to_h do |path, text|
        called = text.is_a?(String) && DEPLOY_FILE.match?(path) ? scripts_called(text) : []
        [path, called.empty? ? text : with_comment(text, called)]
      end
    end

    # @api private
    def show?(io, env)
      !env.key?("HECKS_NO_3_0_NOTICE") && io.respond_to?(:tty?) && io.tty?
    end

    # @api private
    def scripts_called(text)
      text.scan(%r{\bbin/([a-z_][a-z0-9_-]*)}).flatten.uniq.select { |name| FORMS.key?(name) }.sort
    end

    # @api private
    def with_comment(text, called)
      lines = ["# hecks 3.0.0 removes bin/ (ADR 0080). The calls below change:"]
      lines.concat(called.map { |name| "#   bin/#{name} becomes `#{FORMS.fetch(name)}`" })
      shebang, rest = text.start_with?("#!") ? text.split("\n", 2) : [nil, text]
      [shebang, *lines, rest].compact.join("\n")
    end
  end
end
