require_relative "../../bluebook/hexagon"

module Hecks
  module Runtime
    class Registry
      # The wiring gate: every bind names a declared aggregate, every adapter satisfies its
      # port's verb, and every world default is usable. `verify!` runs it all at boot.
      module Verification
        # Runs every wiring check against this registry's loaded bluebooks, hexagons, ports
        # and adapters.
        def verify!
          verify_default_adapter!
          verify_world_defaults!
          verify_singleton_port_answers!
          refuse_cross_package_bluebook_merge!
          refuse_membership_without_identity!
          refuse_unresolved_port_operations!
          refuse_unanswerable_queries!

          @hecksagons.each_value do |hexagon|
            refuse_ungoverned_roles!(hexagon)
            refuse_unwired_framework_members!(hexagon)
            refuse_unwired_vendored_bluebooks!(hexagon)
            refuse_bounded_without_acl!(hexagon)

            hexagon.binds.each do |bind|
              # A domain-level default (§0) names no aggregate of its own; still validate its
              # adapter/verb shape. Real aggregates resolving through it are covered by their
              # own dispatch-time `BindingPolicy.resolve`, not required to be exhaustive here.
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

        # Checks that the framework-wide default persistence adapter is itself wired correctly.
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

        # Checks that `bind`'s adapter implements the port it names and satisfies its verb.
        def check_verb(bind)
          port = port_for(bind)
          check_answers(port, bind.adapter)
          return if port.verb.to_s == bind.verb.to_s

          raise WiringError,
                "#{bind.adapter} implements the #{port.name} port (verb #{port.verb}) " \
                "and cannot satisfy #{bind.verb}"
        end

        # `answers` is optional per port, so an adapter can satisfy a port's verb and still
        # miss a method live dispatch will call; this only tightens ports that opt in.
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

        # persistence/projection/loading are per-aggregate bound and already checked via
        # each bind above; a singleton port is never bound to an aggregate at all.
        PER_AGGREGATE_PORTS = %w[persistence projection loading].freeze

        # Checks every singleton port with exactly one wired adapter against its own
        # declared `answers` methods.
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

        # Checks that every setting `settings` declares (besides `:adapter`) is a field
        # `bind`'s adapter actually admits.
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

        # Checked once against the merged hecksagon so a domain split across multiple
        # hecksagon files sees every uses_framework declaration first. A role is real
        # access control only once an authorization provider exists to check it against
        # (ADR 0025); a provider is recognized by declaring authorization, not by name.
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

        # `uses_embryonaut_bluebook` only loads a package's `.bluebook` files; persistence,
        # Governance and the `translates` ACL live on a sibling hecksagon the consumer must
        # declare, or cross-context field mapping has nowhere to be written.
        def refuse_unwired_vendored_bluebooks!(hexagon)
          Array(hexagon.vendored_bluebooks).each do |package|
            chapter_name = Naming.pascal(package)
            next if hecksagon(chapter_name)

            raise WiringError,
                  "#{hexagon.domain} attaches vendored bluebook #{package.inspect} " \
                  "(bounded context #{chapter_name}) but never declared " \
                  "Hecks.hecksagon #{chapter_name.inspect} — put that sibling " \
                  "(and any `translates` ACL) in context_map.hecksagon; " \
                  "same-name blocks merge, order-independent."
          end
        end

        # `uses_framework` and `attaches` load a bounded context; the consumer must declare the
        # sibling hecksagon that is its ACL (Governance/Identity/Privacy already do).
        def refuse_unwired_framework_members!(hexagon)
          hexagon.member_chapters.each do |member|
            next if hecksagon(member)

            raise WiringError,
                  "#{hexagon.domain} attaches #{member.inspect} " \
                  "(bounded context) but never declared Hecks.hecksagon " \
                  "#{member.inspect} — put that sibling (and any `translates` " \
                  "ACL) in context_map.hecksagon; same-name blocks merge, " \
                  "order-independent."
          end
        end

        # An explicit `bounded` mark on a consumer chapter always needs an ACL. `uses_framework`
        # / `uses_embryonaut_bluebook` mark the attached chapter bounded and require the sibling
        # hecksagon above; they don't require a `translates` on it unless the consumer also
        # wrote `bounded`.
        # rust/host Google sign-in reads ir.json's membership/identity keys, never a deploy-time
        # env var; Membership without Identity means provision cannot Register/Link an identity.
        def refuse_membership_without_identity!
          return unless @bluebooks.values.any? { |chapter| chapter.provides?(Bluebook::Capabilities::MEMBERSHIP) }
          return if @bluebooks.values.any? { |chapter| chapter.provides?(Bluebook::Capabilities::IDENTITY) }

          raise WiringError,
                "a chapter that provides \"membership\" is loaded, but none provides " \
                "\"identity\" — rust/host Google sign-in cannot register or link an " \
                "identity from the hecksagon/world. Attach Identity (`uses_framework " \
                "\"Identity\"` plus a sibling Hecks.hecksagon \"Identity\") so the " \
                "identity verbs are exported onto ir.json, not guessed at deploy."
        end

        # A hecksagon attaches after its chapter builds, so this is the first point a
        # declared `:port_operation` capability can be checked against it.
        def refuse_unresolved_port_operations!
          @bluebooks.each_value do |chapter|
            chapter.provides.each do |row|
              next unless Bluebook::Capabilities::CONTRACTS.dig(row.capability, row.key.to_sym) == :port_operation
              next if port_operation_declared?(chapter, row.verb)

              raise WiringError,
                    "#{chapter.name} provides #{row.capability.inspect} #{row.key}: #{row.verb.inspect}, " \
                    "but its hecksagon declares no such port operation — declare it with " \
                    "`#{chapter.name}::Aggregate.port \"Port\" do operation \"Operation\" ... end`."
            end
          end
        end

        # A query is answered from the aggregate's stored records or from outside the domain, and
        # the bluebook only ever says which records. One that takes arguments but filters, orders
        # and bounds nothing reads none of them, so only an outside answer could use them: unless
        # the hecksagon binds it to a port it is refused. (A query with no arguments and no clause
        # is the plain list of every record, and stays one.) A binding on a query that also
        # filters records says two things, and one must name a query its aggregate declares, once.
        def refuse_unanswerable_queries!
          @bluebooks.each_value do |chapter|
            chapter.aggregates.each do |aggregate|
              bound = refuse_misbound_queries!(chapter, aggregate)

              aggregate.queries.each do |query|
                next if bound.include?(query.hecks_name) || filters_records?(query) || query.attributes.empty?

                raise WiringError,
                      "#{chapter.name}::#{aggregate.hecks_name}.#{query.hecks_name} declares no where " \
                      "and no hecksagon binds it — its arguments (#{query.attributes.map(&:name).join(', ')}) " \
                      "select nothing, so no one can answer it. Add a where, or bind it in the " \
                      "hecksagon: `#{chapter.name}::#{aggregate.hecks_name}.port \"Port\" do " \
                      "answers_query \"#{query.hecks_name}\", shape: :text end`."
              end
            end
          end
        end

        # The bound names of `aggregate`'s queries, refusing a binding that names no query, names
        # one twice, or names one that also filters stored records.
        def refuse_misbound_queries!(chapter, aggregate)
          bound = []
          aggregate.ports.each do |port|
            port.answered_queries.each do |answer|
              query = aggregate.query(answer.name)
              where = "#{chapter.name}::#{aggregate.hecks_name}.#{answer.name}"
              raise WiringError, "the #{port.name} port binds #{where}, which the aggregate does not declare" unless query
              raise WiringError, "#{where} is bound by more than one port" if bound.include?(answer.name)
              if filters_records?(query)
                raise WiringError, "#{where} is bound to the #{port.name} port but also declares where, " \
                                   "order_by or limit over stored records — a query is answered from " \
                                   "records or from outside, not both"
              end

              bound << answer.name
            end
          end
          bound
        end

        # A query that says anything about which stored records it wants.
        def filters_records?(query)
          !(query.wheres.empty? && query.order_by.nil? && query.limit.nil? && query.offset.nil?)
        end

        def port_operation_declared?(chapter, verb)
          aggregate_name, port_name, operation_name = verb.split(".", 3)
          ports = chapter.aggregate(aggregate_name)&.ports || []
          ports.any? { |port| port.name == port_name && port.operations.any? { |op| op.hecks_name == operation_name } }
        end

        def refuse_bounded_without_acl!(hexagon)
          return unless hexagon.bounded?
          return if hexagon.translates.any?

          raise WiringError,
                "#{hexagon.domain} is marked bounded but never declared a " \
                "translates ACL — a bounded chapter wraps in its own module and " \
                "cross-context field mapping lives on the hecksagon, not in " \
                "rust/host and not as a field list on the bluebook. " \
                "Add `translates \"Name\" do on Foreign::Event; trigger Local::Command, " \
                "with: { ... } end` (any field) or drop `bounded`."
        end

        # Derived from whichever framework members actually declare `provides
        # "authorization"` — never a hardcoded name.
        def authorization_attachment_hint
          providers = Framework.providers_of(Bluebook::Capabilities::AUTHORIZATION)
          return "attaches a chapter that provides \"authorization\" (no framework member declares one)" if providers.empty?

          providers.map { |name| "uses_framework #{name.inspect}" }.join(" or ")
        end

        # Every command this domain declares, an aggregate's own and every entity nested
        # inside one — the same reach dispatch-time role checking needs.
        def commands_in(bluebook_ir)
          bluebook_ir.aggregates.flat_map { |aggregate| aggregate.commands + aggregate.entities.flat_map(&:commands) }
        end

        # Two packages can share a chapter name by coincidence (found live: a stale
        # vendor/hecksagain fork of Governance/Identity/Deploy, still on 4 apps' load
        # paths). Intentional accumulation (several files declaring the same chapter on
        # purpose) is distinguished by package root, not file identity, and is left
        # untouched here — checked once, after every file has loaded.
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

        # The nearest boundary a path belongs to: a real gemspec, or a bare `vendor/`
        # component (vendored code is never "the same package" as what vendors it).
        # Falls back to the path's own directory when neither is found.
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

        # A domain with policies/a process_manager but no outbox on its bound adapter
        # (`AppendOnly#outbox?`) runs reactions inline — lost on a crash between a
        # commit and its reaction. A warning, not a refusal: Memory has an in-process
        # outbox, so dev/test stays quiet, but file/remote adapters need this to be loud.
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

        # A warning, not a refusal: running sagas on a store with no `save_saga` is
        # legitimate on purpose in a fast in-memory test/dev boot.
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
