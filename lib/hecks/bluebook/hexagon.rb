require_relative "behaviour/hexagon"
require_relative "../ir"

module Hecks
  module Bluebook
    Port = Struct.new(:name, :verb, :signal, :answers, keyword_init: true) do
      def reply?  = signal == :reply

      def effect? = signal == :effect
    end

    Adapter = Struct.new(:name, :port, :fields, :secrets, keyword_init: true) do
      def declares?(field) = all_fields.include?(field.to_sym)

      def all_fields = (fields || []) + (secrets || [])
    end

    Bind = Struct.new(:aggregate, :verb, :adapter, :role, keyword_init: true) do
      # Empty for a domain-level default bind with no aggregate.
      def aggregate_name = Naming.demodulise(aggregate)
    end

    # The built form of a `.hecksagon` file, produced by `DSL::HecksagonBuilder`.
    # `Behaviour::Hecksagon` supplies the bind lookups; this class holds the declared data.
    class Hecksagon
      include Hecks::IR
      include Behaviour::Hecksagon

      emits_ir(
        domain:             :domain,
        binds:              many(:binds),
        subscriptions:      -> { subscriptions.map(&:to_s) },
        framework_members:  -> { framework_members.map(&:to_s) },
        vendored_bluebooks: -> { vendored_bluebooks.map(&:to_s) },
        attached_chapters:  -> { attached_chapters.map(&:to_s) },
        bounded:            :bounded?,
        translates:         -> { translates.map(&:to_s) }
      )

      attr_reader :domain, :binds, :subscriptions, :framework_members, :vendored_bluebooks,
                  :attached_chapters, :translates

      # @param domain [String, Symbol] the domain this hecksagon wires
      # @param binds [Array<Bluebook::Bind>] the declared adapter binds
      # @param subscriptions [Array<String, Symbol>] the external events this domain
      #   subscribes to
      # @param framework_members [Array<String, Symbol>] framework members (`Governance`, ...) attached
      # @param vendored_bluebooks [Array<String, Symbol>] the vendored embryonaut
      #   bluebook package names this domain attaches
      # @param attached_chapters [Array<String, Symbol>] chapters the gem carries, attached by name
      # @param bounded [Boolean] whether this chapter is an explicit bounded context
      #   (consumer-owned; `uses_framework` / `uses_embryonaut_bluebook` mark
      #   attached chapters bounded on the registry instead)
      # @param translates [Array<String>] names of `translates` ACL blocks declared here
      def initialize(domain:, binds: [], subscriptions: [], framework_members: [],
                     vendored_bluebooks: [], attached_chapters: [], bounded: false, translates: [])
        @domain             = domain.to_s
        @binds              = binds
        @subscriptions      = subscriptions
        @framework_members  = framework_members
        @vendored_bluebooks = vendored_bluebooks
        @attached_chapters  = attached_chapters
        @bounded            = bounded ? true : false
        @translates         = Array(translates).map(&:to_s)
      end

      # Says whether this hecksagon marked its own chapter `bounded`.
      #
      # @return [Boolean] whether `bounded` was declared on this block
      def bounded? = @bounded

      # Every chapter this hecksagon brings into its domain's registry: framework members and
      # attached chapters alike, which resolve the same way.
      #
      # @return [Array<String>] the chapters' names, framework members first
      def member_chapters = (framework_members + attached_chapters).map(&:to_s)
    end

    # The built form of a `.world` file, produced by `DSL::WorldBuilder`.
    # `Behaviour::World` supplies the settings lookups; this class holds the declared data.
    class World
      include Hecks::IR
      include Behaviour::World

      emits_ir(domain: :domain, realm: :realm, latest: :latest, settings: :settings,
               default_database: :default_database, default_adapter: :default_adapter)

      attr_reader :domain, :realm, :latest, :settings, :default_database, :default_adapter

      # @param domain [String, Symbol] the domain this world configures
      # @param realm [String, Symbol, nil] the declared realm/version marker, or `nil`
      #   if none is declared
      # @param latest [String, Symbol, nil] the declared latest-version marker, or `nil`
      #   if none is declared
      # @param settings [Hash] the declared adapter bind settings, keyed by verb and,
      #   for a qualified entry, `"verb:adapter"`
      # @param default_database [String, nil] the connection every chapter's
      #   database-taking persistence adapter uses unless its own settings name one,
      #   or `nil` if none is declared
      # @param default_adapter [String, nil] the persistence adapter every aggregate
      #   binds to unless its chapter's hecksagon binds it, or `nil` if none is declared
      def initialize(domain:, realm: nil, latest: nil, settings: {}, default_database: nil, default_adapter: nil)
        @domain           = domain.to_s
        @realm            = realm&.to_s
        @latest           = latest&.to_s
        @settings         = settings
        @default_database = default_database&.to_s
        @default_adapter  = default_adapter&.to_s
      end
    end
  end
end
