module Hecks
  module Bluebook
    module DSL
      # What a bare `Domain::Aggregate` constant resolves to inside a
      # `.hecksagon`/`.world` block (minted by `.namespace`'s own
      # `const_missing`) — `method_missing` turns a bind like
      # `Payment.persisted_by "Postgres"` into a queued `Bind`, and `#port`
      # is the one real method, for `Aggregate.port("Name") do ... end`.
      class BindingProxy
        # Mints the stand-in module a bare domain constant resolves to inside a `.hecksagon` block.
        #
        # @param domain [Symbol, String] the domain name, the first segment of `Domain::Aggregate`
        # @param collector [Array<Bluebook::Bind>] the list every bind made through the module's
        #   proxies is appended to
        # @return [Module] an anonymous module whose `const_missing` answers a `BindingProxy`
        #   for `"Domain::Aggregate"`
        def self.namespace(domain, collector)
          Module.new do
            define_singleton_method(:const_missing) do |aggregate|
              BindingProxy.new("#{domain}::#{aggregate}", collector)
            end
          end
        end

        # @param fqn [String] the aggregate's qualified name, `"Domain::Aggregate"`
        # @param collector [Array<Bluebook::Bind>] the list each bind made on this proxy is
        #   appended to
        def initialize(fqn, collector)
          @fqn       = fqn
          @collector = collector
        end

        # Declares a port on this aggregate and attaches it to the already-registered bluebook.
        #
        # **The aggregate-scoped port** — `Payments::Payment.port("Gateway") do
        # ... end`, the same receiver a plain bind like `.persisted_by(...)`
        # already reaches, because a port belongs to exactly one aggregate
        # the same way a bind does. A real method, not method_missing : its
        # shape (a name and a block building operations) has nothing to do
        # with `Bind`, so it does not belong in that generic verb path.
        #
        # @param name [String] the port's name, such as `"Gateway"`
        # @yield the port body, evaluated against a `DomainPortBuilder`: either `verb`/`signal`
        #   or `operation`/`tells`/`asks` blocks
        # @return [Bluebook::DSL::BindingProxy] this proxy, so further binds can chain
        # @raise [Bluebook::DSL::Malformed] if the current registry holds no such aggregate, or
        #   the body declares both a verb and operations, neither, or an operation the port
        #   grammar refuses
        def port(name, &block)
          domain, aggregate_name = @fqn.split("::")
          aggregate_ir = Hecks.current_registry.bluebook(domain)&.aggregate(aggregate_name) or
            raise Malformed, "#{@fqn} declares no such aggregate — a port needs one to belong to"

          # See HecksagonBuilder#port's own comment on why this resolver
          # swap is needed : ConstShim's active resolver is one global for
          # the whole dynamic extent, and it is currently this file's own
          # BindingProxy-minting one, which would turn a bare `Pizza` inside
          # `reference_to Pizza` into another BindingProxy instead of a name.
          built = ConstShim.with(->(const) { const }) { DomainPortBuilder.build(name, owner: aggregate_name, &block) }

          # A `verb`-shaped port is a plain `Port` — the exact struct
          # `Hecks.port`'s own top-level method registers, so it goes
          # through the same `add_port` the registry already answers for
          # that call. It belongs to no aggregate IR the way an
          # operations-shaped `DomainPort` does; the aggregate above
          # was only needed to resolve `owner` for the operations branch.
          if built.is_a?(Port)
            Hecks.current_registry.add_port(built)
            return self
          end

          built.operations.each do |operation|
            operation.attributes.select(&:reference?).each { |attribute| attribute.type.declared_in = aggregate_ir }
          end
          aggregate_ir.add_port(built)
          self
        end

        def method_missing(verb, *args, **kwargs, &block)
          # A BARE CALL — no args, no kwargs, no block — starts (or
          # continues, on `AttributePath` itself below) a Privacy
          # marking chain: `Registration.attendee.medications.has_phi(
          # readable_by: "Privacy officer")`. No existing real
          # `.hecksagon` bind is ever called this way (verified by
          # grep before adding this branch — `persisted_by`/
          # `opened_by`/every other bind always takes at least one
          # arg), so this cannot collide with recording a `Bind`.
          return AttributePath.new(@fqn, [verb.to_s]) if args.empty? && kwargs.empty? && !block

          @collector << Bind.new(
            aggregate: @fqn,
            verb:      verb.to_s,
            adapter:   args.first.to_s,
            role:      kwargs[:role]&.to_s
          )
          block&.call
          self
        end

        def respond_to_missing?(_name, _include_private = false) = true

        def to_s = @fqn
      end

      # What a Privacy-marking chain resolves to after its first bare segment —
      # `Registration.attendee` returns one of these, `.medications` returns another
      # (one segment longer), and a terminal `has_<category>(readable_by:)` records the
      # marking and ends the chain. See `BindingProxy#method_missing`'s own header for why
      # a bare call is unambiguously the start of one of these, never a `Bind`.
      class AttributePath
        # @param fqn [String] the aggregate's own qualified name, `"Domain::Aggregate"`
        # @param path [Array<String>] every segment named so far, e.g. `["attendee"]`
        def initialize(fqn, path)
          @fqn  = fqn
          @path = path
        end

        # @param verb [Symbol] `has_<category>` to record the marking and end the chain;
        #   any other bare name to extend the path one segment further
        # @param readable_by [String] required only for a `has_<category>` call — the
        #   Governance role a read must hold to see this field unredacted
        # @return [Bluebook::DSL::AttributePath, nil] a longer chain for a plain segment;
        #   `nil` (nothing further to chain) for a `has_<category>` call
        # @raise [Malformed] if a `has_<category>` call omits `readable_by:`, or any call
        #   carries positional args or a block (neither shape this chain supports)
        def method_missing(verb, *args, readable_by: nil, **kwargs, &block)
          name = verb.to_s
          return record_marking(name.delete_prefix("has_"), readable_by) if name.start_with?("has_")

          if !args.empty? || !kwargs.empty? || block
            raise Malformed, "#{@fqn}.#{@path.join('.')}.#{name} — an attribute path chain takes no " \
                             "arguments except a terminal has_<category>(readable_by:)"
          end

          AttributePath.new(@fqn, @path + [name])
        end

        def respond_to_missing?(_name, _include_private = false) = true

        def to_s = "#{@fqn}.#{@path.join('.')}"

        private

        def record_marking(category, readable_by)
          raise Malformed, "#{self}.has_#{category} needs readable_by: (the Governance role a read must hold)" unless readable_by

          Hecks.current_registry.add_pending_privacy_marking(
            domain: @fqn, attribute_path: @path.join("."), category: category, readable_by: readable_by
          )
          nil
        end
      end
    end
  end
end
