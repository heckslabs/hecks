module Hecks

  # Hecks::BluebookToggles
  #
  # Toggle registry for the Bluebook/Chapter migration. Each module can
  # independently opt into Bluebook behavior. Any combination of toggles
  # keeps the system running. Once all are enabled, pre-Bluebook code is dead.
  #
  #   Hecks::BluebookToggles.enable(:dsl, :ir, :runtime)
  #   Hecks::BluebookToggles.enabled?(:dsl)       # => true
  #   Hecks::BluebookToggles.enabled?(:workshop)   # => false
  #   Hecks::BluebookToggles.all_enabled?           # => false
  #
  module BluebookToggles
    MODULES = {
      dsl:       true,
      ir:        true,
      runtime:   true,
      boot:      true,
      workshop:  true,
      configure: true,
      cli:       true,
      examples:  true,
    }

    @state = MODULES.dup

    def self.enable(*names)
      names.each do |n|
        raise ArgumentError, "Unknown toggle: #{n}" unless MODULES.key?(n)
        @state[n] = true
      end
    end

    def self.disable(*names)
      names.each do |n|
        raise ArgumentError, "Unknown toggle: #{n}" unless MODULES.key?(n)
        @state[n] = false
      end
    end

    def self.enabled?(name)
      @state.fetch(name) { raise ArgumentError, "Unknown toggle: #{name}" }
    end

    def self.all_enabled?
      @state.values.all?
    end

    def self.reset!
      @state = MODULES.dup
    end
  end
end
