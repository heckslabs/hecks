# frozen_string_literal: true

module Hecks
  module Adapters
    # The names a read of history takes from a caller, checked before they reach git: a commit
    # range, a single revision, and a path inside the repository. A name git could read as an
    # option, or a path that leaves the repository, is refused with a `ConsoleCapture::Failure`.
    module GitNames
      # A commit range as git writes one: names joined by `..` or `...`, never an option.
      RANGE = %r{\A[0-9A-Za-z_][0-9A-Za-z_./^~@{}-]*\z}

      private

      def checked_range(range)
        return range if range.match?(RANGE)

        raise ConsoleCapture::Failure, "#{range.inspect} is not a commit range"
      end

      # One revision: a range's characters, but no `..` and so no range.
      def checked_revision(revision)
        return revision if revision.to_s.match?(RANGE) && !revision.include?("..")

        raise ConsoleCapture::Failure, "#{revision.inspect} is not a single revision"
      end

      # A path inside the repository: relative to its top level, one line, no `..` step. The empty
      # path is the top level itself, which git lists.
      def checked_path(path)
        text = path.to_s
        return text unless text.match?(%r{\A[/-]|\A\./|(\A|/)\.\.(/|\z)|[\n\0]})

        raise ConsoleCapture::Failure, "#{path.inspect} is not a path from the repository's top level"
      end
    end
  end
end
