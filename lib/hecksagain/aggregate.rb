module Hecksagain
  class Aggregate
    class << self
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

      def events = runtime.events.select { |event| event.aggregate == fqn }

      def wrap(instance) = new(id: instance.id, state: instance.state)

      def run(command_name, **args)
        runtime.dispatch("#{fqn}.#{command_name}", **args)
      end

      def method_missing(verb, *args, &block)
        collector = Bluebook::DSL::HecksagonBuilder.collector
        return super unless collector

        collector << Bluebook::IR::Bind.new(aggregate: fqn, verb: verb.to_s, adapter: args.first.to_s)
        block&.call
        self
      end

      def respond_to_missing?(name, include_private = false)
        !Bluebook::DSL::HecksagonBuilder.collector.nil? || super
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

    def run(command_name, **args)
      identity = { self.class.ir.identified_by => @id }
      @state   = self.class.run(command_name, **identity, **args).instance.state
      self
    end
  end

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
