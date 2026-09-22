require_relative "behaviour/hexagon"
require_relative "../ir"

module Hecks
  module Bluebook
    Port = Struct.new(:name, :verb, :signal, :answers, keyword_init: true) do
      # Says whether this port answers its verb with a return value.
      #
      # @return [Boolean] whether `signal` is `:reply`
      def reply?  = signal == :reply

      # Says whether this port answers its verb by taking effect, with no return value.
      #
      # @return [Boolean] whether `signal` is `:effect`
      def effect? = signal == :effect
    end

    Adapter = Struct.new(:name, :port, :fields, :secrets, keyword_init: true) do
      # Says whether this adapter declares a field, plain or secret.
      #
      # @param field [Symbol, String] the field to check
      # @return [Boolean] whether `field` is one of this adapter's own `fields` or `secrets`
      def declares?(field) = all_fields.include?(field.to_sym)

      # Lists every field this adapter declares, plain and secret alike.
      #
      # @return [Array<Symbol>] every field this adapter declares, `fields` and `secrets`
      #   combined
      def all_fields = (fields || []) + (secrets || [])
    end

    Bind = Struct.new(:aggregate, :verb, :adapter, :role, keyword_init: true) do
      # Names the aggregate this bind applies to.
      #
      # @return [String] this bind's aggregate name, demodulised, or `""` for a
      #   domain-level default bind with no aggregate
      def aggregate_name = Naming.demodulise(aggregate)
    end

    # The built form of a `.hecksagon` file, produced by
    # `DSL::HecksagonBuilder` — a domain's own binds (`Bind`, above),
    # subscriptions, and attached framework/vendored members.
    # `Behaviour::Hecksagon` supplies the bind lookups (`bind_for`/
    # `binds_for`); this class holds only the declared data.
    class Hecksagon
      include Hecks::IR
      include Behaviour::Hecksagon

      emits_ir(
        domain:             :domain,
        binds:              many(:binds),
        subscriptions:      -> { subscriptions.map(&:to_s) },
        framework_members:  -> { framework_members.map(&:to_s) },
        vendored_bluebooks: -> { vendored_bluebooks.map(&:to_s) },
        bounded:            :bounded,
        translates:         -> { translates.map(&:to_s) }
      )

      attr_reader :domain, :binds, :subscriptions, :framework_members, :vendored_bluebooks,
                  :translates

      # @param domain [String, Symbol] the domain this hecksagon wires
      # @param binds [Array<Bluebook::Bind>] the declared adapter binds
      # @param subscriptions [Array<String, Symbol>] the external events this domain
      #   subscribes to
      # @param framework_members [Array<String, Symbol>] the framework members
      #   (`Governance`, `Identity`, ...) this domain attaches
      # @param vendored_bluebooks [Array<String, Symbol>] the vendored embryonaut
      #   bluebook package names this domain attaches
      # @param bounded [Boolean] whether this chapter is an explicit bounded context
      #   (consumer-owned; `uses_framework` / `uses_embryonaut_bluebook` mark
      #   attached chapters bounded on the registry instead)
      # @param translates [Array<String>] names of `translates` ACL blocks declared here
      def initialize(domain:, binds: [], subscriptions: [], framework_members: [],
                     vendored_bluebooks: [], bounded: false, translates: [])
        @domain             = domain.to_s
        @binds              = binds
        @subscriptions      = subscriptions
        @framework_members  = framework_members
        @vendored_bluebooks = vendored_bluebooks
        @bounded            = bounded ? true : false
        @translates         = Array(translates).map(&:to_s)
      end

      # Says whether this hecksagon marked its own chapter `bounded`.
      #
      # @return [Boolean] whether `bounded` was declared on this block
      def bounded? = @bounded
    end

    # The built form of a `.world` file, produced by `DSL::WorldBuilder` —
    # a domain's own `realm`/`latest` version markers and its adapter bind
    # settings (as opposed to `Hecksagon`'s own bind list, above).
    # `Behaviour::World` supplies the settings lookups (`for_verb`/
    # `for_binding`); this class holds only the declared data.
    class World
      include Hecks::IR
      include Behaviour::World

      emits_ir(domain: :domain, realm: :realm, latest: :latest, settings: :settings)

      attr_reader :domain, :realm, :latest, :settings

      # @param domain [String, Symbol] the domain this world configures
      # @param realm [String, Symbol, nil] the declared realm/version marker, or `nil`
      #   if none is declared
      # @param latest [String, Symbol, nil] the declared latest-version marker, or `nil`
      #   if none is declared
      # @param settings [Hash] the declared adapter bind settings, keyed by verb and,
      #   for a qualified entry, `"verb:adapter"`
      def initialize(domain:, realm: nil, latest: nil, settings: {})
        @domain   = domain.to_s
        @realm    = realm&.to_s
        @latest   = latest&.to_s
        @settings = settings
      end
    end
  end
end
