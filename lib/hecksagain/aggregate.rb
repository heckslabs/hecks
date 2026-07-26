# Aggregate — the base every domain class inherits.
#
# `aggregate "Pizza"` in a bluebook CONSTRUCTS a real Ruby class as it reads,
# in the same pass that builds the IR. Both are products of reading the source;
# nothing ever reads the IR to make Ruby. So the domain is used as ordinary
# Ruby:
#
#   pizza = Pizza.create_pizza(name: "Margherita", price_cents: 1200)
#   pizza.add_topping(name: "Basil", amount: 3)
#   pizza.purchase(customer_name: "Chris")
#   pizza.status      # => "sold"
#   pizza.events.last # => PizzaPurchased(...)
#
# A creating command becomes a CLASS method and returns the new record. A
# command that references its own aggregate becomes an INSTANCE method —
# identity is already known, so it is never passed by hand — and returns self,
# which lets commands chain.
#
# `dispatch` is plumbing. It exists, the parity harness uses it, and no one
# writing a domain should ever type it.
module Hecksagain
  class Aggregate
    class << self
      # The IR this class was built alongside, its domain, and the runtime that
      # boot bound to it.
      attr_accessor :ir, :domain, :runtime

      def fqn        = "#{domain}::#{ir.name}"
      def repository = runtime.registry.repository(domain, ir)
      def commands   = ir.commands.map { |command| Naming.snake(command.name) }.sort

      def find(id)
        found = repository.find(id)
        found && wrap(found)
      end

      def all   = repository.all.map { |instance| wrap(instance) }
      def count = repository.count

      # Every event this aggregate type has announced this session.
      def events = runtime.events.select { |event| event.aggregate == fqn }

      def wrap(instance) = new(id: instance.id, state: instance.state)

      # Plumbing — the generated methods call this, nobody else should.
      def run(command_name, **args)
        runtime.dispatch("#{fqn}.#{command_name}", **args)
      end

      # THE HEXAGON WIRES THE REAL CLASS.
      #
      #   Pizzas::Pizza.persisted_by("Sqlite")
      #
      # An aggregate IS the port, so a bind is a genuine method call on the
      # genuine class rather than a stand-in for one. Any how-verb is accepted
      # here because the vocabulary belongs to the FAMILIES, not to this class
      # — declaring a new family must never require editing this file. Which
      # verbs are real is checked at boot, against the adapter's declared
      # family.
      #
      # Outside a hecksagon this stays an ordinary NoMethodError, so a typo in
      # domain code still fails the way Ruby should.
      def method_missing(verb, *args, &block)
        collector = Language::DSL::HecksagonBuilder.collector
        return super unless collector

        collector << Language::IR::Bind.new(aggregate: fqn, verb: verb.to_s, adapter: args.first.to_s)
        block&.call
        self
      end

      def respond_to_missing?(name, include_private = false)
        !Language::DSL::HecksagonBuilder.collector.nil? || super
      end
    end

    attr_reader :id, :state

    def initialize(id:, state:)
      @id    = id
      @state = state
    end

    def [](key) = @state[key.to_sym]
    def to_h    = { id: @id }.merge(@state)

    def events = self.class.events.select { |event| event.id == @id }

    def reload
      stored = self.class.repository.find(@id)
      @state = stored.state if stored
      self
    end

    def ==(other) = other.is_a?(self.class) && other.id == @id
    alias eql? ==
    def hash = [self.class, @id].hash

    def inspect
      fields = @state.map { |key, value| "#{key}=#{value.inspect}" }.join(" ")
      "#<#{self.class.ir.name} #{@id} #{fields}>"
    end
    alias to_s inspect

    private

    # Plumbing. A command method calls this ; a domain author never does.
    def run(command_name, **args)
      identity = { self.class.ir.identified_by => @id }
      @state   = self.class.run(command_name, **identity, **args).instance.state
      self
    end
  end

  # Claiming a constant without ever clobbering someone else's.
  #
  # Booting the same domain twice must re-point its constants at the NEW
  # classes — a stale Pizza still writing to the previous session's database is
  # the kind of bug that wastes an afternoon.
  module Namespace
    GENERATED = {}

    module_function

    def install(container, name, value)
      name = name.to_s

      if container.const_defined?(name, false)
        current = container.const_get(name)
        unless GENERATED[[container, name]].equal?(current)
          warn "[hecksagain] #{name} is already defined — leaving it alone"
          return current
        end
        container.send(:remove_const, name)
      end

      container.const_set(name, value)
      GENERATED[[container, name]] = value
      value
    end
  end
end
