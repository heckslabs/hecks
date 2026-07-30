module Hecksagain
  class Aggregate
    extend Construct

    class << self
      attr_accessor :ir, :domain, :runtime

      # An aggregate is a MEMBER of its chapter's namespace, so it joins with
      # `::` where every other construct is declared ON its owner and joins with
      # `.`.
      def hecks_separator = "::"

      # `fqn` computed "#{domain}::#{ir.name}" — the same string by a second route,
      # which is exactly the duplicate identity the invisible field exists to
      # prevent. It also answered "::Pizza" for an aggregate with no chapter, where
      # `hecks_fqn` refuses. One spelling, and this name survives only because the
      # runtime addresses aggregates by it.
      def fqn = hecks_fqn
      def repository = runtime.registry.repository(domain, ir)
      def commands   = ir.commands.map { |command| Naming.snake(command.hecks_name) }.sort

      # A CLASS DEFINES ITS OWN SURFACE.
      #
      # These two lived in `AggregateBuilder` as `define_readers` and
      # `define_command`, reaching into `@klass` from outside. They belong here,
      # because the DSL is about to stop being the only thing that builds an
      # aggregate: once the language hands the graph back, the assembler needs the
      # same two calls, and neither of them should have to be a builder to make
      # them.
      #
      # `RESERVED` names would shadow the machinery the instance runs on, so a
      # field with one of those names gets no reader and says so.
      RESERVED = %i[id state events reload inspect to_h hash class].freeze

      def declare_reader(field)
        if RESERVED.include?(field.to_sym)
          warn "[hecksagain] #{hecks_name}##{field} shadows a built-in — no reader defined"
          return
        end

        field = field.to_sym
        define_method(field) { @state[field] }
      end

      # A creating verb is a CLASS method returning the new record ; one that
      # reaches an existing root is an instance method returning self, so verbs
      # chain. Only the verb string is closed over — `run` resolves the runtime at
      # call time.
      def declare_verb(verb, creates:)
        method_name = Naming.snake(verb)

        if creates
          define_singleton_method(method_name) { |**args| wrap(run(verb, **args).instance) }
        else
          define_method(method_name) { |**args| run(verb, **args) }
        end
      end

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

      def method_missing(verb, *args, **kwargs, &block)
        collector = Bluebook::DSL::HecksagonBuilder.collector
        return super unless collector

        collector << Bluebook::IR::Bind.new(
          aggregate: fqn,
          verb:      verb.to_s,
          adapter:   args.first.to_s,
          role:      kwargs[:role]&.to_s
        )
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
