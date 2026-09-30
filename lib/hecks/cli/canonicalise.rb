# frozen_string_literal: true

require_relative "../canonical_json"

module Hecks
  module CLI
    # The command behind `bin/canonicalise`: prints a JSON document with every object's keys
    # sorted, recursively. Key order is not semantics, so a diff a person reads should not have
    # to notice it moved.
    module Canonicalise
      module_function

      # Prints the document at the path in `argv`, canonicalised.
      #
      # @param argv [Array<String>] the path of the JSON file, first
      # @param out [IO] where the document goes
      # @return [Integer] the exit status, always 0
      # @raise [IndexError] when no path is given
      def call(argv, out: $stdout)
        out.puts Hecks::CanonicalJson.pretty(File.read(argv.fetch(0)))
        0
      end
    end
  end
end
