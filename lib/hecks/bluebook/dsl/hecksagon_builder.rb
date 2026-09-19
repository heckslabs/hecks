require_relative "word_gate"
module Hecks
  module Bluebook
    module DSL
      # Parses a `.hecksagon` file's top-level DSL block into a `Hecksagon`
      # — a domain's own wiring: which adapter binds to which verb
      # (`persisted_by`, `projected_by`, ...), which framework/vendored
      # bluebooks it attaches, which external events it subscribes to, and
      # its bare chapter-root port. Kept separate from the bluebook itself
      # (the domain's own declared model) because wiring is an operational
      # decision, not a fact the domain states about itself.
      class HecksagonBuilder
        GRAMMAR_CONTEXT = "Hecksagon".freeze

        include WordGate

        class << self
          attr_accessor :collector
        end

        attr_reader :binds, :subscriptions, :framework_members, :vendored_bluebooks

        # @param domain [String] name of the domain whose wiring this hecksagon declares
        def initialize(domain)
          @domain             = domain
          @binds              = []
          @subscriptions      = []
          @framework_members  = []
          @vendored_bluebooks = []
        end

        # Subscribes this hecksagon to an event it takes from outside the domain's own bluebook.
        #
        # @param event [String, Symbol] the external event's name
        # @return [Array<String>] every subscription declared so far, this one last
        def subscribe(event) = @subscriptions << event.to_s

        # Attaches a framework member to this domain and loads it into the current registry.
        #
        # A framework/ member this domain wants attached —
        # Governance, Identity, whatever else lands beside them.
        # Attaching one is a wiring decision, the same kind `persisted_by`/
        # `projected_by` already are, so it lives here rather than as a
        # fact stated in the domain's own bluebook. Recorded onto this
        # hecksagon, the same way `subscribe` records onto its own
        # `subscriptions` — and loads the member's bluebook then its own
        # hecksagon into whatever registry this one is loading into, see
        # `Framework.load!`.
        #
        # @param name [String, Symbol] the member's name, such as `"Governance"`
        # @return [Boolean, nil] true when this call loaded the member's bluebook, nil when the
        #   current registry already held it
        # @raise [Runtime::WiringError] if no framework member has that name
        def uses_framework(name)
          @framework_members << name.to_s
          Hecks::Framework.load!(name)
        end

        # Attaches a vendored embryonaut bluebook to this domain and loads its files into the
        # current registry.
        #
        # A vendored, external bluebook this domain wants attached — same
        # wiring-decision shape `uses_framework` already is, one level
        # further out: not a member shipped inside hecks's own lib/,
        # but a separate package (embryonaut_bluebooks) vendored into this
        # project's own checkout. See EmbryonautBluebook's own header for
        # the full reasoning on why its root can't be a fixed constant the
        # way Framework::ROOT is, and for the recovery provenance.
        #
        # Recorded onto @vendored_bluebooks, same shape `uses_framework`
        # already gives @framework_members — a separate list on purpose:
        # `framework_members` is load-bearing for `refuse_ungoverned_roles!`
        # (`Registry::Verification`) and for Governance's own attachment
        # check; conflating the two would make a vendored bluebook attachment
        # satisfy a Governance check it has nothing to do with.
        #
        # @param name [String, Symbol] the vendored package's directory name under
        #   `vendor/embryonaut_bluebooks/`
        # @return [Array<String>, nil] paths of the `.bluebook` files this call loaded, or nil
        #   when the current registry already held the bluebook
        # @raise [Runtime::WiringError] if the current registry has no root to vendor from, or
        #   no vendored bluebook of that name exists under it
        def uses_embryonaut_bluebook(name)
          @vendored_bluebooks << name.to_s
          Hecks::EmbryonautBluebook.load!(name)
        end

        # Declares a port at the hecksagon's root and attaches it to the registered bluebook.
        #
        # The primary port, bare at the root — belongs to the chapter as a
        # whole, not one aggregate. `BindingProxy#port` is the aggregate-
        # scoped sibling (`Payments::Payment.port("Gateway") do ... end`);
        # this is what's left when a port isn't about any one record. The
        # bluebook must already be built and registered, since a hecksagon
        # loads after its bluebook, and this attaches to that real, final
        # object directly rather than building a second copy MetaValidator
        # would have to know how to reconstruct.
        #
        # Answers the `port` word through the table's `calls:` column —
        # item #13's full metaprogrammed dispatch (slice 5). Not
        # bootstrap-reachable (checked directly — no core/attached chapter
        # declares a Hecksagon of its own). Reached through `WordGate`'s
        # `word_gate_dispatch`, called explicitly below since
        # `HecksagonBuilder`'s own class-level `method_missing` (the
        # open-verb catch-all beneath this) always wins over the module's —
        # see `word_gate.rb`'s own header for the full mechanism.
        #
        # @param name [String] the port's name
        # @yield the port body, evaluated against a `DomainPortBuilder`: either `verb`/`signal`
        #   or `operation`/`tells`/`asks` blocks
        # @return [Bluebook::Port, Bluebook::DomainPort] the built port: a verb-shaped `Port`
        #   registered on the current registry, or a `DomainPort` attached to the bluebook
        # @raise [Bluebook::DSL::Malformed] if the current registry holds no bluebook for this
        #   domain, or the body declares both a verb and operations, neither, or an operation
        #   the port grammar refuses
        def port_impl(name, &block)
          bluebook_ir = Hecks.current_registry.bluebook(@domain) or
            raise Malformed, "#{@domain} declares no such bluebook — a port needs one to belong to"

          # See BindingProxy#port's own comment on why this resolver swap is
          # needed — ConstShim's active resolver is one global for the whole
          # dynamic extent, currently this file's own BindingProxy-minting
          # one, which would turn a bare constant inside an operation's
          # `reference_to`/`attribute` into another BindingProxy instead of
          # a name.
          built = ConstShim.with(->(const) { const }) { DomainPortBuilder.build(name, &block) }

          # See BindingProxy#port's own comment on the same branch — a
          # `verb`-shaped port is a plain `Port`, registered the same
          # way `Hecks.port`'s top-level method already does, not attached
          # to this bluebook's own IR the way an operations-shaped
          # `DomainPort` is.
          return Hecks.current_registry.add_port(built) if built.is_a?(Port)

          bluebook_ir.add_port(built)
        end

        # Assembles the collected binds, subscriptions and attachments into a `Hecksagon`.
        #
        # No ungoverned-role check here — see
        # Registry::Verification#refuse_ungoverned_roles!. It lives outside
        # per-block `build`, alongside `environment:`
        # (Runtime::Loader.boot's comment has the provenance): a domain
        # split across multiple hecksagon blocks (base + an
        # `environments/<name>.hecksagon` overlay) would have every
        # block but the one declaring `uses_framework "Governance"`
        # refused here, even though `Registry#add_hecksagon` merges them
        # into one Hecksagon before anything ever dispatches against it.
        # Checking the merged result once, at verify! time — after every
        # file for this domain has loaded — is both more permissive (no
        # need to repeat `uses_framework` in every file) and strictly
        # more correct (a check against an incomplete, not-yet-merged
        # hecksagon can never see the real final shape).
        #
        # @return [Bluebook::Hecksagon] this block's wiring, which `Registry#add_hecksagon` merges
        #   with any other block declared for the same domain
        def build
          Hecksagon.new(domain: @domain, binds: @binds, subscriptions: @subscriptions,
                        framework_members: @framework_members, vendored_bluebooks: @vendored_bluebooks)
        end

        # Records any verb the grammar does not own as a domain-wide bind to the named adapter.
        #
        # **Domain-level default binds** — `persisted_by "Heki"` bare, at the top
        # of a hecksagon block, applies to every aggregate in this domain
        # that doesn't declare its own override. Mirrors `BindingProxy`'s own
        # `method_missing` one level down (`aggregate:` filled in there,
        # `nil` here) — generic over verb name, not hardcoded to
        # `persisted_by`/`projected_by` specifically, so any future verb
        # gets a domain-level default for free too. See `Hecksagon#bind_for`
        # for the fallback lookup this feeds.
        #
        # @param verb [Symbol] the word called, such as `:persisted_by`
        # @param args [Array<Object>] positional arguments; the first names the adapter
        # @param kwargs [Hash{Symbol => Object}] keyword arguments; `:role` is kept on the bind
        # @yield an optional block, called once after the bind is recorded
        # @return [Object] this builder after recording a bind, or the grammar word's own result
        #   when `verb` is one the `Hecksagon` grammar admits
        # @raise [NoMethodError] if `verb` is no grammar word and names no adapter
        # @raise [Bluebook::DSL::Malformed] if the grammar admits `verb` only in another context,
        #   or admits it here and its implementation refuses the declaration
        def method_missing(verb, *args, **kwargs, &block)
          # A closed-set grammar word (`port`, today) gets first refusal
          # — item #13's full metaprogrammed dispatch (slice 5); see
          # `WordGate#word_gate_dispatch`'s own header for why this class
          # needs to call it explicitly rather than including it the
          # ordinary way. Only once that says "not admitted" does the
          # genuinely open-ended `persisted_by "Heki"`-style bind
          # vocabulary below get a turn.
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
        #
        # @param domain [String] name of the domain being wired
        # @yield the hecksagon body, evaluated with the builder as `self`; may be omitted
        # @return [Bluebook::Hecksagon] the declared wiring
        # @raise [Bluebook::DSL::Malformed] if a `port` names no registered bluebook or aggregate,
        #   or declares a shape the port grammar refuses
        # @raise [Runtime::WiringError] if `uses_framework` or `uses_embryonaut_bluebook` names
        #   something that cannot be found
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
