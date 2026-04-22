module Hecksagon
  module DSL

    # Hecksagon::DSL::ShellAdapterBuilder
    #
    # DSL builder for a single shell-out adapter. Collects command,
    # arg vector, output format, timeout, working dir, and env
    # overrides declared inside an `adapter :shell, name:` block or
    # as keyword arguments on the one-liner form.
    #
    #   builder = ShellAdapterBuilder.new(:git_log)
    #   builder.command "git"
    #   builder.args    ["log", "--format=%H", "{{range}}"]
    #   builder.output_format :lines
    #   builder.timeout 10
    #   builder.env "GIT_PAGER" => ""
    #   builder.build   # => Hecksagon::Structure::ShellAdapter
    #
    class ShellAdapterBuilder
      # @param name [Symbol, String] adapter name, required, unique within hecksagon
      def initialize(name)
        @name = name&.to_sym
        @command = nil
        @args = []
        @output_format = :text
        @timeout = nil
        @working_dir = nil
        @env = {}
      end

      # Declare the binary to invoke. Must be a fixed string — no
      # placeholders and no shell string. Enforced by Structure::ShellAdapter.
      #
      # @param cmd [String]
      def command(cmd)
        @command = cmd
      end

      # Declare the argument vector. Array of strings only — shell string
      # form (e.g., "git log {{range}}") is forbidden; each token is its
      # own element. Placeholders of the form {{name}} substitute per-element
      # at dispatch time.
      #
      # @param list [Array<String>]
      def args(list)
        @args = list
      end

      # Declare the output parsing format.
      # Valid: :text :lines :json :json_lines :exit_code
      #
      # @param fmt [Symbol]
      def output_format(fmt)
        @output_format = fmt
      end

      # Declare the dispatcher timeout in seconds.
      #
      # @param seconds [Integer]
      def timeout(seconds)
        @timeout = seconds
      end

      # Declare the working directory (resolved against hecksagon source
      # path at dispatch time, not process cwd).
      #
      # @param dir [String]
      def working_dir(dir)
        @working_dir = dir
      end

      # Merge env overrides into the adapter's env map. Values are stringified.
      # The dispatcher starts from an empty env and only passes what was
      # declared here (cleared-by-default is part of the security model).
      #
      #   env "GIT_PAGER" => "", "LC_ALL" => "C"
      #
      # @param pairs [Hash]
      def env(pairs)
        @env.merge!(pairs)
      end

      # Apply any keyword-argument shortcuts from the one-liner form:
      #
      #   adapter :shell, name: :x, command: "echo", args: ["hi"]
      #
      # @param opts [Hash]
      # @return [self]
      def apply_options(opts)
        command(opts[:command])            if opts.key?(:command)
        args(opts[:args])                  if opts.key?(:args)
        output_format(opts[:output_format]) if opts.key?(:output_format)
        timeout(opts[:timeout])            if opts.key?(:timeout)
        working_dir(opts[:working_dir])    if opts.key?(:working_dir)
        env(opts[:env])                    if opts.key?(:env)
        self
      end

      # Build and return the ShellAdapter IR value object.
      #
      # @return [Hecksagon::Structure::ShellAdapter]
      def build
        Structure::ShellAdapter.new(
          name: @name,
          command: @command,
          args: @args || [],
          output_format: @output_format,
          timeout: @timeout,
          working_dir: @working_dir,
          env: @env
        )
      end
    end
  end
end
