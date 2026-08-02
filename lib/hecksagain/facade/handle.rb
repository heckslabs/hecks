require_relative "../naming"

module Hecksagain
  module Facade
    # ONE record in hand — the object `Pizza.create_pizza(...)` and
    # `Pizza.find(id)` give back.
    #
    # ONE SHARED CLASS, not one minted per aggregate. The old door subclassed
    # `Hecksagain::Aggregate` per head and defined a reader per field ; this
    # wraps the same `Runtime::Instance` state hash and answers readers and
    # verbs through `method_missing`, closing over the dispatcher and the
    # aggregate's IR — so a boot mints no classes at all, and two runtimes in
    # one process each hand out handles bound to their own dispatcher.
    #
    # A non-creating verb is a method returning self, so commands chain :
    #
    #     Pizza.create_pizza(...).add_topping(...).purchase(...)
    class Handle
      attr_reader :id

      def initialize(dispatcher:, domain:, ir:, instance:)
        @dispatcher = dispatcher
        @domain     = domain
        @ir         = ir
        @id         = instance.id
        @state      = instance.state
      end

      def [](key) = @state[key.to_sym]
      def to_h    = { id: @id }.merge(@state)

      def fqn = "#{@domain}::#{@ir.hecks_name}"

      def events
        @dispatcher.events.select { |event| event.aggregate == fqn && event.id == @id }
      end

      def reload
        stored = repository.find(@id)
        @state = stored.state if stored
        self
      end

      # Equality is (WHICH AGGREGATE, WHICH ID) — two handles to the same record
      # are the same record, and a Pizza never equals an Account that happens to
      # share an id. The old door said this with `other.is_a?(self.class)`,
      # leaning on one class per aggregate ; the fqn says it in data.
      def ==(other) = other.is_a?(Handle) && other.fqn == fqn && other.id == @id
      alias eql? ==
      def hash = [Handle, fqn, @id].hash

      def inspect
        fields = @state.map { |key, value| "#{key}=#{value.inspect}" }.join(" ")
        "#<#{@ir.hecks_name} #{@id} #{fields}>"
      end
      alias to_s inspect

      # Readers first — a held field, or a declared field not yet written (nil,
      # the way a defined reader answered) — then the aggregate's own
      # non-creating verbs. Anything else is a genuine NoMethodError.
      def method_missing(name, *args, **kwargs, &block)
        return @state[name] if @state.key?(name) || reader?(name)

        verb = verb_named(name)
        return run(verb, **kwargs) if verb

        super
      end

      def respond_to_missing?(name, include_private = false)
        @state.key?(name) || reader?(name) || !verb_named(name).nil? || super
      end

      private

      def repository = @dispatcher.registry.repository(@domain, @ir)

      def reader?(name)
        !@ir.attribute(name).nil? || @ir.lifecycle&.field&.to_sym == name
      end

      def verb_named(name)
        @ir.commands.find do |command|
          !command.creates? && Naming.snake(command.hecks_name) == name.to_s
        end
      end

      def run(command, **args)
        identity = { @ir.identified_by => @id }
        @state = @dispatcher.dispatch("#{fqn}.#{command.hecks_name}", **identity, **args).instance.state
        self
      end
    end
  end
end
