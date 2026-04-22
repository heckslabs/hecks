module Hecksagon
  module Structure

    # Hecksagon::Structure::ShellAdapter
    #
    # Value object for a named shell-out adapter declared in a hecksagon.
    # Holds the command, argument vector (with {{placeholder}} tokens),
    # output parsing format, optional timeout, working dir, and
    # environment overrides.
    #
    # Shell adapters are invoked through Hecks::Runtime#shell(name, **attrs)
    # which substitutes placeholders into the arg vector and executes via
    # Open3.capture3 (no shell).
    #
    #   adapter = ShellAdapter.new(
    #     name: :git_log,
    #     command: "git",
    #     args: ["log", "--format=%H", "{{range}}"],
    #     output_format: :lines,
    #     timeout: 10,
    #     working_dir: ".",
    #     env: { "GIT_PAGER" => "" }
    #   )
    #   adapter.placeholders  # => [:range]
    #
    class ShellAdapter
      VALID_OUTPUT_FORMATS = %i[text lines json json_lines exit_code].freeze
      PLACEHOLDER_RE = /\{\{(\w+)\}\}/

      # @return [Symbol] unique name within the hecksagon
      attr_reader :name

      # @return [String] fixed binary name (no shell string, no {{}})
      attr_reader :command

      # @return [Array<String>] argument vector; elements may contain {{placeholders}}
      attr_reader :args

      # @return [Symbol] one of VALID_OUTPUT_FORMATS
      attr_reader :output_format

      # @return [Integer, nil] seconds before dispatcher raises ShellAdapterTimeoutError
      attr_reader :timeout

      # @return [String, nil] working directory (resolved against hecksagon source)
      attr_reader :working_dir

      # @return [Hash{String=>String}] env overrides passed to Open3 (baseline is empty)
      attr_reader :env

      # @param name [Symbol] adapter name
      # @param command [String] binary to invoke
      # @param args [Array<String>] argument vector
      # @param output_format [Symbol]
      # @param timeout [Integer, nil]
      # @param working_dir [String, nil]
      # @param env [Hash]
      def initialize(name:, command:, args: [], output_format: :text,
                     timeout: nil, working_dir: nil, env: {})
        raise ArgumentError, "shell adapter requires :name" if name.nil?
        raise ArgumentError, "shell adapter :command required" if command.nil? || command.to_s.empty?
        raise ArgumentError, "shell adapter :command must not contain {{}} (fixed binary only): #{command.inspect}" if command.to_s.include?("{{")
        raise ArgumentError, "shell adapter :args must be an Array of Strings" unless args.is_a?(Array) && args.all? { |a| a.is_a?(String) }
        unless VALID_OUTPUT_FORMATS.include?(output_format.to_sym)
          raise ArgumentError, "shell adapter :output_format must be one of #{VALID_OUTPUT_FORMATS.inspect} (got #{output_format.inspect})"
        end

        @name = name.to_sym
        @command = command.to_s
        @args = args.dup.freeze
        @output_format = output_format.to_sym
        @timeout = timeout
        @working_dir = working_dir
        @env = env.to_h.transform_keys(&:to_s).transform_values(&:to_s).freeze
      end

      # Returns the list of unique placeholder names referenced in args,
      # in first-appearance order.
      #
      # @return [Array<Symbol>] placeholder names
      def placeholders
        @args.each_with_object([]) do |arg, acc|
          arg.scan(PLACEHOLDER_RE).flatten.each do |match|
            sym = match.to_sym
            acc << sym unless acc.include?(sym)
          end
        end
      end

      # Hash representation for JSON/IR dumps.
      #
      # @return [Hash]
      def to_h
        {
          name: @name,
          command: @command,
          args: @args,
          output_format: @output_format,
          timeout: @timeout,
          working_dir: @working_dir,
          env: @env
        }
      end
    end
  end
end
