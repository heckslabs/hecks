require "hecks/vocabulary"
require_relative "keyword_fields"
require_relative "model_check/client_profile"
require_relative "model_check/lifecycle_checks"
require_relative "model_check/saga_checks"
require_relative "model_check/policy_checks"
require_relative "model_check/ask_checks"
require_relative "model_check/verbs"

module Hecks
  module Bluebook
    # Static formal checks over the assembled bluebook IR: lifecycles as state
    # machines, process managers as protocols, checked as data without booting a runtime.
    module ModelCheck
      Finding = Struct.new(:kind, :severity, :subject, :message, keyword_init: true) do
        def to_s = "#{severity.to_s.upcase.ljust(7)} #{kind.to_s.ljust(20)} #{subject}  —  #{message}"
      end

      # Findings a domain deliberately allows, enforced in both directions by
      # spec/model_check_spec.rb: an error this checker reports but isn't listed
      # here is a regression; an entry listed but never reported is stale. Pinned
      # empty — a domain's own allowance belongs on its own declaration. (ADR 0025)
      ALLOWED_FINDINGS = {}.freeze

      # The profiles `call` accepts; `nil` is the default, unprofiled run.
      PROFILES = %i[client].freeze

      # What `call` takes from one corpus scan besides the chapter, and each key's default.
      CONTEXT_DEFAULTS = {
        hecksagon: nil, known_domains: nil, global_emitted_events: nil, rust_target: false, strict: false
      }.freeze

      extend LifecycleChecks
      extend SagaChecks
      extend PolicyChecks
      extend AskChecks
      extend Verbs

      module_function

      # Runs every static model check over `bluebook` and returns what it finds.
      #
      # @param bluebook [Bluebook::Chapter] the assembled chapter to check
      # @param profile [Symbol, nil] :client adds ClientProfile's error findings
      # @param context [Hash] the rest of what one corpus scan knows, each key optional:
      #   `hecksagon` (this bluebook's own sibling wiring file, if the caller loaded one),
      #   `known_domains` (every bluebook/hecksagon name booted anywhere in this corpus scan,
      #   checked to catch a typo'd across/attaches target), `global_emitted_events` (every
      #   event emitted anywhere in the corpus, checked as a fallback so a translates reaction
      #   isn't flagged deaf), `rust_target` and `strict` (see `rust_reserved_name_findings`)
      # @return [Array<Finding>] every finding this bluebook triggers
      # @raise [ArgumentError] if profile is neither nil nor :client, or a context key is unknown
      def call(bluebook, profile: nil, **context)
        unless profile.nil? || PROFILES.include?(profile)
          raise ArgumentError, "unknown profile #{profile.inspect} (known: #{PROFILES.inspect})"
        end

        options  = KeywordFields.fill(context, CONTEXT_DEFAULTS)
        findings = [*modelled_findings(bluebook, options), *target_findings(bluebook, options)]
        findings.concat(ClientProfile.call(bluebook, hecksagon: options[:hecksagon])) if profile == :client
        findings
      end

      # Lifecycles, sagas and policies: what the model says about itself.
      def modelled_findings(bluebook, options)
        [
          *bluebook.aggregates.flat_map { |aggregate| aggregate_lifecycle_findings(aggregate) },
          *bluebook.process_managers.flat_map { |process_manager| saga_findings(bluebook, process_manager) },
          *bluebook.policies.flat_map do |policy|
            policy_findings(bluebook, policy, options[:hecksagon], options[:known_domains],
                            options[:global_emitted_events])
          end,
          *unused_ask_findings(bluebook)
        ]
      end

      # Names and queries a Rust target would not accept.
      def target_findings(bluebook, options)
        [
          *rust_reserved_name_findings(domain_name: bluebook.name,
                                       aggregate_names: bluebook.aggregates.map(&:hecks_name),
                                       rust_target: options[:rust_target], strict: options[:strict]),
          *external_query_findings(bluebook, rust_target: options[:rust_target])
        ]
      end

      # @return [Array<Finding>] the aggregate's own lifecycle findings, then each entity's
      def aggregate_lifecycle_findings(aggregate)
        lifecycle_findings(aggregate, aggregate) +
          aggregate.entities.flat_map { |entity| lifecycle_findings(aggregate, entity) }
      end

      # Flags a query the hecksagon binds to a port's adapter. Only the Ruby runtime asks an
      # adapter for an answer; a Rust host would find nothing behind the query.
      #
      # @param bluebook [Bluebook::Chapter] the assembled chapter, its hecksagon's ports attached
      # @param rust_target [Boolean] whether this domain has a real Rust target; a domain without
      #   one is not checked, since nothing but the Ruby runtime serves it
      # @return [Array<Finding>] one :external_query error per bound query, none off a Rust target
      def external_query_findings(bluebook, rust_target: false)
        return [] unless rust_target

        bluebook.aggregates.flat_map do |aggregate|
          aggregate.ports.flat_map do |port|
            port.answered_queries.map { |answer| external_query_finding(aggregate, port, answer) }
          end
        end
      end

      def external_query_finding(aggregate, port, answer)
        Finding.new(kind: :external_query, severity: :error,
                    subject: "#{aggregate.hecks_name}.#{answer.name}",
                    message: "the #{port.name} port's adapter answers this query, and only the Ruby " \
                             "runtime asks an adapter — the Rust host cannot serve it")
      end

      # Flags an aggregate or domain name that collides with a Rust keyword or reserved
      # Cargo key — both become bare module identifiers with no `r#` escape hatch.
      #
      # @param domain_name [String, Symbol, nil] the domain's own name, or nil to skip
      #   the domain-level check
      # @param aggregate_names [Array<String, Symbol>] every aggregate name to check
      # @param rust_target [Boolean] raises severity to error when this domain has a
      #   real Rust target
      # @param strict [Boolean] raises severity to error regardless of rust_target
      # @return [Array<Finding>] one :rust_reserved_name finding per colliding name
      def rust_reserved_name_findings(domain_name: nil, aggregate_names: [], rust_target: false, strict: false)
        severity = rust_target || strict ? :error : :warning
        keywords = Hecks::Vocabulary.fetch("RustReservedWord")

        findings = aggregate_names.filter_map { |name| reserved_aggregate_finding(name, keywords, severity) }
        findings.concat(domain_reserved_name_findings(domain_name, keywords, severity)) if domain_name
        findings
      end

      # @return [Finding, nil] the finding for an aggregate whose Rust module is a keyword
      def reserved_aggregate_finding(name, keywords, severity)
        module_name = rust_module_name(name)
        return unless keywords.include?(module_name)

        Finding.new(kind: :rust_reserved_name, severity: severity, subject: name.to_s,
                    message: "the aggregate's Rust module `#{module_name}` is a Rust keyword (RustReservedWord) — " \
                             "`pub mod #{module_name};` has no raw-identifier escape; rename the aggregate")
      end

      # The domain-level half of rust_reserved_name_findings — same tables, one name.
      def domain_reserved_name_findings(domain_name, keywords, severity)
        module_name = rust_module_name(domain_name)
        table = if keywords.include?(module_name)
                  "a Rust keyword (RustReservedWord)"
                elsif Hecks::Vocabulary.fetch("CargoReservedName").include?(module_name)
                  "a reserved Cargo.toml key (CargoReservedName)"
                end
        return [] unless table

        [Finding.new(kind: :rust_reserved_name, severity: severity, subject: domain_name.to_s,
                     message: "the domain's Rust module and Cargo feature `#{module_name}` is #{table} — " \
                              "rename the domain")]
      end

      def rust_module_name(name) = name.to_s.downcase
    end
  end
end
