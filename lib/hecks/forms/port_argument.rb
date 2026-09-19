module Hecks
  module Forms
    # bin/present's own `-p`/`--port` reader, pulled out of the script so
    # it can be driven directly instead of only through a real server
    # boot. Two spellings the previous inline version got wrong:
    #
    #   --port=8080   the equals form — the old `ARGV.each_cons(2)` scan
    #                 only ever recognized "--port", "8080" as two
    #                 separate argv entries, so this spelling matched
    #                 nothing and silently fell through to the default.
    #   -p abc        a non-numeric value — the old code did `.to_i` on
    #                 whatever followed unconditionally, so a typo
    #                 quietly became port 0 (Rackup/WEBrick's actual
    #                 behavior for `Port: 0` is to bind an ephemeral
    #                 port — arguably useful on purpose elsewhere, but
    #                 never what a mistyped `-p abc` meant to ask for).
    #
    # Returns `[port, nil]` on a clean parse (falling back to `default`
    # when neither spelling appears at all) or `[nil, message]` when an
    # explicit port was given but isn't a real port number — the caller
    # decides what to do with a refusal (bin/present aborts on it).
    module PortArgument
      module_function

      # Reads the `-p`/`--port` argument out of an argv array.
      #
      # @param argv [Array<String>] the command-line arguments, ARGV-shaped
      # @param default [Integer] the port to use when neither spelling appears at all
      # @return [Array(Integer, nil), Array(nil, String)] `[port, nil]` on a clean
      #   parse, or `[nil, message]` when an explicit port was given but isn't a
      #   real port number
      def parse(argv, default: 4567)
        equals = argv.find { |arg| arg.start_with?("--port=") }
        return resolve(equals.split("=", 2).last) if equals

        index = argv.each_index.find { |i| %w[-p --port].include?(argv[i]) }
        return [default, nil] unless index

        resolve(argv[index + 1])
      end

      # Validates and converts a raw `-p`/`--port` argument value.
      #
      # @param value [String, nil] the text following `-p`/`--port`, or nil if none
      # @return [Array(Integer, nil), Array(nil, String)] `[port, nil]` if `value`
      #   is a whole number between 1 and 65535, or `[nil, message]` otherwise
      def resolve(value)
        return [nil, "-p/--port requires a value"] if value.nil? || value.empty?
        return [nil, "-p/--port must be a whole number, got #{value.inspect}"] unless value.match?(/\A\d+\z/)

        port = value.to_i
        return [nil, "-p/--port must be between 1 and 65535, got #{port}"] unless (1..65_535).cover?(port)

        [port, nil]
      end
    end
  end
end
