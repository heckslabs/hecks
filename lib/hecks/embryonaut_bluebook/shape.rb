require_relative "../ports/persistence/plugins/era/storage_shape"

module Hecks
  module EmbryonautBluebook
    # A label change here means a vendored package's next deploy mints a new PostgresEra.
    module Shape
      module_function

      def labels(dir)
        files = Dir[File.join(dir, "*.bluebook")]
        raise Vendoring::Error, "no *.bluebook files in #{dir}" if files.empty?

        load_all(files).bluebooks.sort_by { |name, _| name.to_s }.map do |name, bluebook|
          "#{name} #{Runtime::StorageShape.mint_label(bluebook)}"
        end
      end

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
