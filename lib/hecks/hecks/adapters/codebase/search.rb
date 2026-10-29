# frozen_string_literal: true

require_relative "tree"
require_relative "../console_capture"

module Hecks
  module Adapters
    module Codebase
      # What Codebase's `Search` query asks of the working tree: the lines of its text files that
      # match a regular expression, so a reader never has to leave the launcher for `grep`.
      #
      # Directories that hold no source of their own (version control, build output, vendored
      # packages, scratch space, sibling worktrees) are left out, and so is any file with a null
      # byte in its first block, which is how a binary announces itself.
      module Search
        # Directory names that are never walked.
        SKIPPED = %w[.git target node_modules tmp vendor worktrees].freeze

        # The rows kept when `top` is not named.
        DEFAULT_TOP = 200

        # Searched when no path is named.
        DEFAULT_PATHS = "."

        # How much of a file is read to tell text from binary.
        SNIFF_BYTES = 8192

        module_function

        # @param args [Hash] the query's arguments: `pattern`, `paths`, `top`
        # @param tree [Tree] the working tree, already known to be a hecks checkout
        # @return [String] one `path:line: text` row per match, in path order
        # @raise [ConsoleCapture::Failure] when the pattern is not a regular expression
        def report(args, tree)
          matcher = compile(args.fetch(:pattern))
          limit = args[:top] || DEFAULT_TOP
          rows = []
          files(tree, args[:paths] || DEFAULT_PATHS).each do |file|
            matches(tree, file, matcher, limit, rows)
            break if rows.length >= limit
          end
          rows.join("\n")
        end

        # @return [Regexp] the pattern, compiled
        # @raise [ConsoleCapture::Failure] when it does not compile
        def compile(pattern)
          Regexp.new(pattern)
        rescue RegexpError => e
          raise ConsoleCapture::Failure, "not a regular expression: #{e.message}"
        end

        # @param limit [Integer] the most rows `rows` may hold
        # @param rows [Array<String>] the rows so far; the matches of `file` are appended
        def matches(tree, file, matcher, limit, rows)
          File.foreach(tree.path(file), chomp: true).with_index(1) do |line, number|
            break if rows.length >= limit
            next unless line.valid_encoding? && matcher.match?(line)

            rows << "#{file}:#{number}: #{line.strip}"
          end
        end

        # @return [Array<String>] the text files under the named paths, relative to the root, sorted
        def files(tree, paths)
          named = paths.split(",").flat_map { |path| listing(tree, path) }
          named.uniq.sort.select { |file| text?(tree, file) }
        end

        # @return [Array<String>] the files at one path: itself when a file, else all below it
        def listing(tree, path)
          return [path.delete_prefix("./")] if File.file?(tree.path(path))

          below = Dir.glob("#{path.chomp("/")}/**/*", File::FNM_DOTMATCH, base: tree.root)
          below.select { |entry| File.file?(tree.path(entry)) && walkable?(entry) }
               .map { |entry| entry.delete_prefix("./") }
        end

        # @return [Boolean] whether no directory on the way to `entry` is one that is skipped
        def walkable?(entry)
          !entry.split("/")[0...-1].intersect?(SKIPPED)
        end

        # @return [Boolean] whether the file's first block holds no null byte
        def text?(tree, file)
          !File.binread(tree.path(file), SNIFF_BYTES).to_s.include?("\0")
        end
      end
    end
  end
end
