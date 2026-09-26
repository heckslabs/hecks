require_relative "../ports/persistence/plugins/era/storage_shape"

module Hecks
  module EmbryonautBluebook
    # The storage-shape labels of a directory of `*.bluebook` files.
    #
    # A label is what `PostgresEra` mints an era from, so a vendored package
    # whose label changed is one whose next deploy mints a new era. This reads
    # the files the way the era guard reads a held era's text: parse only, no
    # boot, no wiring, no database, each file loaded into a scratch registry.
    module Shape
      module_function

      # Measures every domain a directory's bluebook files declare.
      #
      # @param dir [String] a directory holding `*.bluebook` files
      # @return [Array<String>] one `"<Domain> <label>"` line per domain, sorted by domain name
      # @raise [Vendoring::Error] if the directory holds no bluebook file, or the files do
      #   not load, the refusal a boot would raise
      def labels(dir)
        files = Dir[File.join(dir, "*.bluebook")]
        raise Vendoring::Error, "no *.bluebook files in #{dir}" if files.empty?

        load_all(files).bluebooks.sort_by { |name, _| name.to_s }.map do |name, bluebook|
          "#{name} #{Runtime::StorageShape.mint_label(bluebook)}"
        end
      end

      # Loads bluebook files into a registry of their own.
      #
      # @param files [Array<String>] absolute bluebook file paths, in load order
      # @return [Runtime::Registry] the scratch registry holding what the files declared
      # @raise [Vendoring::Error] if any file fails to load
      def load_all(files)
        scratch = Runtime::Registry.new
        library = Ports::Loading.bootstrap
        Hecks.with_registry(scratch) do
          library.load_library
          files.each { |file| Kernel.load(file) }
        end
        scratch
      rescue StandardError, ScriptError => e
        raise Vendoring::Error, "the bluebook files do not load: #{e.class}: #{e.message.lines.first.to_s.strip}"
      end
    end
  end
end
