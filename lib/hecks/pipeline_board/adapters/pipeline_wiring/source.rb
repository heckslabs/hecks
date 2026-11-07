# frozen_string_literal: true

module Hecks
  module Adapters
    module PipelineBoard
      # The bluebook files a booted registry was declared from, and a reading of them as they stand.
      # A reading declares the files into a registry of its own and boots nothing, so it runs no
      # policy, opens no repository and takes no outbox row; the ports and adapters are the booted
      # registry's, which the files do not change.
      class WiringSource
        # The parts of a registry the graph reads.
        Reading = Struct.new(:bluebooks, :ports, :adapters)

        # @param registry [Runtime::Registry] the booted registry whose sources are watched
        def initialize(registry)
          @registry = registry
        end

        # @return [Array<String>] each bluebook file the registry was declared from, once
        def paths
          return [] unless @registry.respond_to?(:bluebook_sources)

          declared = @registry.bluebook_sources.values.flatten
          declared.compact.uniq.sort
        end

        # A cheap look at the files: their size and modification time, nil for one that is gone.
        #
        # @return [Array] changes whenever a watched file is edited, replaced or removed
        def stamp = paths.map { |path| [path, *look(path)] }

        # @return [Reading] the bluebooks as the files declare them now
        # @raise [StandardError] when a file does not declare a valid bluebook
        def read
          fresh = Runtime::Registry.new(root: @registry.root)
          Hecks.with_registry(fresh) { paths.select { |path| File.file?(path) }.each { |path| Kernel.load(path) } }
          Reading.new(fresh.bluebooks, @registry.ports, @registry.adapters)
        end

        private

        def look(path)
          stat = File.stat(path)
          [stat.mtime.to_f, stat.size]
        rescue SystemCallError
          [nil, nil]
        end
      end
    end
  end
end
