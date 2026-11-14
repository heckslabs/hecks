module Hecks
  module Tools
    module ModelCheck
      # Boots a domain's source into a registry of its own, so the checks read IR and nothing runs.
      # `ModelCheck` extends it.
      module Sources
        # The framework files a booted source needs loaded first, under `ModelCheck::HECKS_DIR`.
        FRAMEWORK_FILES = [
          "ports/persistence.port", "ports/extraction.port",
          "adapters/driven/memory.adapter", "adapters/driven/prism.adapter"
        ].freeze
        # The `.bluebook` extension ending a source path.
        BLUEBOOK_EXTENSION = /\.bluebook\z/

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
          load_wiring(source)
        end

        # A port attaches to its aggregate from the hecksagon, not the bluebook, so a deaf-policy
        # check that skipped it would miss a policy reacting to an event nothing emits. Recording a
        # bind builds IR only; no adapter resolves here. A bluebook that ships its ports beside its
        # bluebook (`<name>.ports.hecksagon`) is read with them.
        #
        # A context map is held against the wiring just read, so it loads last (ADR 0135): a source
        # booted without its map is checked for no declared relationship and no accepted cycle.
        #
        # @api private
        def load_wiring(source)
          (hecksagons_of(source) + context_maps_of(source)).each { |file| Kernel.load(file) if File.exist?(file) }
        end

        # @api private
        def context_maps_of(source)
          return Dir.glob(File.join(source, "*.contextmap")) if File.directory?(source)

          [source.sub(BLUEBOOK_EXTENSION, ".contextmap")]
        end

        # @api private
        def hecksagons_of(source)
          return Dir.glob(File.join(source, "*.hecksagon")) if File.directory?(source)

          [".hecksagon", ".ports.hecksagon"].map { |suffix| source.sub(BLUEBOOK_EXTENSION, suffix) }
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
