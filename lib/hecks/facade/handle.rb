require_relative "../naming"

module Hecks
  module Facade
    # One record in hand — the object `Pizza.create_pizza!(...)` and
    # `Pizza.find(id)` give back.
    #
    # One shared class, not one minted per aggregate. Rather than subclassing
    # per head and defining a reader per field, this wraps a
    # `Runtime::Instance` state hash, answers readers through
    # `method_missing` and verbs through per-handle singleton methods, and
    # closes over the dispatcher and the aggregate's IR — so a boot mints no
    # classes at all, and two boots in one process each hand out handles bound
    # to their own dispatcher.
    #
    # A non-creating verb is a method returning self, so commands chain :
    #
    #     Pizza.create_pizza!(...).add_topping!(...).purchase!(...)
    class Handle
      attr_reader :id

      # @param dispatcher [Runtime::Dispatcher, Runtime::RemoteDispatcher] the booted
      #   dispatcher this record's verbs, `events` and `reload` go through
      # @param domain [String] the owning chapter's name, the first half of `fqn`
      # @param aggregate [Bluebook::Aggregate] the IR of the aggregate this record is one of
      # @param instance [Runtime::Instance] the stored record; its `id` and `state` are
      #   read once here and the instance itself is not retained
      def initialize(dispatcher:, domain:, aggregate:, instance:)
        @dispatcher = dispatcher
        @domain     = domain
        @ir         = aggregate
        @id         = instance.id
        @state      = instance.state
        define_reference_accessors
        define_verb_methods
      end

      # Reads one field's raw stored value, without hydrating a reference the way the
      # reference accessor of the same name does.
      #
      # @param key [Symbol, String] the attribute name
      # @return [Object, nil] the value held in state (a scalar, a value object, a list,
      #   or a referenced record's id); `nil` when the field is unset or not in state
      def [](key) = @state[key.to_sym]

      # Answers the record's state as a plain Hash with the bare identity under `:id`.
      #
      # `id: @id` last, not first — an aggregate is free to declare its own
      # attribute literally named `id` (BurningManPrep's `Item`, `attribute
      # :id, ItemId`, is real corpus now: `identified_by :id` reads
      # that attribute for identity). When it does, `@state[:id]` holds the
      # full wrapped value object, not the bare identity string — merging
      # `@state` on top of `{ id: @id }` would let that wrapped VO silently
      # clobber the correct bare `@id`, so every caller of `to_h` (the JSON
      # door's own `/api/:coll` listing, in particular) would get an object
      # where a plain identity string belongs. `@id` merged last always wins,
      # so `to_h[:id]` is always the true bare identity, regardless of
      # whether the aggregate also happens to declare a same-named field.
      #
      # @return [Hash{Symbol => Object}] a new Hash of every state field by attribute
      #   name, plus `:id` holding the identity String
      def to_h = @state.merge(id: @id)

      # Names the aggregate this record belongs to, in the form every dispatch verb and
      # event is addressed by.
      #
      # @return [String] the fully qualified aggregate name, such as `"Pizzas::Pizza"`
      def fqn = "#{@domain}::#{@ir.hecks_name}"

      # Lists the events this one record has emitted, filtered out of the dispatcher's
      # whole event log on each call.
      #
      # @return [Array<Runtime::Event>] this record's events in the order the log holds
      #   them; `[]` when it has emitted none
      def events
        @dispatcher.events.select { |event| event.aggregate == fqn && event.id == @id }
      end

      # Refreshes this handle's state from the repository, picking up writes made through
      # another handle or door. Keeps the current state when the record is not found.
      #
      # @return [Facade::Handle] this handle, so the call chains
      # @raise [Runtime::WiringError] if the aggregate's persistence bind cannot be
      #   resolved into a repository
      def reload
        stored = repository.find(@id)
        @state = stored.state if stored
        self
      end

      # Equality is (which aggregate, which ID) — two handles to the same record
      # are the same record, and a Pizza never equals an Account that happens to
      # share an id. With one shared class for every aggregate,
      # `other.is_a?(self.class)` cannot tell them apart ; the fqn says it in data.
      #
      # @param other [Object] anything; only another `Handle` can be equal
      # @return [Boolean] true when `other` is a `Handle` with the same `fqn` and `id`,
      #   whatever state either one holds
      def ==(other) = other.is_a?(Handle) && other.fqn == fqn && other.id == @id
      alias eql? ==
      def hash = [Handle, fqn, @id].hash

      def inspect
        fields = @state.map { |key, value| "#{key}=#{value.inspect}" }.join(" ")
        "#<#{@ir.hecks_name} #{@id} #{fields}>"
      end
      alias to_s inspect

      # Answers a field reader: `pizza.name` reads `name` out of state.
      #
      # A declared field not yet written arrives here too (nil, the way a
      # defined reader answers). Verbs are not handled here — see
      # `define_verb_methods` for why.
      #
      # @param name [Symbol] the method called, read as an attribute or lifecycle field name
      # @param args [Array<Object>] ignored by a reader; passed on to `super` otherwise
      # @param kwargs [Hash{Symbol => Object}] ignored by a reader; passed on to `super`
      #   otherwise
      # @return [Object, nil] the field's value; `nil` for a declared field with nothing
      #   written yet
      # @raise [NoMethodError] if `name` is neither a key in state nor a declared field
      def method_missing(name, *args, **kwargs, &)
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

      # Non-creating verbs are defined, not dispatched through method_missing.
      #
      # method_missing only runs once Ruby finds no real method already
      # answering the name — and every object already answers `freeze` and
      # `send` (Kernel/Object), among others. A verb whose snake-cased name
      # collided with one of those — `Account::Freeze` -> `freeze`,
      # `ExternalTransfer::Send` -> `send` in the banking corpus, both real —
      # would silently run the Kernel method instead of dispatching: no
      # error, no refusal, the call just does the wrong thing. Defining a
      # real singleton method per verb closes that; the `!` suffix (every
      # command, door and Handle alike) closes it a second, permanent way —
      # `freeze!`/`send!` name nothing Kernel/Object already answers to,
      # so this exact class of collision cannot recur no matter what a
      # future domain names a command.
      def define_verb_methods
        @ir.commands.reject(&:creates?).each do |command|
          define_singleton_method("#{Naming.snake(command.hecks_name)}!") do |**args|
            run(command, **args)
          end
        end
      end

      # One head addresses the same way as several. `@ir.identified_by` is only
      # the single-head shorthand — nil the moment an identity is composite
      # (`SafeDepositBox`'s `branch_code`/`box_number`) — so building the
      # identity payload from `identity_heads` instead reads every head, one
      # or many alike, straight out of state that already carries them.
      def run(command, **args)
        @state = @dispatcher.dispatch("#{fqn}.#{command.hecks_name}", to: @id, with: args).instance.state
        self
      end

      # **The other half of a cross-reference**. `transfer.source` already reads
      # the raw value — a plain reader, same as any other attribute, still
      # needed by a `given`. This is the hydrated hop docs/rails-integration.md
      # designed and marked "nothing built": `transfer.source_account`
      # resolves it to the actual Account record, on demand — nothing loads
      # until called, and this hop never triggers the next one. Plain
      # chaining composes for free from here : `payment.disputed_by_customer.name`
      # is two ordinary calls, each individually lazy, which is exactly why
      # this is a named accessor per reference rather than a `through:`
      # option — that shape was considered and rejected in the same design
      # note for hiding how many lookups actually happened behind one call.
      #
      # Defined before verb methods, not after — on the vanishing chance a
      # reference's own accessor name collided with a command's, the verb
      # should win; `initialize` calls this first so `define_verb_methods`
      # defines second and last.
      # No derivation left (ADR 0025, "References"): `reference_to`
      # itself mints the bare attribute name now — `:account`, never
      # `:account_id` — so the accessor is spelled exactly like the
      # attribute it reads, with no `_id`-strip or `as:`-suffix rule to
      # apply first. `piece.account` (a method, defined here) and
      # `piece[:account]` (`Handle#[]`, bracket access reading the raw
      # id straight off `@instance`) never collide despite sharing a
      # name — Ruby dispatches the two completely differently — so no
      # renamed accessor (a "studio_studio"-style double suffix) is needed
      # to keep them apart.
      def define_reference_accessors
        @ir.attributes.select(&:reference?).each do |attribute|
          target = attribute.type.resolve
          # Cross-domain, or otherwise unresolvable — no accessor rather than a guess.
          next unless target

          domain     = @domain
          field      = attribute.name
          list       = attribute.list?
          target_fqn = "#{domain}::#{target.hecks_name}"

          define_singleton_method(field) do
            value = self[field]
            door = Object.const_get(target_fqn)
            next Array(value).map { |identity| door.find(identity) } if list

            value && door.find(value)
          end
        end
      end
    end
  end
end
