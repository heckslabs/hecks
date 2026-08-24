require_relative "../naming"

module Hecks
  module Facade
    # ONE record in hand — the object `Pizza.create_pizza(...)` and
    # `Pizza.find(id)` give back.
    #
    # ONE SHARED CLASS, not one minted per aggregate. The old door subclassed
    # `Hecks::Aggregate` per head and defined a reader per field ; this
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
        define_reference_accessors
        define_verb_methods
      end

      def [](key) = @state[key.to_sym]

      # `id: @id` LAST, not first — an aggregate is free to declare its own
      # attribute literally named `id` (BurningManPrep's `Item`, `attribute
      # :id, ItemId`, is real corpus now: `identified_by :id` reads
      # THAT attribute for identity). When it does, `@state[:id]` holds the
      # full wrapped value object, not the bare identity string — merging
      # `@state` on top of `{ id: @id }` let that wrapped VO silently
      # clobber the correct bare `@id`, so every caller of `to_h` (the JSON
      # door's own `/api/:coll` listing, in particular) got an object where
      # a plain identity string belonged. `@id` merged LAST always wins,
      # so `to_h[:id]` is always the true bare identity, regardless of
      # whether the aggregate also happens to declare a same-named field.
      def to_h = @state.merge(id: @id)

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
      # collided with one of those — `Account::Freeze` -> `freeze`,
      # `ExternalTransfer::Send` -> `send` in the banking corpus, both real —
      # used to silently run the Kernel method instead of dispatching: no
      # error, no refusal, the call just did the wrong thing. Defining a
      # real singleton method per verb closed that; the `!` suffix (every
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

      # ONE HEAD ADDRESSES THE SAME WAY AS SEVERAL. `@ir.identified_by` is only
      # the single-head shorthand — nil the moment an identity is composite
      # (`SafeDepositBox`'s `branch_code`/`box_number`) — so building the
      # identity payload from `identity_heads` instead reads every head, one
      # or many alike, straight out of state that already carries them.
      def run(command, **args)
        @state = @dispatcher.dispatch("#{fqn}.#{command.hecks_name}", to: @id, with: args).instance.state
        self
      end

      # THE OTHER HALF OF A CROSS-REFERENCE. `transfer.source` already reads
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
      # Defined BEFORE verb methods, not after — on the vanishing chance a
      # reference's own accessor name collided with a command's, the verb
      # should win; `initialize` calls this first so `define_verb_methods`
      # defines second and last.
      # NO DERIVATION LEFT (ADR 0025, "References"): `reference_to`
      # itself mints the bare attribute name now — `:account`, never
      # `:account_id` — so the accessor is spelled exactly like the
      # attribute it reads, with no `_id`-strip or `as:`-suffix rule to
      # apply first. `piece.account` (a METHOD, defined here) and
      # `piece[:account]` (`Handle#[]`, bracket access reading the raw
      # id straight off `@instance`) never collide despite sharing a
      # name — Ruby dispatches the two completely differently — which is
      # what makes the OLD "studio_studio" double-suffix workaround
      # (this method used to force a DIFFERENT name specifically to dodge
      # that non-collision) unnecessary rather than merely simplified.
      def define_reference_accessors
        @ir.attributes.select(&:reference?).each do |attribute|
          target = attribute.type.resolve
          next unless target # cross-domain, or otherwise unresolvable — no accessor rather than a guess

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
