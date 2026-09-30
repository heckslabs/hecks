# frozen_string_literal: true

require "json"
require_relative "../../hecks"
# The `:shape` projection reads `Runtime::StorageShape`, which lives in the era persistence plugin
# core does not load by default (ADR 0033).
require_relative "../ports/persistence/plugins/era"

module Hecks
  module CLI
    # The command behind `bin/shape` and `hecks shape`: a bluebook's storage-shape projection, the
    # same hash PostgresEra mints an era's label from, so two runs diff to show whether a bluebook
    # change would bump an era.
    module Shape
      module_function

      # Prints the projection of a bluebook file as JSON, or one `<Domain> <label>` line per domain
      # of a directory (files in subdirectories are not read).
      #
      # @param argv [Array<String>] the bluebook file or directory, first
      # @param program [String] the name the usage message calls this command by
      # @return [void]
      # @raise [SystemExit] when `argv` is empty, the path is missing or holds no bluebook
      def call(argv, program: "bin/shape")
        target = argv.first or abort "usage: #{program} <bluebook | directory of *.bluebook files>"
        puts render(target)
      rescue Runtime::NotFound => e
        abort e.message
      end

      # @param target [String] a bluebook file, or a directory of them
      # @return [String] the storage-shape projection as JSON for a file, or one
      #   `<Domain> <label>` line per domain for a directory
      # @raise [Runtime::NotFound] if the path does not exist or holds no bluebook
      def render(target)
        raise Runtime::NotFound, "#{target} does not exist" unless File.exist?(target)

        directory = File.directory?(target)
        files = directory ? Dir[File.join(target, "*.bluebook")] : [target]
        raise Runtime::NotFound, "no *.bluebook files in #{target}" if files.empty?

        registry = load_files(files)
        return labels(registry) if directory

        bluebook = registry.bluebooks.values.first or raise Runtime::NotFound, "#{target} declares no bluebook"
        JSON.pretty_generate(Projector.call(:shape, bluebook: bluebook))
      end

      # @param files [Array<String>] bluebook files
      # @return [Runtime::Registry] a registry holding every bluebook the files declare
      def load_files(files)
        registry = Runtime::Registry.new
        loading  = Ports::Loading.bootstrap
        Hecks.with_registry(registry) do
          loading.load_library
          files.each { |file| Kernel.eval(File.read(file), TOPLEVEL_BINDING, File.expand_path(file), 1) }
        end
        registry
      end

      # @param registry [Runtime::Registry] a loaded registry
      # @return [String] one `<Domain> <label>` line per bluebook, sorted by name
      def labels(registry)
        registry.bluebooks.sort_by { |name, _| name.to_s }
                .map { |name, bluebook| "#{name} #{Runtime::StorageShape.mint_label(bluebook)}" }
                .join("\n")
      end
    end
  end
end
