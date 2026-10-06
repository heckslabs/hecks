# frozen_string_literal: true

module Hecks
  module RustBuild
    class ProjectRust
      # Loads one domain directory into a fresh registry: its bluebooks, then its translation edges,
      # hecksagons, worlds and environment, in the order the language loads them.
      class DomainLoader
        # The port and adapter declarations every domain load needs, relative to `lib/hecks`.
        FRAMEWORK_FILES = %w[ports/persistence.port ports/extraction.port adapters/driven/memory.adapter
                             adapters/driven/prism.adapter adapters/driven/postgres_era.adapter].freeze

        # @return [Hecks::Runtime::Registry] the registry the domain was loaded into
        attr_reader :registry

        # @return [String] the domain's `bluebook/` directory
        attr_reader :bluebook_dir

        # @return [String] the name of the first bluebook loaded
        attr_reader :domain_name

        # @param domain [String] the domain's directory
        def initialize(domain)
          @domain = domain
          @bluebook_dir = File.join(domain, "bluebook")
        end

        # `root:` is the domain's own directory: a domain that declares `attaches ... from: :vendor`
        # resolves its vendored chapters beneath it.
        #
        # @return [DomainLoader] self, with the registry loaded
        def call
          @registry = Hecks::Runtime::Registry.new(root: File.expand_path(@domain))
          Hecks.with_registry(@registry) do
            load_framework
            Hecks::Adapters::Folder.new.load_bluebooks(@bluebook_dir)
            load_siblings
            load_environment
          end
          @domain_name = @registry.bluebooks.keys.first
          self
        end

        private

        def load_framework
          lib = File.expand_path("../..", __dir__)
          FRAMEWORK_FILES.each { |file| Kernel.load(File.join(lib, file)) }
        end

        # Translation edges, hecksagons (whose `attaches` loads a framework chapter into the
        # same registry) and worlds (whose `default_adapter` binds what a hecksagon leaves out), in
        # the order the language loads them.
        def load_siblings
          Dir[File.join(@bluebook_dir, "translations", "*.bluebook")].each { |file| Kernel.load(file) }
          Dir.glob(File.join(@bluebook_dir, "*.hecksagon")).each { |file| Kernel.load(file) }
          Dir.glob(File.join(@bluebook_dir, "*.world")).each { |file| Kernel.load(file) }
        end

        # Production is the default environment when `environments/production.hecksagon` exists
        # (`rust/host` is the production runtime); `HECKS_PROJECT_ENVIRONMENT` overrides it.
        def load_environment
          environment = ENV.fetch("HECKS_PROJECT_ENVIRONMENT") do
            File.exist?(File.join(@bluebook_dir, "environments", "production.hecksagon")) ? "production" : nil
          end
          return if environment.nil? || environment.empty?

          folder = Hecks::Adapters::Folder.new
          folder.load_each(@bluebook_dir, [File.join("environments", "#{environment}.hecksagon")])
          folder.load_each(@bluebook_dir, [File.join("environments", "#{environment}.world")])
        end
      end
    end
  end
end
