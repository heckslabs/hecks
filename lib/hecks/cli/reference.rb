# frozen_string_literal: true

require_relative "../../hecks"
require_relative "../projection_files"

module Hecks
  module CLI
    # The command behind `bin/reference`: regenerates `docs/implemented/reference/` from the
    # language's Syntax chapter. Tables come from the declaration; prose is kept from the
    # committed pages.
    module Reference
      module_function

      # Writes the pages and reports both coverage gates together (`DocCoverage` asks the same
      # as an exit status).
      #
      # @param root [String] the repository root
      # @param out [IO] where the report goes
      # @return [Integer] the exit status, always 0
      def call(root:, out: $stdout)
        directory = File.join(root, "docs/implemented/reference")
        written = Hecks::ProjectionFiles.write(:reference, root: root)
        out.puts "wrote #{written.size - 1} pages to docs/implemented/reference/, " \
                 "and regenerated README.md's own indexes"
        { "prose"             => Hecks::Doc::Reference.undocumented(directory),
          "a running example" => Hecks::Doc::Reference.unexemplified(directory) }.each do |owed, missing|
          report(out, owed, missing)
        end
        0
      end

      # @param out [IO] where the line goes
      # @param owed [String] what each word owes: prose, or a running example
      # @param missing [Array<String>] the words that lack it
      # @return [void]
      def report(out, owed, missing)
        if missing.empty?
          out.puts "every live word carries #{owed}."
        else
          out.puts "#{missing.size} word(s) still carry no #{owed}:"
          missing.each { |word| out.puts "  #{word}" }
        end
      end
    end
  end
end
