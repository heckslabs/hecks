module Hecks
  module CLI
    module ModelCheck
      # Boots a domain's source into a registry of its own, so the checks read IR and nothing runs.
      # `ModelCheck` extends it.
      module Sources
        # The framework files a booted source needs loaded first, under `ModelCheck::HECKS_DIR`.
        FRAMEWORK_FILES = [
          "ports/persistence.port", "ports/extraction.port",
          "adapters/driven/memory.adapter", "adapters/driven/prism.adapter"
        ].freeze

        # `root:` is the source's parent, so a member declaring
        # `attaches ... from: :vendor` can vendor from it.
        def boot(source)
          root = File.directory?(source) ? File.dirname(source) : nil
          registry = Runtime::Registry.new(root: root)
          Hecks.with_registry(registry) { load_source(source) }
          registry
        end

        # @api private
        def load_source(source)
          FRAMEWORK_FILES.each { |file| Kernel.load(File.join(HECKS_DIR, file)) }
          folder = Adapters::Folder.new
          if File.directory?(source)
            folder.load_bluebooks(source)
          else
            folder.load_bluebooks(File.dirname(source), [File.basename(source)])
          end

          # A port attaches to its aggregate from the hecksagon, not the bluebook, so a
          # deaf-policy check that skipped it would miss a policy reacting to an event
          # nothing emits. Recording a bind builds IR only; no adapter resolves here. A chapter
          # that ships its ports beside its bluebook (`<name>.ports.hecksagon`) is read with them.
          hecksagons_of(source).each { |hecksagon| Kernel.load(hecksagon) if File.exist?(hecksagon) }
        end

        # @api private
        def hecksagons_of(source)
          return Dir.glob(File.join(source, "*.hecksagon")) if File.directory?(source)

          [".hecksagon", ".ports.hecksagon"].map { |suffix| source.sub(/\.bluebook\z/, suffix) }
        end

        # The same rule `Corpus.bluebook_dir` applies.
        def bluebook_dir(domain_path)
          [File.join(domain_path, "bluebook"), domain_path].each do |dir|
            files = Dir[File.join(dir, "*.bluebook")]
            return File.dirname(files.first) unless files.empty?
          end
          nil
        end
      end
    end
  end
end
