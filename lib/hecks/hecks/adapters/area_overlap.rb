# frozen_string_literal: true

module Hecks
  module Adapters
    # When two file areas overlap: the one rule behind a Work row's `area` claim and a Landing's
    # changed files. An area is a path prefix (`lib/hecks/tickets`) or a glob (`lib/**/*.rb`),
    # compared by whole segments, so `lib/hecks` holds `lib/hecks/a` and not `lib/hecks_extra`.
    #
    # - Two prefixes overlap when one equals or holds the other.
    # - A glob and a prefix overlap when the glob matches the prefix or a directory above it, or
    #   the prefix holds the glob's literal stem (`lib` holds `lib/a/*.rb`).
    # - Two globs overlap when either's literal stem (the segments before the first wildcard)
    #   holds the other's: conservative, it never misses an overlap.
    module AreaOverlap
      # Characters that make a segment a glob.
      WILDCARD = /[*?\[{]/

      # A leading `./` and a trailing `/`, which name no segment.
      LEADING_DOT = %r{\A(\./)+}
      TRAILING_SLASH = %r{/+\z}

      module_function

      # Whether two areas overlap.
      #
      # @param one [String] a path prefix or glob
      # @param other [String] a path prefix or glob
      # @return [Boolean]
      def overlap?(one, other)
        left = clean(one)
        right = clean(other)
        return holds?(left, right) || holds?(right, left) unless glob?(left) || glob?(right)
        return stems_overlap?(left, right) if glob?(left) && glob?(right)

        glob, path = glob?(left) ? [left, right] : [right, left]
        glob_covers?(glob, path)
      end

      # The first pair of paths, one from each list, that overlap.
      #
      # @param mine [Array<String>] areas or file paths
      # @param theirs [Array<String>] areas or file paths
      # @return [Array(String, String), nil] the pair, or nil when none overlap
      def first_overlap(mine, theirs)
        mine.each do |one|
          theirs.each { |other| return [one, other] if overlap?(one, other) }
        end
        nil
      end

      # @return [String] the path without a leading `./` or a trailing `/`
      def clean(path) = trimmed(path.to_s.strip)

      def trimmed(path) = path.sub(LEADING_DOT, "").sub(TRAILING_SLASH, "")

      # @return [Boolean] whether `outer` is `inner` or a directory above it
      def holds?(outer, inner) = inner == outer || inner.start_with?("#{outer}/")

      # @return [Boolean] whether the path has a wildcard segment
      def glob?(path) = path.match?(WILDCARD)

      # @return [String] the segments of a glob before its first wildcard
      def stem(glob) = glob.split("/").take_while { |segment| !segment.match?(WILDCARD) }.join("/")

      def stems_overlap?(one, other)
        left = stem(one)
        right = stem(other)
        holds?(left, right) || holds?(right, left)
      end

      def glob_covers?(glob, path)
        return true if holds?(path, stem(glob))

        ancestors(path).any? { |above| File.fnmatch?(glob, above, File::FNM_PATHNAME | File::FNM_EXTGLOB | File::FNM_DOTMATCH) }
      end

      def ancestors(path)
        parts = path.split("/")
        (1..parts.size).map { |count| parts.take(count).join("/") }
      end
    end
  end
end
