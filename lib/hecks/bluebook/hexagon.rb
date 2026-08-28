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
      def aggregate_name = Naming.demodulise(aggregate)
    end

    class Hecksagon
      include Hecks::IR
      include Behaviour::Hecksagon

      emits_ir(
        domain:             :domain,
        binds:              many(:binds),
        subscriptions:      -> { subscriptions.map(&:to_s) },
        framework_members:  -> { framework_members.map(&:to_s) },
        vendored_bluebooks: -> { vendored_bluebooks.map(&:to_s) }
      )

      attr_reader :domain, :binds, :subscriptions, :framework_members, :vendored_bluebooks

      def initialize(domain:, binds: [], subscriptions: [], framework_members: [], vendored_bluebooks: [])
        @domain             = domain.to_s
        @binds              = binds
        @subscriptions      = subscriptions
        @framework_members  = framework_members
        @vendored_bluebooks = vendored_bluebooks
      end
    end

    class World
      include Hecks::IR
      include Behaviour::World

      emits_ir(domain: :domain, realm: :realm, latest: :latest, settings: :settings)

      attr_reader :domain, :realm, :latest, :settings

      def initialize(domain:, realm: nil, latest: nil, settings: {})
        @domain   = domain.to_s
        @realm    = realm&.to_s
        @latest   = latest&.to_s
        @settings = settings
      end
    end
  end
end
