module Hecks
  module CommandNames
    # The files whose text shells out to the launcher, and the ones left out.
    module Sources
      # Globs, relative to the checkout, of the files a line may invoke the launcher in.
      INCLUDED = %w[
        .github/workflows/*.yml .github/workflows/*.yaml .github/actions/**/* .githooks/*
        lib/hecks/language/bluebook/vocabulary.bluebook Makefile scripts/**/* spec/**/*.rb
        *.md docs/**/*.md examples/**/*.md packages/**/*.md rust/**/*.md release/**/*.md editors/**/*.md
        lib/**/*.rb qa/**/*.rb qa/**/*.md qa/**/*.sh qa/**/*.yml
        .claude/hooks/* .claude/settings.json .claude/skills/**/*.md .claude/agents/**/*.md
      ].freeze

      # Exact lines left unflagged. Each is a dead name kept on purpose until a person picks the
      # command that replaces it; remove the entry when that command exists.
      #
      # The headers below are written into committed generated files (diagrams, the Rust syntax and
      # phrase tables, the site routes, the kernel templates) and specs assert them, so renaming
      # one is a regeneration of those files and its own change.
      ALLOWED_LINES = [
        # The mint plan's ledger line has no successor command yet.
        "exe/hecks Maintenance.mint_era! run.value=<run-id>",
        "hecks project_diagrams", "hecks project_parser_table", "hecks project_phrase_table",
        "hecks measure_kernel_coverage",
        # The installed gem's own `hecks vendor`, which a client runs outside this launcher.
        "(the name `hecks vendor` accepts)", "`hecks site site_projection.project_site"
      ].freeze

      # Paths that record what was once true, so a retired name in them is history, not a fault.
      HISTORICAL = %r{\A(?:docs/decisions/|docs/implemented/decisions/|docs/archive/|CHANGELOG\.md\z)}

      # A banner in a document's first lines that says it records a moment.
      SNAPSHOT = /\A(?:>\s*)?\*\*Historical snapshot\b/

      # A line in a document's first lines that excuses the whole file, such as a page that lists
      # the names a rename leaves behind.
      SKIP_FILE = "dead-name-check: skip-file".freeze

      # How many lines from the top count as "the first lines".
      BANNER_WINDOW = 12

      module_function

      # @param root [String] the checkout
      # @return [Array<String>] the paths to scan, relative to `root`, sorted
      def files(root)
        scanned(root).reject { |path| historical?(root, path) }
      end

      # @return [Array<String>] every file the globs reach, relative to `root`, sorted
      def scanned(root)
        paths = INCLUDED.flat_map { |glob| Dir.glob(File.join(root, glob), File::FNM_DOTMATCH) }
        relative(root, paths.select { |path| File.file?(path) })
      end

      # @return [Array<String>] the paths below `root`, once each, sorted
      def relative(root, paths) = paths.map { |path| path.delete_prefix("#{root}/") }.uniq.sort

      # @return [Boolean] whether a path is history: a decision record, the changelog, an archive, a
      #   document whose first lines call it a historical snapshot, or one that excuses itself
      def historical?(root, path)
        return true if path.match?(HISTORICAL)

        File.foreach(File.join(root, path), encoding: "UTF-8").first(BANNER_WINDOW).any? { |line| excused?(line) }
      end

      # @return [Boolean] whether a line carries one of the allowed strings
      def allowed?(text) = ALLOWED_LINES.any? { |allowed| text.include?(allowed) }

      def excused?(line) = line.match?(SNAPSHOT) || line.include?(SKIP_FILE)
    end
  end
end
