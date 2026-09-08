require_relative "../../bluebook/hexagon"

module Hecks
  module Runtime
    class Registry
      # The wiring gate: every bind names a declared aggregate, every
      # adapter satisfies the verb its port declares, every world setting is
      # a field the adapter admits, and the default adapter is usable at
      # all. Included into Registry — `verify!` is what a boot calls after
      # loading, and the smaller checks are also called piecemeal by the
      # repository factory.
      module Verification
        def verify!
          verify_default_adapter!
          verify_singleton_port_answers!

          @hecksagons.each_value do |hexagon|
            refuse_ungoverned_roles!(hexagon)

            hexagon.binds.each do |bind|
              # A domain-level default (§0) — `persisted_by "Heki"` bare,
              # applying to whichever aggregates don't override it — names
              # no aggregate of its own, so there's nothing to look up in
              # the bluebook for THIS row specifically. Still validate its
              # own adapter/verb shape (the same reason
              # `verify_default_adapter!` checks the framework-wide
              # default the same way, aggregate-less). Coverage of real
              # aggregates that only resolve THROUGH this default comes
              # from their own dispatch-time `BindingPolicy.resolve` —
              # deliberately not required to be exhaustive here, the same
              # leniency this method already extended to any aggregate
              # left out of an explicit bind list entirely (real test
              # fixtures bind only the aggregates they exercise).
              if bind.aggregate.nil?
                check_verb(bind)
                next
              end

              aggregate = bluebook(hexagon.domain)&.aggregate(bind.aggregate_name)
              raise WiringError, "#{bind.aggregate} is bound but not declared in the bluebook" unless aggregate

              check_verb(bind)

              repository(hexagon.domain, aggregate)
            end

            warn_undurable_sagas!(hexagon)
          end
          self
        end

        def verify_default_adapter!
          name = Ports::Persistence::DEFAULT_ADAPTER

          check_verb(
            Bluebook::Bind.new(
              aggregate: "(default)",
              verb:      Ports::Persistence::VERB,
              adapter:   name
            )
          )
          adapter_class(name)
          self
        rescue WiringError => e
          raise WiringError,
                "the default persistence adapter (#{name}) is not usable, so an " \
                "aggregate with no bind could not be given one: #{e.message}"
        end

        def check_verb(bind)
          port = port_for(bind)
          check_answers(port, bind.adapter)
          return if port.verb.to_s == bind.verb.to_s

          raise WiringError,
                "#{bind.adapter} implements the #{port.name} port (verb #{port.verb}) " \
                "and cannot satisfy #{bind.verb}"
        end

        # THE METHOD CONTRACT A `.port` FILE'S `verb`/`signal` NEVER
        # CARRIED — an adapter can name the right port, satisfy the right
        # verb, and admit every `.world` setting `check_settings` checks,
        # and still be missing the one method a live dispatch will
        # actually call. `answers` is optional per port (an empty list is
        # today's pre-existing behavior, unchecked), so this only ever
        # tightens a port that opted in.
        def check_answers(port, adapter_name)
          answers = Array(port.answers)
          return if answers.empty?

          klass   = adapter_class(adapter_name)
          missing = answers.reject { |method_name| klass.respond_to?(method_name) }
          return if missing.empty?

          raise WiringError,
                "#{adapter_name} declares the #{port.name} port but does not respond to " \
                "#{missing.map(&:inspect).join(', ')} — #{port.name}.port declares answers " \
                "#{answers.map(&:inspect).join(', ')}"
        end

        # THE NINE SINGLETON PORTS' OWN GAP — `persistence`, `projection`
        # and `loading` are per-aggregate bindings, checked above through
        # every real `bind` a hexagon declares; a singleton port
        # (`clock`, `authorization`, …) is never bound to an aggregate at
        # all, so nothing above ever resolves one and nothing above ever
        # ran `check_answers` against it. Each one's own `Ports::*.adapter`
        # already refuses zero or multiple implementations, live, at
        # first dispatch — that stays exactly as-is here (0 or 2+ is
        # ambiguity, not a method-contract question, and asserting every
        # declared port MUST have exactly one adapter would wrongly
        # refuse a boot that simply never wires a port it doesn't use).
        # This only ever tightens the ONE case those checks don't cover:
        # exactly one adapter, wired, missing a method `answers` names.
        PER_AGGREGATE_PORTS = %w[persistence projection loading].freeze

        def verify_singleton_port_answers!
          @ports.each_value do |port|
            next if PER_AGGREGATE_PORTS.include?(port.name)
            next if Array(port.answers).empty?

            implementations = @adapters.values.select { |a| a.port == port.name }
            next unless implementations.size == 1

            check_answers(port, implementations.first.name)
          end
          self
        end

        def check_settings(bind, settings)
          adapter = @adapters[bind.adapter]
          return unless adapter

          declared = settings.keys - [:adapter]
          unknown  = declared.reject { |field| adapter.declares?(field) }
          return if unknown.empty?

          raise WiringError,
                "#{bind.adapter} does not declare #{unknown.map(&:inspect).join(', ')} — " \
                "it declares #{adapter.all_fields.map(&:inspect).join(', ')}. " \
                "Add the field to the adapter, or remove it from the world."
        end

        def port_for(bind)
          adapter = @adapters[bind.adapter]
          raise WiringError, "unknown adapter #{bind.adapter.inspect}" unless adapter

          @ports[adapter.port] ||
            raise(WiringError, "adapter #{bind.adapter} declares unknown port #{adapter.port.inspect}")
        end

        def adapter_class(name)
          Adapters.const_get(name)
        rescue NameError
          raise WiringError, "no Ruby adapter implementation for #{name.inspect} " \
                             "(expected Hecks::Adapters::#{name})"
        end

        private

        # `role` IS REAL ACCESS CONTROL ONLY WHEN GOVERNANCE CAN CHECK IT
        # AGAINST SOMETHING — a command that declares a role but whose
        # domain never attaches Governance would leave that role forever
        # unchecked, exactly the defect ADR 0025 §9 names ("role gates
        # access control by exact string equality ... Governance ...
        # connected to none of it"). Checked here, at `verify!` — RECOVERED
        # and MOVED, not new: this used to run per-block, at HECKSAGON
        # build time (Bluebook::DSL::HecksagonBuilder#build), which broke
        # the moment a domain could be split across multiple hecksagon
        # blocks (base + an `environments/<name>.hecksagon` overlay,
        # Runtime::Loader.boot's `environment:` — see its own comment for
        # the recovery provenance): every block but the one declaring
        # `uses_framework "Governance"` would be refused there, even
        # though `Registry#add_hecksagon` merges every block for a domain
        # into ONE Hecksagon before anything ever dispatches against it.
        # Checking the MERGED result once, here, after every file for
        # this domain has loaded, is both more permissive (no need to
        # repeat `uses_framework` in every file) and strictly more
        # correct (a check against an incomplete, not-yet-merged
        # hecksagon can never see the real final shape).
        #
        # GOVERNANCE ITSELF IS EXEMPT — it cannot `uses_framework` its own
        # aggregates, and it IS the source of truth a role check runs
        # against, the same self-reference `CommandRules::Authorization
        # #governance_attached?` grants it at dispatch time.
        def refuse_ungoverned_roles!(hexagon)
          return if hexagon.domain == "Governance"
          return if hexagon.framework_members.include?("Governance")

          bluebook_ir = bluebook(hexagon.domain)
          return unless bluebook_ir

          offender = commands_in(bluebook_ir).find { |command| !command.role.to_s.empty? }
          return unless offender

          raise WiringError,
                "#{offender.hecks_fqn} declares role #{offender.role.inspect}, but " \
                "#{hexagon.domain}'s hecksagon never uses_framework \"Governance\" — role is only " \
                "real access control once Governance is attached to check it against; without that " \
                "it is silent decoration, the exact defect this refusal exists to catch"
        end

        # Every command this domain declares, an aggregate's own AND every
        # entity nested inside one — the same reach `refuse_role_mismatch`
        # itself needs at dispatch time, just walked ahead of time here.
        def commands_in(bluebook_ir)
          bluebook_ir.aggregates.flat_map { |aggregate| aggregate.commands + aggregate.entities.flat_map(&:commands) }
        end

        # A domain that declares a `process_manager` but whose
        # `saga_persistence` resolves to `NULL_SAGA_STORE` (no anchor
        # aggregate, a RemoteRuntime-shaped adapter, an adapter that
        # doesn't `respond_to?(:save_saga)`, or a rescued WiringError —
        # see `SagaPersistence#resolve_saga_persistence`) gets sagas that
        # advance correctly in-process and vanish on restart: no
        # checkpoint written, nothing for `rehydrate_sagas!` to find, no
        # compensation ever replayed. That is silent right up until the
        # process actually dies mid-saga — the same "consistency/
        # freshness defect applied to access control, failing open" ADR
        # 0025 named for an unchecked `role`, here applied to saga
        # durability instead.
        #
        # A WARNING, NOT A REFUSAL — unlike `refuse_ungoverned_roles!`,
        # running sagas on a store with no `save_saga` is legitimate on
        # purpose in a fast in-memory test/dev boot (this project's own
        # `saga_durability_spec.rb` boots a process manager on `Memory`
        # specifically to exercise the saga_mutex without real I/O), so
        # refusing the boot outright would break a choice an author made
        # deliberately. What a deploy needs is for the gap to be loud and
        # undeniable, not for local dev/test to become impossible.
        def warn_undurable_sagas!(hexagon)
          bluebook_ir = bluebook(hexagon.domain)
          return unless bluebook_ir
          return if bluebook_ir.process_managers.empty?
          return unless saga_persistence(hexagon.domain).equal?(Ports::Persistence::NULL_SAGA_STORE)

          names = bluebook_ir.process_managers.map(&:name).join(", ")
          warn "[hecks] #{hexagon.domain} declares process_manager(s) #{names} but its resolved " \
               "persistence adapter has no save_saga — saga state advances correctly in-process " \
               "and is LOST on restart (no checkpoint, no rehydration, no compensation replay). " \
               "Bind this domain to an adapter that implements save_saga if this process_manager " \
               "must survive a crash."
        end
      end
    end
  end
end
