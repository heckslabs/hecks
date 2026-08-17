module Hecksagain
  module Bluebook
    module DSL
      class HecksagonBuilder
        class << self
          attr_accessor :collector
        end

        attr_reader :binds, :subscriptions, :framework_members

        def initialize(domain)
          @domain             = domain
          @binds              = []
          @subscriptions      = []
          @framework_members  = []
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
          Hecksagain::Framework.load!(name)
        end

        # THE PRIMARY PORT, BARE AT THE ROOT — belongs to the CHAPTER as a
        # whole, not one aggregate. `BindingProxy#port` is the aggregate-
        # scoped sibling (`Payments::Payment.port("Gateway") do ... end`);
        # this is what's left when a port isn't about any one record. The
        # bluebook must already be built and registered, since a hecksagon
        # loads after its bluebook, and this attaches to that real, final
        # object directly rather than building a second copy MetaValidator
        # would have to know how to reconstruct.
        def port(name, &block)
          bluebook_ir = Hecksagain.current_registry.bluebook(@domain) or
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
          return Hecksagain.current_registry.add_port(built) if built.is_a?(Port)

          bluebook_ir.add_port(built)
        end

        def build
          hecksagon = Hecksagon.new(domain: @domain, binds: @binds, subscriptions: @subscriptions,
                                    framework_members: @framework_members)
          refuse_ungoverned_roles!(hecksagon)
          hecksagon
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
          return super unless args.first

          @binds << Bind.new(aggregate: nil, verb: verb.to_s, adapter: args.first.to_s, role: kwargs[:role]&.to_s)
          block&.call
          self
        end

        def respond_to_missing?(_name, _include_private = false) = true

        private

        # `role` IS REAL ACCESS CONTROL ONLY WHEN GOVERNANCE CAN CHECK IT
        # AGAINST SOMETHING — a command that declares a role but whose
        # domain never attaches Governance would leave that role forever
        # unchecked, exactly the defect ADR 0025 §9 names ("role gates
        # access control by exact string equality ... Governance ...
        # connected to none of it"). Refused here, at HECKSAGON build
        # time, not bluebook build time — a bluebook can be judged before
        # its own domain's hecksagon exists at all (`uses_framework` is a
        # WIRING decision, declared on the hecksagon, same as
        # `persisted_by`), so this is the first point either fact is
        # known together.
        #
        # GOVERNANCE ITSELF IS EXEMPT — it cannot `uses_framework` its own
        # aggregates, and it IS the source of truth a role check runs
        # against, the same self-reference `CommandRules::Authorization
        # #governance_attached?` grants it at dispatch time.
        def refuse_ungoverned_roles!(hecksagon)
          return if hecksagon.domain == "Governance"
          return if hecksagon.framework_members.include?("Governance")

          bluebook_ir = Hecksagain.current_registry.bluebook(hecksagon.domain)
          return unless bluebook_ir

          offender = commands_in(bluebook_ir).find { |command| !command.role.to_s.empty? }
          return unless offender

          raise Malformed,
                "#{offender.hecks_fqn} declares role #{offender.role.inspect}, but " \
                "#{hecksagon.domain}'s hecksagon never uses_framework \"Governance\" — role is only " \
                "real access control once Governance is attached to check it against; without that " \
                "it is silent decoration, the exact defect this refusal exists to catch"
        end

        # Every command this domain declares, an aggregate's own AND every
        # entity nested inside one — the same reach `refuse_role_mismatch`
        # itself needs at dispatch time, just walked ahead of time here.
        def commands_in(bluebook_ir)
          bluebook_ir.aggregates.flat_map { |aggregate| aggregate.commands + aggregate.entities.flat_map(&:commands) }
        end

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
