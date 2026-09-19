require "fileutils"

module Hecks
  module Translation
    module Scaffold
      # Put the rendered edge on disk, regenerating in place when a file
      # for the same shape pair already exists.
      module Writer
        # Renders an edge and writes it under `directory/translations`, regenerating in
        # place when a file for the same shape pair already exists.
        #
        # The edge file, regenerated in place when one for the same shape
        # pair already exists (matched textually — an unresolved file
        # cannot be loaded to ask, that being the whole point of
        # unresolved).
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
