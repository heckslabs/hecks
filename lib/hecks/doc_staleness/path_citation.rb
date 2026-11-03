module Hecks
  module DocStaleness
    # The repo paths a stretch of text cites, and whether each one is there.
    module PathCitation
      ROOTS = %w[lib spec rust docs qa packages examples deploy release bin .github .githooks].freeze

      # A path that starts at one of the checkout's top directories, not inside a longer path.
      TOKEN = %r{(?<![\w./-])(?:#{ROOTS.map { |root| Regexp.escape(root) }.join("|")})/[^\s`'"(),;]*}

      # A mark of a pattern, a placeholder or a generated name rather than a file.
      NOT_A_PATH = %r{[<>*{}$|\[\]?]|\.\.\.|…|//}

      # A segment that stands for any name.
      PLACEHOLDER = /
        \A(?:[a-z](?:_\w+)?|N{2,}(?:-\w+)*|slug|foo|bar|baz|name|path|file|dir
        |thing\w*|my_\w+|your_\w+|example(?:_\w+)?)(?:\.\w+)?\z
      /x

      # A name a number or a trailing `_` or `-` leaves open, as in `docs/decisions/0059`.
      OPEN_NAME = %r{/(?:\d{4}|[^/]*[_-])\z}

      # What follows a path in prose: an anchor, a line number, closing punctuation.
      ANCHOR = /#.*\z/
      LINE_NUMBER = /:\d+(?:-\d+)?\z/
      PUNCTUATION = /[.:]+\z/

      # Directories created by a build or a run, absent from a fresh checkout.
      RUNTIME = %r{(?:\A|/)(?:target|node_modules|tmp|coverage|dist)(?:/|\z)}

      module_function

      # @param text [String] a stretch of prose or comment
      # @return [Array<String>] the cited repo paths, without punctuation, anchors or line numbers
      def cited(text) = text.scan(TOKEN).map { |token| clean(token) }.reject { |path| ignorable?(path) }

      # @return [Array<String>] the cited paths that name nothing in the checkout
      def missing(text, root) = cited(text).reject { |path| exists?(root, path) }

      # A path is there as written, as a Ruby file without its `.rb`, or as the start of a name a
      # number or a trailing `_` or `-` leaves open (`docs/decisions/0059`, `spec/qa_tick_`).
      def exists?(root, path)
        full = File.join(root, path)
        return true if File.exist?(full) || File.exist?("#{full}.rb")

        path.match?(OPEN_NAME) && !Dir.glob("#{full}*").empty?
      end

      def clean(token)
        bare = token.sub(ANCHOR, "").sub(PUNCTUATION, "")
        bare.sub(LINE_NUMBER, "").sub(PUNCTUATION, "")
      end

      def ignorable?(path)
        bare_root?(path) || path.match?(NOT_A_PATH) || path.match?(RUNTIME) || placeholder?(path)
      end

      # A top directory named alone, such as `bin/`, is prose about the directory.
      def bare_root?(path) = path.chomp("/").count("/").zero?

      def placeholder?(path) = path.split("/").drop(1).any? { |part| part.match?(PLACEHOLDER) }
    end
  end
end
