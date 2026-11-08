# frozen_string_literal: true

require "pathname"

module Hecks
  module Adapters
    # When two file areas overlap: the one rule behind a Work item's `area` claim and a Landing's
    # changed files. An area is a path prefix (`lib/hecks`) or a glob (`lib/**/*.rb`), compared by
    # whole segments, so `lib/hecks` holds `lib/hecks/a` and not `lib/hecks_extra`.
    #
    # It never misses a real overlap; it may report one that is not real. Areas are normalized
    # first (`//`, `.`, `..`, a trailing `/`, absolute paths made repository-relative, case folded
    # where the filesystem folds it). Then they overlap unless a segment proves them apart: a
    # prefix holds everything beneath it, the empty area is the whole repository, `**` stands for
    # any depth, and a glob without a `/` matches at any depth. A file holds nothing beneath it.
    module AreaOverlap
      # Characters that make a segment a glob.
      WILDCARD = /[*?\[{]/

      # A brace group that holds a `/`, which splitting on `/` would tear apart.
      SLASHED_BRACE = /\{[^}]*\/[^}]*\}/

      # The segment that stands for any number of directories.
      ANY = "**"

      # The leading segment that puts a path outside the repository in a place no area of it has.
      OUTSIDE = "/outside/"

      # How a single segment glob is matched.
      MATCHING = File::FNM_EXTGLOB | File::FNM_DOTMATCH

      module_function

      # Whether two areas overlap.
      #
      # @param one [String] a path prefix or glob
      # @param other [String] a path prefix or glob
      # @param root [String, nil] the repository's top level, to make absolute paths relative
      # @param file [Boolean] whether `other` is known to be a file, which holds nothing beneath it
      # @return [Boolean]
      def overlap?(one, other, root: nil, file: false)
        folded = fold_case?(root)
        left = segments(one, root, folded)
        right = segments(other, root, folded)
        return true if left.nil? || right.nil?

        file ? meet?(left, right, leaf: true) : meet?(left, right)
      end

      # Whether an area is an absolute path in some other checkout than `root`: the one rule that
      # tells another repository's areas apart from this repository's.
      #
      # @param path [String] a path prefix or glob
      # @param root [String, nil] the repository's top level
      # @return [Boolean] false for a relative area, or when no root is known
      def outside?(path, root:)
        text = path.to_s.strip
        return false unless root && text.start_with?("/")

        relative_to(text, root, fold_case?(root)).start_with?(OUTSIDE)
      end

      # The first pair of paths, one from each list, that overlap.
      #
      # @param mine [Array<String>] areas or file paths
      # @param theirs [Array<String>] areas or file paths
      # @param root [String, nil] the repository's top level
      # @return [Array(String, String), nil] the pair, or nil when none overlap
      def first_overlap(mine, theirs, root: nil)
        mine.each do |one|
          theirs.each { |other| return [one, other] if overlap?(one, other, root: root) }
        end
        nil
      end

      # @return [Array<String>, nil] the normalized segments, nil when the path may be anywhere
      def segments(path, root, folded)
        text = path.to_s.strip
        text = text.downcase if folded
        return [ANY] if text.match?(SLASHED_BRACE)

        relative = relative_to(text, root, folded)
        relative && anywhere(collapse(relative.split("/")), relative)
      end

      # A glob without a `/` matches at any depth, as it does in a git pathspec.
      def anywhere(parts, text)
        parts.size == 1 && wild?(parts.first) && !text.include?("/") ? [ANY, parts.first] : parts
      end

      # @return [String, nil] the path under the repository; nil when it is absolute and could be
      #   anywhere (no root known); a path outside the root gets a segment no area has
      def relative_to(text, root, folded)
        return text unless text.start_with?("/")
        return nil unless root

        inside = under(text, folded ? root.downcase : root)
        inside.start_with?("..") ? "#{OUTSIDE}#{text}" : inside
      end

      # @return [String] the path from `root`; empty for the root itself
      def under(text, root)
        found = cleaned(text).relative_path_from(cleaned(root)).to_s
        found == "." ? "" : found
      end

      def cleaned(text) = Pathname.new(text).cleanpath

      # @return [Array<String>] the segments without empty and `.` ones, `..` applied
      def collapse(parts)
        parts.each_with_object([]) do |part, kept|
          next if part.empty? || part == "."

          part == ".." ? up(kept) : kept << part
        end
      end

      def up(kept)
        return kept << ".." if kept.empty? || kept.last == ".."

        kept << ANY if kept.pop == ANY
      end

      # @return [Boolean] whether the filesystem under `root` treats `A` and `a` alike
      def fold_case?(root)
        base = root || Dir.pwd
        swapped = base.swapcase
        swapped != base && File.exist?(swapped) && File.identical?(swapped, base)
      rescue SystemCallError
        false
      end

      # @param leaf [Boolean] whether `right` is a file, so it holds nothing beneath it
      # @return [Boolean] whether two segment lists can name a common path
      def meet?(left, right, leaf: false)
        return exhausted?(left, right, leaf) if left.empty? || right.empty?
        return meet?(right, left) if swap?(left, right, leaf)
        return reaches?(left, right, leaf) if left.first == ANY

        segments_meet?(left.first, right.first) && meet?(left.drop(1), right.drop(1), leaf: leaf)
      end

      # One list ran out: its path holds the rest, unless that is a file's.
      def exhausted?(left, right, leaf) = left.empty? || (right.empty? && (!leaf || left.all?(ANY)))

      # Puts a leading `**` on the left.
      def swap?(left, right, leaf) = !leaf && right.first == ANY && left.first != ANY

      # A leading `**` matches no segment or swallows one of the other list's.
      def reaches?(left, right, leaf)
        meet?(left.drop(1), right, leaf: leaf) || meet?(left, right.drop(1), leaf: leaf)
      end

      def segments_meet?(one, other)
        return one == other unless wild?(one) || wild?(other)
        return File.fnmatch?(other, one, MATCHING) if wild?(other) && !wild?(one)
        return File.fnmatch?(one, other, MATCHING) unless wild?(other)

        beginnings_agree?(one, other)
      end

      def beginnings_agree?(one, other)
        left = one.split(WILDCARD, 2).first.to_s
        right = other.split(WILDCARD, 2).first.to_s
        left.start_with?(right) || right.start_with?(left)
      end

      # @return [Boolean] whether the segment is a glob
      def wild?(segment) = segment.match?(WILDCARD)
    end
  end
end
