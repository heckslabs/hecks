require_relative "word_gate"
module Hecks
  module Bluebook
    module DSL
      # Parses a `.hecksagon` file's top-level DSL block into a `Hecksagon`
      # — a domain's own WIRING: which adapter binds to which verb
      # (`persisted_by`, `projected_by`, ...), which framework/vendored
      # bluebooks it attaches, which external events it subscribes to, and
      # its bare chapter-root port. Kept separate from the bluebook itself
      # (the domain's own declared MODEL) because wiring is an operational
      # decision, not a fact the domain states about itself.
      class HecksagonBuilder
        GRAMMAR_CONTEXT = "Hecksagon".freeze

        include WordGate

        class << self
          attr_accessor :collector
        end

        attr_reader :binds, :subscriptions, :framework_members, :vendored_bluebooks

        def initialize(domain)
          @domain             = domain
          @binds              = []
          @subscriptions      = []
          @framework_members  = []
          @vendored_bluebooks = []
        end

        # An event this hecksagon takes from OUTSIDE the domain's own
        # bluebook.
        def subscribe(event) = @subscriptions << event.to_s

        # A framework/ member this domain wants attached —
        # Governance, Identity, whatever else lands beside them.
        # Attaching one is a WIRING decision, the same kind `persisted_by`/
        # `projected_by` already are, so it lives here rather than as a
        # fact stated in the domain's own bluebook. Recorded onto THIS
        # hecksagon, the same way `subscribe` records onto its own
        # `subscriptions` — and loads the member's bluebook then its own
        # hecksagon into whatever registry this one is loading into, see
        # `Framework.load!`.
        def uses_framework(name)
          @framework_members << name.to_s
          Hecks::Framework.load!(name)
        end

        # A VENDORED, EXTERNAL bluebook this domain wants attached — same
        # wiring-decision shape `uses_framework` already is, one level
        # further out: not a member shipped inside hecks's own lib/,
        # but a separate package (embryonaut_bluebooks) vendored into THIS
        # project's own checkout. See EmbryonautBluebook's own header for
        # the full reasoning on why its ROOT can't be a fixed constant the
        # way Framework::ROOT is, and for the recovery provenance.
        #
        # RECORDED ONTO @vendored_bluebooks, same shape `uses_framework`
        # already gives @framework_members — a SEPARATE list on purpose:
        # `framework_members` is load-bearing for `refuse_ungoverned_roles!`
        # (below) and for Governance's own attachment check; conflating
        # the two would make a vendored bluebook attachment satisfy a
        # Governance check it has nothing to do with.
        def uses_embryonaut_bluebook(name)
          @vendored_bluebooks << name.to_s
          Hecks::EmbryonautBluebook.load!(name)
        end

        # THE PRIMARY PORT, BARE AT THE ROOT — belongs to the CHAPTER as a
        # whole, not one aggregate. `BindingProxy#port` is the aggregate-
        # scoped sibling (`Payments::Payment.port("Gateway") do ... end`);
        # this is what's left when a port isn't about any one record. The
        # bluebook must already be built and registered, since a hecksagon
        # loads after its bluebook, and this attaches to that real, final
        # object directly rather than building a second copy MetaValidator
        # would have to know how to reconstruct.
        # RENAMED FROM `port` — item #13's full metaprogrammed dispatch
        # (slice 5). Not bootstrap-reachable (checked directly — no
        # core/attached chapter declares a Hecksagon of its own). Reached
        # through `WordGate#method_missing`'s new `word_gate_dispatch`,
        # called explicitly below since `HecksagonBuilder`'s own
        # class-level `method_missing` (the open-verb catch-all beneath
        # this) always wins over the module's — see `word_gate.rb`'s own
        # header for the full mechanism.
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

        # NO ungoverned-role check here anymore — see
        # Registry::Verification#refuse_ungoverned_roles!. Moved out of
        # per-block `build`, recovered alongside `environment:`
        # (Runtime::Loader.boot's comment has the provenance): a domain
        # split across multiple hecksagon blocks (base + an
        # `environments/<name>.hecksagon` overlay) would have every
        # block but the one declaring `uses_framework "Governance"`
        # refused HERE, even though `Registry#add_hecksagon` merges them
        # into one Hecksagon before anything ever dispatches against it.
        # Checking the MERGED result once, at verify! time — after every
        # file for this domain has loaded — is both more permissive (no
        # need to repeat `uses_framework` in every file) and strictly
        # more correct (a check against an incomplete, not-yet-merged
        # hecksagon can never see the real final shape).
        def build
          Hecksagon.new(domain: @domain, binds: @binds, subscriptions: @subscriptions,
                        framework_members: @framework_members, vendored_bluebooks: @vendored_bluebooks)
        end

        # DOMAIN-LEVEL DEFAULT BINDS — `persisted_by "Heki"` bare, at the top
        # of a hecksagon block, applies to every aggregate in this domain
        # that doesn't declare its own override. Mirrors `BindingProxy`'s own
        # `method_missing` one level down (`aggregate:` filled in there,
        # `nil` here) — generic over verb name, not hardcoded to
        # `persisted_by`/`projected_by` specifically, so any future verb
        # gets a domain-level default for free too. See `Hecksagon#bind_for`
        # for the fallback lookup this feeds.
        def method_missing(verb, *args, **kwargs, &block)
          # A closed-set grammar word (`port`, today) gets first refusal
          # — item #13's full metaprogrammed dispatch (slice 5); see
          # `WordGate#word_gate_dispatch`'s own header for why this class
          # needs to call it explicitly rather than including it the
          # ordinary way. Only once THAT says "not admitted" does the
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
