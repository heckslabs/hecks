require "hecks/command_names"

module Hecks
  module DocStaleness
    # The files to read, and the ones whose citations are history or example.
    module Sources
      # Directories whose files are build output, fixtures or records of a moment.
      SKIPPED = %r{(?:\A|/)(?:\.git|node_modules|target|vendor|tmp|generated|fixtures|golden|corpus)/}

      # A first-lines banner or status line that marks a page as a record of a past state.
      HISTORICAL = /\A(?:>\s*Historical:|\**Status:?\**:?\s*(?:Superseded|Historical|Rejected)\b)/i

      # The marker that excuses a shown-not-meant citation, on its line or the one before.
      MARKER = "staleness-check: skip".freeze

      # The files read.
      READ = /\.(?:md|rb|rs)\z/

      # How many lines from the top count as "the first lines".
      WINDOW = 15

      module_function

      # @param root [String] the checkout
      # @param paths [Array<String>] files or directories below it, or empty for all of it
      # @return [Array<String>] the `.md`, `.rb` and `.rs` files to read, relative to `root`, sorted
      def files(root, paths)
        starts = paths.empty? ? ["."] : paths
        found = starts.flat_map { |start| Dir.glob(File.join(root, start, "**/*.{md,rb,rs}")) + [File.join(root, start)] }
        relative(root, found.select { |path| File.file?(path) && path.match?(READ) }).reject { |path| skipped?(root, path) }
      end

      # @return [Array<String>] the paths below `root`, once each, sorted
      def relative(root, paths)
        base = "#{File.expand_path(root)}/"
        paths.map { |path| File.expand_path(path).delete_prefix(base) }.uniq.sort
      end

      # @return [Boolean] whether a path is output, or a record, or marked as a page to leave alone
      def skipped?(root, path)
        path.match?(SKIPPED) || (path.end_with?(".md") && CommandNames::Sources.historical?(root, path))
      end

      # @param text [String] one file
      # @return [Boolean] whether its first lines mark it historical or skip it whole
      def excused?(text)
        text.lines.first(WINDOW).any? { |line| line.match?(HISTORICAL) || line.include?("#{MARKER}-file") }
      end

      # @return [Boolean] whether the line or the one before it carries the skip marker
      def marked?(lines, index)
        [lines[index], (lines[index - 1] if index.positive?)].compact.any? { |line| line.include?(MARKER) }
      end
    end
  end
end
