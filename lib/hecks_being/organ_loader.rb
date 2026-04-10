# HecksBeing::OrganLoader
#
# Loads a domain from the nursery or a being's local directory,
# boots it as a live Runtime with a shared event bus. Persistence
# is wired through the hecksagon — not hardcoded here.
#
#   loader = OrganLoader.new(shared_bus, nursery_dir)
#   runtime = loader.load("ImmuneSystem", "nursery/immune_system")
#
module HecksBeing
  class OrganLoader
    include HecksTemplating::NamingHelpers

    # @param shared_bus [Hecks::EventBus] the organism's shared event bus
    # @param nursery_dir [String] path to the nursery
    def initialize(shared_bus, nursery_dir)
      @shared_bus = shared_bus
      @nursery_dir = nursery_dir
    end

    # Load a domain and boot it as a live Runtime.
    #
    # @param domain_name [String] e.g. "ImmuneSystem"
    # @param source_path [String] relative path from nursery or absolute
    # @return [Hecks::Runtime] a live, wired runtime
    def load(domain_name, source_path)
      bluebook_path = resolve_path(domain_name, source_path)
      raise "Bluebook not found: #{bluebook_path}" unless File.exist?(bluebook_path)

      domain = load_domain_ir(bluebook_path)
      validate!(domain)
      boot_runtime(domain)
    end

    private

    def resolve_path(domain_name, source_path)
      if File.exist?(source_path)
        source_path
      else
        slug = bluebook_snake_name(domain_name)
        File.join(@nursery_dir, slug, "#{slug}.bluebook")
      end
    end

    def load_domain_ir(path)
      Hecks::DSL::AggregateBuilder::VoTypeResolution.with_vo_constants do
        Kernel.load(path)
      end
      Hecks.last_domain
    end

    def validate!(domain)
      valid, errors = Hecks.validate(domain)
      return if valid
      raise "Invalid domain #{domain.name}: #{errors.join(', ')}"
    end

    def boot_runtime(domain)
      require "hecks_multidomain"
      bus = Hecks::FilteredEventBus.new(
        inner: @shared_bus,
        bluebook_gem_name: domain.gem_name,
        allowed_sources: nil
      )
      Hecks.load_bluebook(domain)
      Hecks::Runtime.new(domain, event_bus: bus)
    end
  end
end
