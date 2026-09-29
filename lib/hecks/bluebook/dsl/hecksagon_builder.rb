require_relative "word_gate"
module Hecks
  module Bluebook
    module DSL
      # Parses a `.hecksagon` file's DSL block into a Hecksagon: a domain's adapter bindings,
      # framework/vendored attachments and subscriptions — wiring, not part of the bluebook.
      class HecksagonBuilder
        GRAMMAR_CONTEXT = "Hecksagon".freeze

        include WordGate

        class << self
          attr_accessor :collector
        end

        attr_reader :binds, :subscriptions, :framework_members, :vendored_bluebooks, :attached_chapters

        def initialize(domain)
          @domain             = domain
          @binds              = []
          @subscriptions      = []
          @framework_members  = []
          @vendored_bluebooks = []
          @attached_chapters  = []
          @bounded            = false
          @translates         = []
        end

        # Marks this chapter as a bounded context; framework/vendored attachments set it too.
        # Must declare at least one `translates` ACL or boot refuses.
        def bounded
          @bounded = true
        end

        # Subscribes to an event from outside this domain's own bluebook.
        def subscribe(event) = @subscriptions << event.to_s

        # Attaches a framework member (e.g. Governance) and loads it into the current registry.
        def uses_framework(name)
          @framework_members << name.to_s
          Hecks::Framework.load!(name)
          # Marks the framework member as bounded; the consumer's own hecksagon is the
          # anti-corruption layer.
          Hecks.current_registry&.mark_bounded(name.to_s)
        end

        # Attaches a vendored embryonaut bluebook to this domain and loads its files into the
        # registry. Recorded separately from @framework_members, which is load-bearing for
        # governance checks.
        def uses_embryonaut_bluebook(name)
          @vendored_bluebooks << name.to_s
          Hecks::EmbryonautBluebook.load!(name)
          # Marks the chapter bounded, same as `uses_framework`; the directory name Pascal-cases
          # to the chapter name (`"membership"` → `Membership`).
          Hecks.current_registry&.mark_bounded(Hecks::Naming.pascal(name.to_s))
        end

        # Attaches a chapter the gem carries (the language, Expression, Tenancy, Deploy) by name
        # and loads its files into the registry. Marked bounded like a framework member, since
        # this hecksagon is its anti-corruption layer.
        def attaches(name)
          require_relative "../../chapters"
          @attached_chapters << name.to_s
          Hecks::Chapters.load!(name)
          Hecks.current_registry&.mark_bounded(name.to_s)
        end

        # Declares a port at the hecksagon's root — the chapter as a whole, not one aggregate.
        def port_impl(name, &block)
          bluebook_ir = Hecks.current_registry.bluebook(@domain) or
            raise Malformed, "#{@domain} declares no such bluebook — a port needs one to belong to"

          # Swaps the active ConstShim resolver to plain passthrough — without it a bare constant
          # inside `reference_to`/`attribute` would resolve to a BindingProxy instead of a name.
          built = ConstShim.with(->(const) { const }) { DomainPortBuilder.build(name, &block) }

          # A verb-shaped port is a plain `Port`, registered like `Hecks.port`'s top-level method,
          # not attached to this bluebook's IR the way an operations-shaped `DomainPort` is.
          return Hecks.current_registry.add_port(built) if built.is_a?(Port)

          bluebook_ir.add_port(built)
        end

        # A cross-domain reaction, built as the same `Policy` an in-bluebook `policy` block would.
        # Must be a block — the eager const resolver here can't handle multi-segment references.
        def translates(name, &block)
          bluebook_ir = Hecks.current_registry.bluebook(@domain) or
            raise Malformed, "#{@domain} declares no such bluebook — translates needs one to attach its reaction to"

          # Same resolver `policy` blocks use for `on`/`trigger` — a ScopedConstant, not the bare
          # passthrough `port_impl` swaps to, since these take multi-segment references.
          resolver = ->(const) { ConstShim::ScopedConstant.for(const) }
          built = ConstShim.with(resolver) { PolicyBuilder.build(name, &block) }

          @translates << name.to_s
          bluebook_ir.add_policy(built)
        end

        # Assembles the collected binds, subscriptions and attachments into a `Hecksagon`.
        # No ungoverned-role check here — it runs once on the merged result at verify! time.
        def build
          Hecksagon.new(domain: @domain, binds: @binds, subscriptions: @subscriptions,
                        framework_members: @framework_members, vendored_bluebooks: @vendored_bluebooks,
                        attached_chapters: @attached_chapters, bounded: @bounded, translates: @translates)
        end

        # Records any verb the grammar doesn't own as a domain-wide default bind, e.g. bare
        # `persisted_by "Heki"` at the top of a block, applied unless an aggregate overrides it.
        def method_missing(verb, *args, **kwargs, &block)
          # Grammar words (like `port`) get first refusal via explicit dispatch; only when that's
          # not admitted does the open-ended `persisted_by`-style bind vocabulary below apply.
          result = word_gate_dispatch(verb, args, kwargs, block)
          return result unless result.equal?(WordGate::NOT_ADMITTED)

          return super unless args.first

          @binds << Bind.new(aggregate: nil, verb: verb.to_s, adapter: args.first.to_s, role: kwargs[:role]&.to_s)
          block&.call
          self
        end

        def respond_to_missing?(_name, _include_private = false) = true

        # Evaluates a `Hecks.hecksagon` block with bare `Domain::Aggregate` constants resolving to
        # bind-collecting proxies, and returns the wiring it declared.
        def self.build(domain, &block)
          builder  = new(domain)
          resolver = ->(name) { BindingProxy.namespace(name, builder.binds) }

          previous       = collector
          self.collector = builder.binds
          begin
            ConstShim.with(resolver) { builder.instance_eval(&block) } if block
          ensure
            self.collector = previous
          end

          builder.build
        end
      end
    end
  end
end
