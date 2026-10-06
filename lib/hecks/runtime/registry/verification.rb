require_relative "../../bluebook/hecksagon"
require_relative "hecksagon_rules"
require_relative "query_verification"
require_relative "chapter_verification"
require_relative "durability_warnings"

module Hecks
  module Runtime
    class Registry
      # The wiring gate: every bind names a declared aggregate, every adapter satisfies its
      # port's verb, and every world default is usable. `verify!` runs it all at boot.
      module Verification
        include HecksagonRules
        include QueryVerification
        include ChapterVerification
        include DurabilityWarnings

        # Runs every wiring check against this registry's loaded bluebooks, hecksagons, ports
        # and adapters.
        def verify!
          verify_default_adapter!
          verify_world_defaults!
          verify_singleton_port_answers!
          refuse_cross_package_bluebook_merge!
          refuse_reserved_chapter_names!
          refuse_membership_without_identity!
          refuse_unresolved_port_operations!
          refuse_unanswerable_queries!

          @declared.hecksagons.each_value { |hecksagon| verify_hecksagon!(hecksagon) }
          self
        end

        # Checks that the framework-wide default persistence adapter is itself wired correctly.
        def verify_default_adapter!
          name = Ports::Persistence::DEFAULT_ADAPTER

          check_verb(Bluebook::Bind.new(aggregate: "(default)", verb: Ports::Persistence::VERB, adapter: name))
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
                "#{missing.map(&:inspect).join(", ")} — #{port.name}.port declares answers " \
                "#{answers.map(&:inspect).join(", ")}"
        end

        # persistence/projection/loading are per-aggregate bound and already checked via
        # each bind above; a singleton port is never bound to an aggregate at all.
        PER_AGGREGATE_PORTS = %w[persistence projection loading].freeze

        # Checks every singleton port with exactly one wired adapter against its own
        # declared `answers` methods.
        def verify_singleton_port_answers!
          @declared.ports.each_value { |port| check_singleton_port!(port) }
          self
        end

        def check_singleton_port!(port)
          return if PER_AGGREGATE_PORTS.include?(port.name) || Array(port.answers).empty?

          implementations = @declared.adapters.values.select { |a| a.port == port.name }
          check_answers(port, implementations.first.name) if implementations.size == 1
        end

        # Checks that every setting `settings` declares (besides `:adapter`) is a field
        # `bind`'s adapter actually admits.
        def check_settings(bind, settings)
          adapter = @declared.adapters[bind.adapter]
          return unless adapter

          declared = settings.keys - [:adapter]
          unknown  = declared.reject { |field| adapter.declares?(field) }
          return if unknown.empty?

          raise WiringError,
                "#{bind.adapter} does not declare #{unknown.map(&:inspect).join(", ")} — " \
                "it declares #{adapter.all_fields.map(&:inspect).join(", ")}. " \
                "Add the field to the adapter, or remove it from the world."
        end

        def port_for(bind)
          adapter = @declared.adapters[bind.adapter]
          raise WiringError, "unknown adapter #{bind.adapter.inspect}" unless adapter

          @declared.ports[adapter.port] ||
            raise(WiringError, "adapter #{bind.adapter} declares unknown port #{adapter.port.inspect}")
        end

        def adapter_class(name)
          Adapters.const_get(name)
        rescue NameError
          raise WiringError, "no Ruby adapter implementation for #{name.inspect} " \
                             "(expected Hecks::Adapters::#{name})"
        end

        private

        # One hecksagon's checks: its roles, attachments and ACL, every bind, and the durability
        # warnings for its chapter.
        def verify_hecksagon!(hecksagon)
          refuse_ungoverned_roles!(hecksagon)
          refuse_unwired_attachments!(hecksagon)
          refuse_bounded_without_acl!(hecksagon)
          hecksagon.binds.each { |bind| verify_bind!(hecksagon, bind) }
          warn_undurable_sagas!(hecksagon)
          warn_undurable_outbox!(hecksagon)
        end

        def verify_bind!(hecksagon, bind)
          # A domain-level default (§0) names no aggregate of its own; still validate its
          # adapter/verb shape. Real aggregates resolving through it are covered by their
          # own dispatch-time `BindingPolicy.resolve`, not required to be exhaustive here.
          return check_verb(bind) if bind.aggregate.nil?

          aggregate = bluebook(hecksagon.domain)&.aggregate(bind.aggregate_name)
          raise WiringError, "#{bind.aggregate} is bound but not declared in the bluebook" unless aggregate

          check_verb(bind)

          repository(hecksagon.domain, aggregate)
        end
      end
    end
  end
end
