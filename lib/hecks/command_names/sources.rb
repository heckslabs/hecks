module Hecks
  module CommandNames
    # The files whose text shells out to the launcher, and the ones left out.
    module Sources
      # Globs, relative to the checkout, of the files a line may invoke the launcher in.
      INCLUDED = %w[
        .github/workflows/*.yml .github/workflows/*.yaml .github/actions/**/* .githooks/*
        lib/hecks/language/bluebook/vocabulary.bluebook Makefile scripts/**/* spec/**/*.rb
        docs/implemented/**/*.md CLAUDE.md
      ].freeze

      # Paths that record what was once true, so a retired name in them is history, not a fault.
      HISTORICAL = %r{\A(?:docs/decisions/|docs/implemented/decisions/|docs/archive/|CHANGELOG\.md\z)}

      # A banner in a document's first lines that says it records a moment.
      SNAPSHOT = /\A(?:>\s*)?\*\*Historical snapshot\b/

      # A line in a document's first lines that excuses the whole file, such as a page that lists the
      # names a rename leaves behind.
      SKIP_FILE = "dead-name-check: skip-file".freeze

      # How many lines from the top count as "the first lines".
      BANNER_WINDOW = 12

      module_function

      # @param root [String] the checkout
      # @return [Array<String>] the paths to scan, relative to `root`, sorted
      def files(root)
        INCLUDED.flat_map { |glob| Dir.glob(File.join(root, glob), File::FNM_DOTMATCH) }
                .select { |path| File.file?(path) }
                .map { |path| path.delete_prefix("#{root}/") }
                .reject { |path| historical?(root, path) }.uniq.sort
      end

      # @return [Boolean] whether a path is history: a decision record, the changelog, an archive, a
      #   document whose first lines call it a historical snapshot, or one that excuses itself
      def historical?(root, path)
        return true if path.match?(HISTORICAL)

        File.foreach(File.join(root, path), encoding: "UTF-8").first(BANNER_WINDOW).any? { |line| excused?(line) }
      end

      def excused?(line) = line.match?(SNAPSHOT) || line.include?(SKIP_FILE)
    end
  end
end
