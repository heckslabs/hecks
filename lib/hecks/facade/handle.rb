require_relative "../naming"
require_relative "../runtime/caller"
require_relative "../ports/authorization"

module Hecks
  module Facade
    # A record in hand: what `Pizza.create_pizza!(...)` and `Pizza.find(id)`
    # give back. One shared class per aggregate; verbs are per-handle singleton methods.
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
      def [](key) = redacted(key.to_sym)

      # Answers the record's state as a Hash, with `:id` merged in last so it
      # always wins over a same-named `id` attribute (BurningManPrep::Item).
      #
      # @return [Hash{Symbol => Object}] every state field by attribute name, plus `:id`
      def to_h = @state.to_h { |key, _| [key, redacted(key)] }.merge(id: @id)

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

      # Equality is (fqn, id): two handles to the same record are equal, and
      # `other.is_a?(self.class)` can't tell aggregates apart since they share one class.
      #
      # @param other [Object] anything; only another `Handle` can be equal
      # @return [Boolean] true when `other` is a `Handle` with the same `fqn` and `id`
      def ==(other) = other.is_a?(Handle) && other.fqn == fqn && other.id == @id
      alias eql? ==
      def hash = [Handle, fqn, @id].hash

      def inspect
        fields = @state.map { |key, value| "#{key}=#{value.inspect}" }.join(" ")
        "#<#{@ir.hecks_name} #{@id} #{fields}>"
      end
      alias to_s inspect

      # Answers a field reader: `pizza.name` reads `name` out of state. A
      # declared field not yet written arrives here too, as `nil`.
      #
      # @param name [Symbol] the method called, read as an attribute or lifecycle field name
      # @param args [Array<Object>] ignored by a reader; passed on to `super` otherwise
      # @param kwargs [Hash{Symbol => Object}] ignored by a reader; passed on to `super` otherwise
      # @return [Object, nil] the field's value; `nil` when nothing is written yet
      # @raise [NoMethodError] if `name` is neither a key in state nor a declared field
      def method_missing(name, *args, **kwargs, &)
        return redacted(name) if @state.key?(name) || reader?(name)

        super
      end

      def respond_to_missing?(name, include_private = false)
        @state.key?(name) || reader?(name) || super
      end

      private

      def repository = @dispatcher.registry.repository(@domain, @ir)

      # Masks any Privacy::Marking leaf the caller isn't granted to read, and
      # masks an unidentified caller outright (a leak is worse than a refusal
      # commands allow). Nesting is masked one level deep only.
      def redacted(field)
        raw = @state[field]
        rows = marked_paths.select { |row| row[:attribute_path][:value].to_s.split(".", 2).first == field.to_s }
        return raw if rows.empty?

        rows.each do |row|
          path = row[:attribute_path][:value].to_s
          next if authorized_for?(row[:readable_by][:value].to_s)

          segments = path.split(".", 2)
          if segments.size == 1
            raw = "[redacted]"
          elsif raw.is_a?(Runtime::Value)
            raw = raw.with(segments[1], "[redacted]")
          end
        end

        raw
      end

      # Cached per handle so an unattached-Privacy domain never pays for a query
      # dispatch on every read.
      def marked_paths
        return @marked_paths if defined?(@marked_paths)
        return @marked_paths = [] unless @dispatcher.registry.bluebook("Privacy")

        @marked_paths = @dispatcher.query("Privacy::Marking.ForDomain", domain: fqn)
      end

      # False outright for an unidentified caller or an unattached domain, never
      # the weak fallback a command's own role check allows.
      def authorized_for?(role)
        caller = Runtime::Caller.current
        return false unless caller&.actor_id
        return false unless @dispatcher.registry.authorization_provider_for(@domain)

        Ports::Authorization.holds_role?(@dispatcher.registry, actor_id: caller.actor_id, role: role,
                                                                 as_of: caller.as_of, scope: caller.scope)
      end

      def reader?(name)
        !@ir.attribute(name).nil? || @ir.lifecycle&.field&.to_sym == name
      end

      # Real singleton methods, not method_missing: a verb named `freeze` or
      # `send` (both real, e.g. Account::Freeze, ExternalTransfer::Send) would
      # otherwise silently hit the Kernel method instead of dispatching.
      def define_verb_methods
        @ir.commands.reject(&:creates?).each do |command|
          define_singleton_method("#{Naming.snake(command.hecks_name)}!") do |**args|
            run(command, **args)
          end
        end
      end

      # `@ir.identified_by` is only the single-head shorthand (nil for a
      # composite identity, e.g. SafeDepositBox's branch_code/box_number);
      # this reads every head through `identity_heads` instead.
      def run(command, **args)
        @state = @dispatcher.dispatch("#{fqn}.#{command.hecks_name}", to: @id, with: args).instance.state
        self
      end

      # Lazy hop: `transfer.source_account` resolves to the actual record only
      # when called; nothing loads until then, so chains like
      # `payment.disputed_by_customer.name` stay lazy at every step.
      #
      # Defined before verb methods so a same-named verb wins the name on the
      # rare collision; `initialize` calls this first for that reason.
      #
      # The accessor is named like the attribute itself, never `<name>_id`
      # (ADR 0025) — `piece.account` and `piece[:account]` (bracket access,
      # the raw id) never collide despite sharing a name.
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
