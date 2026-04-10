# HecksBeing::NerveWirer
#
# Connects organs by subscribing to events on one organ's bus
# and dispatching commands on another. Each nerve is a live
# subscription that can be severed and restored.
#
#   wirer = NerveWirer.new(organs)
#   wirer.connect("Digest", "DomainAbsorbed", "WinterBody", "Conceive")
#   wirer.sever("Digest", "DomainAbsorbed")
#
module HecksBeing
  class NerveWirer
    Nerve = Struct.new(:name, :from_domain, :from_event,
                       :to_domain, :to_command, :active,
                       keyword_init: true)

    def initialize(organs)
      @organs = organs
      @nerves = []
    end

    # Wire an event on one organ to a command on another.
    #
    # @param from_domain [String] source organ name
    # @param from_event [String] event name to listen for
    # @param to_domain [String] target organ name
    # @param to_command [String] command to dispatch
    # @param name [String, nil] optional nerve name
    # @return [Nerve] the created nerve
    def connect(from_domain, from_event, to_domain, to_command, name: nil)
      source = @organs[from_domain]
      target = @organs[to_domain]
      raise "Unknown organ: #{from_domain}" unless source
      raise "Unknown organ: #{to_domain}" unless target

      nerve = Nerve.new(
        name: name || "#{from_domain}.#{from_event}->#{to_domain}.#{to_command}",
        from_domain: from_domain,
        from_event: from_event,
        to_domain: to_domain,
        to_command: to_command,
        active: true
      )

      source.event_bus.subscribe(from_event) do |event|
        next unless nerve.active
        target.command_bus.dispatch(to_command, event_to_attrs(event))
      end

      @nerves << nerve
      nerve
    end

    # Sever a nerve — stop delivering events without removing it.
    #
    # @param name [String] nerve name
    def sever(name)
      nerve = find(name)
      nerve.active = false if nerve
    end

    # Restore a severed nerve.
    #
    # @param name [String] nerve name
    def restore(name)
      nerve = find(name)
      nerve.active = true if nerve
    end

    # @return [Array<Nerve>] all nerves
    def nerves = @nerves.dup

    # @return [Array<Nerve>] only active nerves
    def active = @nerves.select(&:active)

    private

    def find(name)
      @nerves.find { |n| n.name == name }
    end

    def event_to_attrs(event)
      if event.respond_to?(:to_h)
        event.to_h
      elsif event.respond_to?(:attributes)
        event.attributes
      else
        {}
      end
    end
  end
end
