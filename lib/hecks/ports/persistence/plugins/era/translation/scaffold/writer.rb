require "fileutils"

module Hecks
  module Translation
    module Scaffold
      # Writes the rendered edge to disk, reusing the file for the same shape pair if present.
      module Writer
        # Renders an edge and writes it under `directory/translations`.
        # An existing file is matched textually because an unresolved file cannot be loaded.
        #
        # @param directory [String] the domain's root directory
        # @param edge [Scaffold::Edge] the edge to render and write
        # @return [String] the path written, either the matched existing file or a new
        #   `<ordinal>-<label>.bluebook`
        def write!(directory, edge)
          translations_dir = File.join(directory, "translations")
          FileUtils.mkdir_p(translations_dir)

          existing = Dir[File.join(translations_dir, "*.bluebook")].find do |path|
            text = File.read(path)
            text.include?("from: #{edge.from.inspect}") && text.include?("to: #{edge.to.inspect}")
          end
          path = existing || File.join(translations_dir, "#{edge.ordinal}-#{edge.label}.bluebook")
          File.write(path, render(edge))
          path
        end
      end
    end
  end
end
