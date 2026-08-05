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
    # aggregate's IR — so a boot mints no classes at all, and two boots in
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
        define_verb_methods
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

      # A declared field not yet written arrives here too (nil, the way a
      # defined reader answered). Verbs are NOT handled here — see
      # `define_verb_methods` for why.
      def method_missing(name, *args, **kwargs, &block)
        return @state[name] if @state.key?(name) || reader?(name)

        super
      end

      def respond_to_missing?(name, include_private = false)
        @state.key?(name) || reader?(name) || super
      end

      private

      def repository = @dispatcher.registry.repository(@domain, @ir)

      def reader?(name)
        !@ir.attribute(name).nil? || @ir.lifecycle&.field&.to_sym == name
      end

      # NON-CREATING VERBS ARE DEFINED, NOT DISPATCHED THROUGH method_missing.
      #
      # method_missing only runs once Ruby finds no REAL method already
      # answering the name — and every object already answers `freeze` and
      # `send` (Kernel/Object), among others. A verb whose snake-cased name
      # collides with one of those — `Account::Freeze` -> `freeze`,
      # `ExternalTransfer::Send` -> `send` in the banking corpus, both real —
      # silently ran the Kernel method instead of dispatching: no error, no
      # refusal, the call just did the wrong thing. AggregateDoor's creating
      # verbs never had this problem because it already defines a real
      # singleton method per verb; this closes the same gap here.
      def define_verb_methods
        @ir.commands.reject(&:creates?).each do |command|
          define_singleton_method(Naming.snake(command.hecks_name)) do |**args|
            run(command, **args)
          end
        end
      end

      # ONE HEAD ADDRESSES THE SAME WAY AS SEVERAL. `@ir.identified_by` is only
      # the single-head shorthand — nil the moment an identity is composite
      # (`SafeDepositBox`'s `branch_code`/`box_number`) — so building the
      # identity payload from `identity_heads` instead reads every head, one
      # or many alike, straight out of state that already carries them.
      def run(command, **args)
        identity = @ir.identity_heads.to_h { |head| [head, @state[head]] }
        @state = @dispatcher.dispatch("#{fqn}.#{command.hecks_name}", **identity, **args).instance.state
        self
      end
    end
  end
end
