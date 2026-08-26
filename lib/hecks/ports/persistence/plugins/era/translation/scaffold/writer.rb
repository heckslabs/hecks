require "fileutils"

module Hecks
  module Translation
    module Scaffold
      # Put the rendered edge on disk, regenerating in place when a file
      # for the same shape pair already exists.
      module Writer
        # The edge file, regenerated in place when one for the same shape
        # pair already exists (matched textually — an unresolved file
        # cannot be LOADED to ask, that being the whole point of
        # unresolved).
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
