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
        # Runs the whole wiring gate against this registry's loaded bluebooks,
        # hexagons, ports and adapters.
        #
        # @return [Runtime::Registry] self
        # @raise [Runtime::WiringError] if a bind names an undeclared aggregate, an
        #   adapter cannot satisfy its port's verb or declared `answers`, a world
        #   setting names a field its adapter does not declare, the default adapter
        #   is unusable, or a command declares a role with no authorization provider
        #   attached
        def verify!
          verify_default_adapter!
          verify_singleton_port_answers!
          refuse_cross_package_bluebook_merge!

          @hecksagons.each_value do |hexagon|
            refuse_ungoverned_roles!(hexagon)

            hexagon.binds.each do |bind|
              # A domain-level default (§0) — `persisted_by "Heki"` bare,
              # applying to whichever aggregates don't override it — names
              # no aggregate of its own, so there's nothing to look up in
              # the bluebook for this row specifically. Still validate its
              # own adapter/verb shape (the same reason
              # `verify_default_adapter!` checks the framework-wide
              # default the same way, aggregate-less). Coverage of real
              # aggregates that only resolve through this default comes
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
            warn_undurable_outbox!(hexagon)
          end
          self
        end

        # Checks that the framework-wide default persistence adapter (used by any
        # aggregate left out of an explicit bind list) is itself wired correctly.
        #
        # @return [Runtime::Registry] self
        # @raise [Runtime::WiringError] if the default adapter cannot satisfy the
        #   persistence port's verb, is missing a declared `answers` method, or has
        #   no Ruby implementation
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

        # Checks that `bind`'s adapter implements the port it names and satisfies
        # the verb the bind declares.
        #
        # @param bind [Bluebook::Bind] the bind to check
        # @return [void]
        # @raise [Runtime::WiringError] if `bind`'s adapter is unknown, declares an
        #   unknown port, is missing a declared `answers` method, or cannot satisfy
        #   `bind`'s own verb
        def check_verb(bind)
          port = port_for(bind)
          check_answers(port, bind.adapter)
          return if port.verb.to_s == bind.verb.to_s

          raise WiringError,
                "#{bind.adapter} implements the #{port.name} port (verb #{port.verb}) " \
                "and cannot satisfy #{bind.verb}"
        end

        # The method contract a `.port` file's `verb`/`signal` never
        # carried — an adapter can name the right port, satisfy the right
        # verb, and admit every `.world` setting `check_settings` checks,
        # and still be missing the one method a live dispatch will
        # actually call. `answers` is optional per port (an empty list is
        # today's pre-existing behavior, unchecked), so this only ever
        # tightens a port that opted in.
        #
        # @param port [Bluebook::Port] the port whose declared `answers` methods
        #   `adapter_name` must respond to
        # @param adapter_name [String] the adapter's declared name to check
        # @return [void]
        # @raise [Runtime::WiringError] if `adapter_name` has no Ruby implementation,
        #   or its implementation does not respond to one of `port.answers`
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

        # **The nine singleton ports' own gap** — `persistence`, `projection`
        # and `loading` are per-aggregate bindings, checked above through
        # every real `bind` a hexagon declares; a singleton port
        # (`clock`, `authorization`, …) is never bound to an aggregate at
        # all, so nothing above ever resolves one and nothing above ever
        # ran `check_answers` against it. Each one's own `Ports::*.adapter`
        # already refuses zero or multiple implementations, live, at
        # first dispatch — that stays exactly as-is here (0 or 2+ is
        # ambiguity, not a method-contract question, and asserting every
        # declared port must have exactly one adapter would wrongly
        # refuse a boot that simply never wires a port it doesn't use).
        # This only ever tightens the one case those checks don't cover:
        # exactly one adapter, wired, missing a method `answers` names.
        PER_AGGREGATE_PORTS = %w[persistence projection loading].freeze

        # Checks every singleton port (not per-aggregate-bound) with exactly one
        # wired adapter against its own declared `answers` methods.
        #
        # @return [Runtime::Registry] self
        # @raise [Runtime::WiringError] if a singleton port's one wired adapter is
        #   missing one of its declared `answers` methods
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

        # Checks that every setting `settings` declares (besides `:adapter`) is a
        # field `bind`'s adapter actually admits.
        #
        # @param bind [Bluebook::Bind] the bind naming the adapter to check against;
        #   a no-op if its adapter is unknown
        # @param settings [Hash{Symbol => Object}] the world's declared settings for
        #   this bind
        # @return [void]
        # @raise [Runtime::WiringError] if `settings` declares a field `bind`'s
        #   adapter does not declare
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

        # Finds the port `bind`'s adapter declares.
        #
        # @param bind [Bluebook::Bind] the bind naming the adapter to look up
        # @return [Bluebook::Port] the port `bind`'s adapter declares
        # @raise [Runtime::WiringError] if `bind` names an unknown adapter, or one
        #   declaring an unknown port
        def port_for(bind)
          adapter = @adapters[bind.adapter]
          raise WiringError, "unknown adapter #{bind.adapter.inspect}" unless adapter

          @ports[adapter.port] ||
            raise(WiringError, "adapter #{bind.adapter} declares unknown port #{adapter.port.inspect}")
        end

        # Finds the Ruby module implementing the adapter declared `name`.
        #
        # @param name [String] the adapter's declared name, such as `"PostgresEra"`
        # @return [Module] the adapter module or class under `Hecks::Adapters`
        # @raise [Runtime::WiringError] if no Ruby implementation named `name` exists
        #   under `Hecks::Adapters`
        def adapter_class(name)
          Adapters.const_get(name)
        rescue NameError
          raise WiringError, "no Ruby adapter implementation for #{name.inspect} " \
                             "(expected Hecks::Adapters::#{name})"
        end

        private

        # `role` is real access control only when governance can check it
        # against something — a command that declares a role but whose
        # domain never attaches Governance would leave that role forever
        # unchecked, exactly the defect ADR 0025 §9 names ("role gates
        # access control by exact string equality ... Governance ...
        # connected to none of it"). Checked here, at `verify!` — recovered
        # and moved, not new: running this per-block, at hecksagon
        # build time (Bluebook::DSL::HecksagonBuilder#build), breaks
        # the moment a domain is split across multiple hecksagon
        # blocks (base + an `environments/<name>.hecksagon` overlay,
        # Runtime::Loader.boot's `environment:` — see its own comment for
        # the recovery provenance): every block but the one declaring
        # `uses_framework "Governance"` would be refused there, even
        # though `Registry#add_hecksagon` merges every block for a domain
        # into one Hecksagon before anything ever dispatches against it.
        # Checking the merged result once, here, after every file for
        # this domain has loaded, is both more permissive (no need to
        # repeat `uses_framework` in every file) and strictly more
        # correct (a check against an incomplete, not-yet-merged
        # hecksagon can never see the real final shape).
        #
        # A provider is recognised by its declaration, not its name —
        # `authorization_provider_for` answers for the domain's own
        # chapter too, so Governance (which declares `provides
        # "authorization"`) passes here because of what it declares, and
        # the same rule `CommandRules::Authorization#governance_attached?`
        # applies at dispatch time.
        def refuse_ungoverned_roles!(hexagon)
          return if authorization_provider_for(hexagon.domain)

          bluebook_ir = bluebook(hexagon.domain)
          return unless bluebook_ir

          offender = commands_in(bluebook_ir).find { |command| !command.role.to_s.empty? }
          return unless offender

          raise WiringError,
                "#{offender.hecks_fqn} declares role #{offender.role.inspect}, but " \
                "#{hexagon.domain}'s hecksagon never #{authorization_attachment_hint} — role is only " \
                "real access control once an authorization provider is attached to check it against; " \
                "without that it is silent decoration, the exact defect this refusal exists to catch"
        end

        # The suggestion, derived from whichever framework members actually
        # declare `provides "authorization"` — never a hardcoded name.
        def authorization_attachment_hint
          providers = Framework.providers_of(Bluebook::Capabilities::AUTHORIZATION)
          return "attaches a chapter that provides \"authorization\" (no framework member declares one)" if providers.empty?

          providers.map { |name| "uses_framework #{name.inspect}" }.join(" or ")
        end

        # Every command this domain declares, an aggregate's own and every
        # entity nested inside one — the same reach `refuse_role_mismatch`
        # itself needs at dispatch time, just walked ahead of time here.
        def commands_in(bluebook_ir)
          bluebook_ir.aggregates.flat_map { |aggregate| aggregate.commands + aggregate.entities.flat_map(&:commands) }
        end

        # TWO UNRELATED PACKAGES, ONE CHAPTER NAME BY COINCIDENCE — the
        # real risk `Registry#bluebook_sources` exists to catch (found
        # live: a stale `vendor/hecksagain` fork's own copy of Governance/
        # Identity/Deploy, still reachable on 4 consuming apps' own load
        # paths alongside the real gem). `BluebookBuilder.build`'s own
        # accumulation (several files declaring the SAME chapter name ON
        # PURPOSE — `lib/hecks/language/bluebook/*.bluebook` all open
        # `Hecks.bluebook "Bluebook"`) is never touched here — that merge
        # stays unconditional, checked only AFTER every file has loaded,
        # the same "check the merged final result once" timing
        # `refuse_ungoverned_roles!` already uses and for the same reason
        # (a check against an incomplete load can never see the real
        # shape). What distinguishes intentional accumulation from
        # coincidence is PACKAGE ROOT, not file identity: files a real
        # gemspec or a `vendor/` boundary already treats as one unit are
        # expected to share a name; files from two DIFFERENT roots never
        # legitimately do.
        def refuse_cross_package_bluebook_merge!
          @bluebook_sources.each do |name, paths|
            roots = paths.map { |path| package_root_for(path) }.uniq
            next if roots.size <= 1

            raise WiringError,
                  "#{name.inspect} is declared by more than one package: #{roots.join(' and ')} — " \
                  "these are two unrelated sources sharing a chapter name by coincidence, not one " \
                  "domain split across files, and merging their declarations into one chapter is " \
                  "almost certainly a stale/vendored copy left on the load path (paths: " \
                  "#{paths.join(', ')})"
          end
        end

        # THE NEAREST BOUNDARY A PATH ALREADY BELONGS TO — a real
        # gemspec (this IS a package, whatever depends on it or vendors
        # it), or a bare `vendor/` path component, treated as its OWN
        # root regardless of what gemspec might sit above it: vendored
        # code should never be considered "the same package" as whatever
        # it's vendored into, even when nothing else marks the boundary.
        # Neither found, the path's own directory is the root — two
        # files with no closer marker only "belong together" if they are
        # literally the same file.
        def package_root_for(path)
          return path.to_s if path.nil?

          dir = File.dirname(File.expand_path(path))
          loop do
            return "vendor:#{dir}" if File.basename(dir) == "vendor"
            return dir if Dir.glob(File.join(dir, "*.gemspec")).any?

            parent = File.dirname(dir)
            return dir if parent == dir

            dir = parent
          end
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
        # A warning, not a refusal — unlike `refuse_ungoverned_roles!`,
        # running sagas on a store with no `save_saga` is legitimate on
        # purpose in a fast in-memory test/dev boot (this project's own
        # `saga_durability_spec.rb` boots a process manager on `Memory`
        # specifically to exercise the saga_mutex without real I/O), so
        # refusing the boot outright would break a choice an author made
        # deliberately. What a deploy needs is for the gap to be loud and
        # undeniable, not for local dev/test to become impossible.
        # The outbox's twin of `warn_undurable_sagas!` — a domain that
        # declares anything a commit could owe a reaction to (a policy
        # listening to one of its events, or a process manager) but is
        # bound to an adapter with no outbox (`AppendOnly#outbox?`) gets
        # reactions the pre-outbox way: run inline, lost on a crash
        # between commit and reaction. A warning, not a refusal, for the
        # reason `warn_undurable_sagas!` gives — and Memory has an outbox
        # (in-process, like everything else it holds), so a dev/test
        # boot stays quiet; this speaks up for the file/remote adapters
        # that persist state durably but hand reactions to nothing.
        def warn_undurable_outbox!(hexagon)
          bluebook_ir = bluebook(hexagon.domain)
          return unless bluebook_ir
          return if bluebook_ir.process_managers.empty? && !any_policy_listens_to?(bluebook_ir)

          anchor = bluebook_ir.aggregates.first or return
          bind = Ports::Persistence::BindingPolicy.resolve(self, hexagon.domain, anchor)
          return if adapter_class(bind.adapter) <= Ports::Persistence::RemoteRuntime
          return if repository(hexagon.domain, anchor).outbox?

          warn "[hecks] #{hexagon.domain} declares policies/process_managers but its persistence adapter " \
               "(#{bind.adapter}) has no outbox — reactions run inline and a crash between a command's commit " \
               "and its reactions loses them silently. Bind SqlitePersistence or Postgres for a durable outbox " \
               "(see Runtime::Outbox), or accept in-process-only reactions on purpose."
        rescue WiringError
          nil
        end

        def any_policy_listens_to?(bluebook_ir)
          emitted = bluebook_ir.aggregates.flat_map do |aggregate|
            aggregate.commands.flat_map(&:emits) +
              aggregate.ports.flat_map { |port| port.operations.flat_map { |op| [*op.emits, op.answers, op.refuses] } }
          end.compact.map(&:to_s)
          @bluebooks.each_value.any? { |candidate| candidate.policies.any? { |policy| emitted.include?(policy.event_name.to_s) } }
        end

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
