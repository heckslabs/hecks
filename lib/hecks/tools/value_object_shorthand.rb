# frozen_string_literal: true

module Hecks
  module Tools
    # Rewrites a value object block that only wraps one plain `value` attribute into the shorthand
    # that says the same thing in one line: `value_object "Name", Type`.
    #
    # A block with an invariant, a constraint such as `matches:`, a comment, or any other attribute
    # is left alone: the block is the only place those can go. This is the rule the
    # `Hecks/ValueObjectShorthand` cop states for Ruby, applied to bluebook files.
    module ValueObjectShorthand
      # A block whose whole body is `attribute :value, Type`.
      BARE = /^([ \t]*)value_object "(\w+)" do\n[ \t]*attribute :value, (\w+)\n[ \t]*end\n/

      # Where bluebooks are looked for when no path is named.
      DEFAULT_PATHS = %w[lib qa examples].freeze

      module_function

      # @param paths [Array<String>] files or folders, relative to `root`; the defaults when empty
      # @param root [String] the checkout the paths are relative to
      # @param write [Boolean] rewrite the files; false only counts what a rewrite would change
      # @return [Hash{String => Integer}] each file's count of blocks that are, or were, rewritten
      def shorten(paths, root:, write:)
        found = {}
        bluebooks(paths, root).each do |file|
          text = File.read(file)
          count = text.scan(BARE).size
          next if count.zero?

          File.write(file, rewritten(text)) if write
          found[file.delete_prefix("#{root}/")] = count
        end
        found
      end

      # @param text [String] a bluebook's source
      # @return [String] the source with every bare block written as the shorthand
      def rewritten(text)
        text.gsub(BARE) do
          indent = Regexp.last_match(1)
          name = Regexp.last_match(2)
          "#{indent}value_object \"#{name}\", #{Regexp.last_match(3)}\n"
        end
      end

      # @return [Array<String>] every `.bluebook` file under the paths, sorted
      def bluebooks(paths, root)
        named = paths.empty? ? DEFAULT_PATHS : paths
        named.flat_map { |path| Dir.glob(File.join(root, path, "**", "*.bluebook")) + single(path, root) }.uniq.sort
      end

      # @return [Array<String>] the path itself when it names one bluebook file
      def single(path, root)
        file = File.join(root, path)
        File.file?(file) && file.end_with?(".bluebook") ? [file] : []
      end
    end
  end
end
