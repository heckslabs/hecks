module Hecks
  module Forms
    # bin/present's own `-p`/`--port` reader, pulled out of the script so
    # it can be driven directly instead of only through a real server
    # boot. Handles two spellings deliberately:
    #
    #   --port=8080   the equals form — parsed as one joined argv entry,
    #                 since "--port", "8080" arriving as two separate
    #                 entries is a different spelling this also matches
    #                 (below), and neither should silently fall through
    #                 to the default.
    #   -p abc        a non-numeric value — refused explicitly rather
    #                 than coerced with `.to_i`, which would quietly turn
    #                 a typo into port 0 (Rackup/WEBrick's actual
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

      # Reads a `-p`/`--port` argument out of an argv Array, accepting both the
      # equals form and the space-separated form.
      #
      # @param argv [Array<String>] the command-line arguments to scan
      # @param default [Integer] the port to answer when neither spelling is present
      # @return [Array(Integer, nil), Array(nil, String)] `[port, nil]` on a clean parse
      #   or fallback to `default`; `[nil, message]` when an explicit port was given but
      #   is not a valid port number
      def parse(argv, default: 4567)
        equals = argv.find { |arg| arg.start_with?("--port=") }
        return resolve(equals.split("=", 2).last) if equals

        index = argv.each_index.find { |i| %w[-p --port].include?(argv[i]) }
        return [default, nil] unless index

        resolve(argv[index + 1])
      end

      # Validates and converts one raw port argument.
      #
      # @param value [String, nil] the text following `-p`/`--port`/`--port=`
      # @return [Array(Integer, nil), Array(nil, String)] `[port, nil]` when `value` is a
      #   whole number between 1 and 65535; `[nil, message]` naming why not, otherwise
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
