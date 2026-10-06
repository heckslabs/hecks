require_relative "behaviour/hexagon"
require_relative "keyword_fields"
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

    # One chapter a hecksagon attaches, with where it was found.
    #
    # `source` is `:gem` for a chapter the gem carries (a framework member such as Governance,
    # or a language chapter such as Deploy) and `:vendor` for a package vendored into the
    # consuming project, whose `name` is the package's directory name (`"membership"`).
    Attachment = Struct.new(:name, :source, keyword_init: true) do
      # @return [Boolean] whether the chapter is a vendored package
      def vendor? = source == :vendor

      # @return [String] the chapter's name in the registry: a gem chapter's own name, a
      #   vendored package's directory name in Pascal case
      def chapter_name = vendor? ? Naming.pascal(name) : name

      # @return [Hash{Symbol => String}] the attachment as plain data
      def to_h = { name: name.to_s, source: source.to_s }
    end

    # The built form of a `.hecksagon` file, produced by `DSL::HecksagonBuilder`.
    # `Behaviour::Hecksagon` supplies the bind lookups; this class holds the declared data.
    class Hecksagon
      include Hecks::IR
      include Behaviour::Hecksagon

      emits_ir(
        domain:        :domain,
        binds:         many(:binds),
        subscriptions: -> { subscriptions.map(&:to_s) },
        attachments:   -> { attachments.map(&:to_h) },
        bounded:       :bounded?,
        translates:    -> { translates.map(&:to_s) }
      )

      attr_reader :domain, :binds, :subscriptions, :attachments, :translates

      # Every optional keyword and what it holds when the declaration omits it.
      FIELD_DEFAULTS = {
        binds: [], subscriptions: [], attachments: [], bounded: false, translates: []
      }.freeze

      # @param domain [String, Symbol] the domain this hecksagon wires
      # @param binds [Array<Bluebook::Bind>] the declared adapter binds
      # @param subscriptions [Array<String, Symbol>] the external events this domain
      #   subscribes to
      # @param attachments [Array<Bluebook::Attachment>] every chapter this hecksagon attaches,
      #   each with its source (`:gem` or `:vendor`)
      # @param bounded [Boolean] whether this chapter is an explicit bounded context
      #   (consumer-owned; `attaches` marks attached chapters bounded on the registry instead)
      # @param translates [Array<String>] names of `translates` ACL blocks declared here
      def initialize(domain:, **given)
        KeywordFields.assign(self, KeywordFields.fill(given, FIELD_DEFAULTS))
        @domain             = domain.to_s
        @bounded            = @bounded ? true : false
        @translates         = Array(@translates).map(&:to_s)
      end

      # Says whether this hecksagon marked its own chapter `bounded`.
      #
      # @return [Boolean] whether `bounded` was declared on this block
      def bounded? = @bounded

      # Every chapter this hecksagon brings into its domain's registry, gem and vendored alike.
      #
      # @return [Array<String>] the chapters' names as the registry holds them, in the order
      #   they were attached
      def member_chapters = attachments.map(&:chapter_name)

      # Says whether this hecksagon attaches a chapter, whatever its source.
      #
      # @param chapter [String, Symbol] a chapter's name as the registry holds it
      # @return [Boolean] whether that chapter is attached here
      def attaches?(chapter) = member_chapters.include?(chapter.to_s)

      # The vendored packages this hecksagon attaches.
      #
      # @return [Array<String>] their directory names, in the order they were attached
      def vendored_packages = attachments.select(&:vendor?).map { |attachment| attachment.name.to_s }
    end

    # The built form of a `.world` file, produced by `DSL::WorldBuilder`.
    # `Behaviour::World` supplies the settings lookups; this class holds the declared data.
    class World
      include Hecks::IR
      include Behaviour::World

      emits_ir(domain: :domain, realm: :realm, latest: :latest, settings: :settings,
               default_database: :default_database, default_adapter: :default_adapter)

      attr_reader :domain, :realm, :latest, :settings, :default_database, :default_adapter

      # Every optional keyword and what it holds when the declaration omits it.
      FIELD_DEFAULTS = {
        realm: nil, latest: nil, settings: {}, default_database: nil, default_adapter: nil
      }.freeze

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
      def initialize(domain:, **given)
        KeywordFields.assign(self, KeywordFields.fill(given, FIELD_DEFAULTS))
        @domain           = domain.to_s
        @realm            = @realm&.to_s
        @latest           = @latest&.to_s
        @default_database = @default_database&.to_s
        @default_adapter  = @default_adapter&.to_s
      end
    end
  end
end
