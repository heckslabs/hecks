require_relative "behaviour/hexagon"
require_relative "../ir"

module Hecksagain
  module Bluebook
    Port = Struct.new(:name, :verb, :signal, keyword_init: true) do
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
      include Hecksagain::IR
      include Behaviour::Hecksagon

      emits_ir(
        domain:            :domain,
        binds:             many(:binds),
        subscriptions:     -> { subscriptions.map(&:to_s) },
        framework_members: -> { framework_members.map(&:to_s) }
      )

      attr_reader :domain, :binds, :subscriptions, :framework_members

      def initialize(domain:, binds: [], subscriptions: [], framework_members: [])
        @domain             = domain.to_s
        @binds              = binds
        @subscriptions      = subscriptions
        @framework_members  = framework_members
      end


    end

    class World
      include Hecksagain::IR
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
