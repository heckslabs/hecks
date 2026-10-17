module Hecks
  module Composer
    # Where each named thing in a workspace is declared, read from the text alone so it works on a
    # draft that does not parse: the editor jumps to a definition and shows a line's `goal` or
    # `description` on hover from it.
    module Outline
      # The constructs that name something a reader may want to jump to.
      KINDS = %w[aggregate entity value_object command query policy process_manager].freeze

      DECLARATION = /\A\s*(#{KINDS.join("|")})\s+"([^"]+)"/
      SUMMARY = /\A\s*(?:goal|description)\s+"((?:[^"\\]|\\.)*)"/

      # How many lines below a declaration its `goal` or `description` may sit.
      REACH = 6

      module_function

      # @param stage [String] a staged directory (see {Workspace.stage})
      # @param files [Array<String>] the staged files, relative to `stage`
      # @return [Array<Hash>] `{file:, line:, kind:, name:, summary:}` for each declaration, in file
      #   then line order; `line` counts from 1 and `summary` is nil when none follows
      def call(stage, files)
        files.grep(/\.(bluebook|hecksagon|behaviors|world)\z/).flat_map do |file|
          entries(file, File.readlines(File.join(stage, file), chomp: true))
        end
      end

      # @api private
      def entries(file, lines)
        lines.each_with_index.filter_map do |text, index|
          found = text.match(DECLARATION) or next
          { file: file, line: index + 1, kind: found[1], name: found[2], summary: summary(lines, index) }
        end
      end

      # @api private
      def summary(lines, index)
        lines[(index + 1)..(index + REACH)].to_a.each do |text|
          break if text.match?(DECLARATION)

          found = text.match(SUMMARY)
          return found[1].gsub('\"', '"') if found
        end
        nil
      end
    end
  end
end
