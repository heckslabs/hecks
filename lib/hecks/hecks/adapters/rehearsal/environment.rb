# frozen_string_literal: true

module Hecks
  module Adapters
    module Rehearsal
      # Which environment overlay (`environments/<name>.hecksagon` and `.world`) a rehearsal loads
      # the subject under, and where that was decided.
      #
      # A rehearsal is about the era the production binds will mint, so it loads `production` when
      # the domain has `environments/production.hecksagon`, the same default the Rust host build
      # takes (`ProjectRust::DomainLoader#load_environment`). Most domains bind their aggregates
      # to a database only in that overlay, so the base files alone have no `persisted_by` bind.
      # The choice is a reported fact (`environment_loaded`), never a silent one.
      class Environment
        # Where the name came from, in the order they are tried.
        SOURCES = %w[world HECKS_PROJECT_ENVIRONMENT default none].freeze

        NONE_WORDS = "no environment overlay (none named in rehearsed_by or HECKS_PROJECT_ENVIRONMENT, " \
                     "and no environments/production.hecksagon)"

        # @!attribute [r] name
        #   @return [String] the overlay's name, or `""` when none was loaded
        # @!attribute [r] source
        #   @return [String] one of `SOURCES`
        # @!attribute [r] directory
        #   @return [String] the bluebook directory the overlay is looked for under
        attr_reader :name, :source, :directory

        # @param declared [String, nil] what the world's `rehearsed_by` names (`environment "..."`)
        # @param directory [String] the domain's bluebook directory
        # @return [Environment] the choice: the world's, else `HECKS_PROJECT_ENVIRONMENT`, else
        #   `production` when its overlay exists, else none
        def self.resolve(declared, directory)
          env = ENV.fetch("HECKS_PROJECT_ENVIRONMENT", "")
          return new(declared, "world", directory) if declared && !declared.empty?
          return new(env, "HECKS_PROJECT_ENVIRONMENT", directory) unless env.empty?
          return new("production", "default", directory) if File.exist?(File.join(directory, "environments",
                                                                                  "production.hecksagon"))

          new("", "none", directory)
        end

        # @param name [String] the overlay's name
        # @param source [String] one of `SOURCES`
        # @param directory [String] the bluebook directory
        def initialize(name, source, directory)
          @name = name
          @source = source
          @directory = directory
        end

        # @return [String, nil] the name to load, nil when no overlay is wanted
        def overlay = name.empty? ? nil : name

        # @return [Boolean] whether the hecksagon file of this overlay exists
        def overlay_file? = File.exist?(file)

        # @return [String] the hecksagon file the overlay is looked for in
        def file = File.join(directory, "environments", "#{name}.hecksagon")

        # @return [Hash] the report fact, as the `Environment` value object holds it
        def facts = { name: name, source: source, file: name.empty? ? "" : file }

        # @return [String] what the overlay choice was, in words
        def to_s
          return NONE_WORDS if name.empty?

          "environment #{name.inspect} (#{source}), file #{file} #{overlay_file? ? "found" : "NOT FOUND"}"
        end

        # The overlays the directory holds, so a refusal can say what could be chosen.
        #
        # @return [Array<String>] the names of `environments/*.hecksagon`
        def available
          Dir.glob(File.join(directory, "environments", "*.hecksagon")).map { |path| File.basename(path, ".hecksagon") }.sort
        end

        # @return [String] the overlays the directory holds, comma separated, or `none`
        def available_words = available.empty? ? "none" : available.join(", ")
      end
    end
  end
end
