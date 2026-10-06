require_relative "evolve/seeds"
require_relative "evolve/keywords"
require_relative "evolve/arguments"

module Hecks
  module Grammar
    # File surgery under `hecks word_status` and its siblings: reads and rewrites the
    # aggregate-local KeywordSeed/ArgumentSeed rows as text, preserving the table's own formatting.
    #
    # The row readers and edits live in `Seeds`, `Keywords` and `Arguments`, extended onto this
    # module; what is here is the reading and writing of the table files themselves.
    module Evolve
      class Refusal < StandardError; end

      # The stations a word's or an argument's life admits.
      STATIONS = %w[proposed admitted deprecated retired].freeze

      extend Seeds
      extend Keywords
      extend Arguments

      module_function

      # Only consumes the next argv element as the value when it isn't itself
      # a flag, so `--foo --bar` doesn't swallow `--bar` as `--foo`'s value.
      def option(argv, name, default = nil)
        index = argv.index("--#{name}")
        return default unless index

        value = argv[index + 1]
        value.nil? || value.start_with?("-") ? default : value
      end

      # Runs the block against an in-memory copy of the tables: every edit it makes is held, none
      # is written, and later reads see the earlier edits.
      #
      # @yield the edits to rehearse
      # @return [Hash{String => String}] each file the edits changed, with the text it would hold
      def rehearse
        @overlay = {}
        yield
        @overlay.dup
      ensure
        @overlay = nil
      end

      # @param path [String] a table file
      # @return [String] its text: a rehearsed edit if one was made, else what the file holds
      def read_source(path)
        @overlay&.key?(path) ? @overlay[path] : File.read(path)
      end

      # @param path [String] a table file
      # @param text [String] what it holds afterwards; held, not written, while rehearsing
      # @return [Object] the text
      def write_source(path, text)
        @overlay ? (@overlay[path] = text) : File.write(path, text)
      end

      # Snapshots `paths` before running the block and restores every file
      # if it raises, even partway through a multi-file write.
      def restore_on_raise(paths)
        snapshots = paths.to_h { |path| [path, File.read(path)] }
        yield
      rescue StandardError
        snapshots.each { |path, content| File.write(path, content) }
        raise
      end

      # Where the language's own bluebooks live: this checkout's, unless a block is running under
      # `with_language_dir`.
      #
      # @return [String] the directory holding the syntax tables
      def language_dir = @language_dir || File.expand_path("../language", __dir__)

      # Runs the block with every table read and edit aimed at `dir`, so a caller can try real
      # edits on a copy. The language's own files are what other processes load, so an edit that
      # lands on them, even one put back afterwards, can be loaded half-made.
      #
      # @param dir [String] a directory laid out like `lib/hecks/language`
      # @yield the work to run against `dir`
      # @return [Object] what the block returns
      def with_language_dir(dir)
        previous = @language_dir
        @language_dir = dir
        yield
      ensure
        @language_dir = previous
      end

      # Every syntax-table file declaring a KeywordSeed or ArgumentSeed value object.
      def syntax_paths
        Dir.glob(File.join(language_dir, "**/*.bluebook")).select do |path|
          source = read_source(path)
          source.include?('value_object "KeywordSeed"') || source.include?('value_object "ArgumentSeed"')
        end
      end

      # Narrow compatibility door for single-file callers; syntax_paths is normal.
      def syntax_path = syntax_paths.first

      # Resolves the file(s) a call should search or write.
      def paths_for(path) = path ? Array(path) : syntax_paths

      # Refuses a keyword a call was not declared to take, as a method with those keywords would.
      #
      # @param fields [Hash] the keywords the caller passed
      # @param allowed [Array<Symbol>] the keywords the call takes
      # @raise [ArgumentError] naming the first keyword not in `allowed`
      def check_fields!(fields, allowed)
        unknown = fields.keys - allowed
        raise ArgumentError, "unknown keyword: #{unknown.first.inspect}" unless unknown.empty?
      end
    end
  end
end
