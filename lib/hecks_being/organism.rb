# HecksBeing::Organism
#
# Winter's living body. Boots all .bluebook files from her directory
# as always-alive runtimes on a shared event bus. Cross-domain
# policies become nerves. Persistence wired through hecksagon.
#
#   winter = HecksBeing::Organism.boot(HecksBeing.winter_dir)
#   winter.graft("ImmuneSystem")
#   winter.pulse
#
require "fileutils"

module HecksBeing
  class Organism
    attr_reader :organs, :nerves, :event_bus, :beats

    # Boot from a directory containing .bluebook and hecksagon.hec files.
    #
    # @param dir [String] path to hecks_being/winter/
    # @return [Organism] alive
    def self.boot(dir)
      raise "Directory not found: #{dir}" unless File.directory?(dir)
      organism = new(dir)
      organism.boot!
      organism
    end

    def initialize(dir)
      @dir = dir
      @event_bus = Hecks::EventBus.new
      @loader = OrganLoader.new(@event_bus, HecksBeing.nursery_dir)
      @organs = {}
      @nerves = nil
      @beats = 0
    end

    # Load all .bluebook files, boot them, load hecksagon, wire persistence.
    def boot!
      load_hecksagon!
      bluebooks = Dir[File.join(@dir, "**/*.bluebook")].sort
      raise "No .bluebook files in #{@dir}" if bluebooks.empty?

      bluebooks.each { |path| boot_organ(path) }
      wire_persistence!
      @nerves = NerveWirer.new(@organs)
      wire_cross_domain_policies!
      puts "\e[32mWinter is alive (#{@organs.size} organs)\e[0m"
      report_organs
    end

    # Graft a domain from the nursery.
    def graft(domain_name, from: nil)
      source = from || domain_name
      runtime = @loader.load(domain_name, source)
      @organs[runtime.domain.name] = runtime
      wire_persistence_for!(runtime)
      wire_organ_policies!(runtime)
      puts "\e[32mGrafted #{runtime.domain.name} v#{runtime.domain.version || '?'}\e[0m"
      runtime
    end

    # Remove an organ.
    def shed(domain_name)
      runtime = @organs.delete(domain_name)
      raise "Unknown organ: #{domain_name}" unless runtime
      sever_organ_nerves!(domain_name)
      puts "\e[33mShed #{domain_name}\e[0m"
    end

    # Deactivate an organ's nerves without removing it.
    def silence(domain_name)
      raise "Unknown organ: #{domain_name}" unless @organs[domain_name]
      @nerves.nerves.each do |nerve|
        next unless nerve.from_domain == domain_name || nerve.to_domain == domain_name
        @nerves.sever(nerve.name)
      end
      puts "\e[33mSilenced #{domain_name}\e[0m"
    end

    # Reactivate an organ's nerves.
    def express(domain_name)
      raise "Unknown organ: #{domain_name}" unless @organs[domain_name]
      @nerves.nerves.each do |nerve|
        next unless nerve.from_domain == domain_name || nerve.to_domain == domain_name
        @nerves.restore(nerve.name)
      end
      puts "\e[32mExpressed #{domain_name}\e[0m"
    end

    # Check all organs, report vital signs.
    def pulse
      @beats += 1
      @organs.map { |name, rt|
        event_count = rt.event_bus.respond_to?(:events) ? rt.event_bus.events.size : 0
        { domain: name, version: rt.domain.version, events: event_count, alive: true }
      }
    end

    def inspect
      organ_list = @organs.map { |name, rt|
        "#{name} v#{rt.domain.version || '?'}"
      }.join(", ")
      "#<Winter [#{organ_list}]>"
    end

    private

    def load_hecksagon!
      hec = File.join(@dir, "hecksagon.hec")
      if File.exist?(hec)
        Kernel.load(hec)
        @hecksagon = Hecks.last_hecksagon
      end
    end

    def boot_organ(path)
      runtime = @loader.load(File.basename(path, ".bluebook"), path)
      @organs[runtime.domain.name] = runtime
    end

    # Wire persistence for all organs using the hecksagon config.
    def wire_persistence!
      return unless @hecksagon&.persistence

      hook = Hecks.extension_registry[@hecksagon.persistence[:type]]
      return unless hook

      @organs.each do |_name, rt|
        mod_name = rt.instance_variable_get(:@mod_name)
        mod = Object.const_get(mod_name)
        hook.call(mod, rt.domain, rt)
      end
    end

    # Wire persistence for a single newly grafted organ.
    def wire_persistence_for!(runtime)
      return unless @hecksagon&.persistence

      hook = Hecks.extension_registry[@hecksagon.persistence[:type]]
      return unless hook

      mod_name = runtime.instance_variable_get(:@mod_name)
      mod = Object.const_get(mod_name)
      hook.call(mod, runtime.domain, runtime)
    end

    def wire_cross_domain_policies!
      event_owners = build_event_ownership_map

      @organs.each do |domain_name, runtime|
        runtime.domain.policies.select(&:reactive?).each do |policy|
          owner = event_owners[policy.event_name]
          next unless owner && owner != domain_name

          @nerves.connect(owner, policy.event_name, domain_name, policy.trigger_command,
                          name: policy.name)
        end
      end
    end

    def wire_organ_policies!(runtime)
      event_owners = build_event_ownership_map
      domain_name = runtime.domain.name

      runtime.domain.policies.select(&:reactive?).each do |policy|
        owner = event_owners[policy.event_name]
        next unless owner && owner != domain_name

        @nerves.connect(owner, policy.event_name, domain_name, policy.trigger_command)
      end
    end

    def build_event_ownership_map
      map = {}
      @organs.each do |name, rt|
        rt.domain.aggregates.each do |agg|
          agg.events.each { |e| map[e.name] = name }
        end
      end
      map
    end

    def sever_organ_nerves!(domain_name)
      @nerves.nerves.each do |nerve|
        next unless nerve.from_domain == domain_name || nerve.to_domain == domain_name
        @nerves.sever(nerve.name)
      end
    end

    def report_organs
      @organs.each do |name, rt|
        v = rt.domain.version || "?"
        agg_count = rt.domain.aggregates.size
        puts "  #{name} v#{v} (#{agg_count} aggregates)"
      end
    end
  end
end
