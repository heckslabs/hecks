require_relative "behaviour/hecksagon"
require_relative "keyword_fields"
require_relative "../ir"

module Hecks
  module Bluebook
    Port = Struct.new(:name, :verb, :signal, :answers, keyword_init: true) do
      def reply?  = signal == :reply

      def effect? = signal == :effect
    end

    # One `.adapter`: the port it implements, the settings a world may give it, and the secrets.
    # `defaults` maps a field's name to the value used when the world gives none; a string may hold
    # a `{name}` or `{storage_name}` placeholder, filled from the aggregate the adapter is built
    # for.
    #
    # A plugin adapter instead `runs` a `.wasm` module beside its `.adapter` file (`source_dir`)
    # and names the queries it `answers` (`"Bluebook::Aggregate.Query"`); it needs no port, and the
    # runtime binds each query it answers without a hecksagon line.
    #
    # `provides` names what the adapter can do beyond its port's contract, such as
    # `"set_transform"`; a caller asks before relying on it.
    Adapter = Struct.new(:name, :port, :fields, :secrets, :defaults, :answers, :runs, :provides, :source_dir,
                         keyword_init: true) do
      def declares?(field) = all_fields.include?(field.to_sym)

      def all_fields = (fields || []) + (secrets || [])

      # @return [Hash{Symbol => Object}] the declared defaults, empty when none
      def declared_defaults = defaults || {}

      # @return [Array<String>] the qualified queries this adapter answers, empty when none
      def answered_queries = answers || []

      # @return [Array<String>] the capabilities this adapter provides, empty when none
      def capabilities = provides || []

      # @param capability [String, Symbol] a capability's name, such as `"set_transform"`
      # @return [Boolean] whether this adapter declares `provides` for it
      def provides?(capability) = capabilities.include?(capability.to_s)

      # @return [Boolean] whether this adapter is a wasm plugin
      def plugin? = !runs.nil?

      # @return [String, nil] where the plugin's module is, beside its `.adapter` file
      def plugin_path = runs && File.expand_path(runs, source_dir || Dir.pwd)
    end

    Bind = Struct.new(:aggregate, :verb, :adapter, :role, keyword_init: true) do
      # Empty for a domain-level default bind with no aggregate.
      def aggregate_name = Naming.demodulise(aggregate)
    end

    # One bluebook a hecksagon attaches, with where it was found.
    #
    # `source` is `:gem` for a bluebook the gem carries (a framework member such as Governance,
    # or a language bluebook such as Deploy) and `:vendor` for a package vendored into the
    # consuming project, whose `name` is the package's directory name (`"membership"`) and whose
    # `bluebook` is the name its bluebook declares, which the directory name need not spell.
    Attachment = Struct.new(:name, :source, :declaration, keyword_init: true) do
      # @return [Boolean] whether the bluebook is a vendored package
      def vendor? = source == :vendor

      # @return [String] the bluebook's name in the registry: a gem bluebook's own name, a
      #   vendored package's declared bluebook, else its directory name in Pascal case
      def declaration_name = declaration || (vendor? ? Naming.pascal(name) : name)

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
        driving:       -> { driving.map(&:to_s) },
        bounded:       :bounded?,
        translates:    -> { translates.map(&:to_s) }
      )

      attr_reader :domain, :binds, :subscriptions, :attachments, :translates, :driving

      # The driving adapters `driven_by` can name.
      DRIVING_ADAPTERS = %w[Ruby Cli Json Mcp Web].freeze

      # Every optional keyword and what it holds when the declaration omits it.
      FIELD_DEFAULTS = {
        binds: [], subscriptions: [], attachments: [], bounded: false, translates: [], driving: []
      }.freeze

      # @param domain [String, Symbol] the domain this hecksagon wires
      # @param binds [Array<Bluebook::Bind>] the declared adapter binds
      # @param subscriptions [Array<String, Symbol>] the external events this domain
      #   subscribes to
      # @param attachments [Array<Bluebook::Attachment>] every bluebook this hecksagon attaches,
      #   each with its source (`:gem` or `:vendor`)
      # @param bounded [Boolean] whether this bluebook is an explicit bounded context
      #   (consumer-owned; `attaches` marks attached bluebooks bounded on the registry instead)
      # @param translates [Array<String>] names of `translates` ACL blocks declared here
      # @param driving [Array<String>] the driving adapters `driven_by` admits; empty admits all
      def initialize(domain:, **given)
        KeywordFields.assign(self, KeywordFields.fill(given, FIELD_DEFAULTS))
        @domain             = domain.to_s
        @bounded            = @bounded ? true : false
        @translates         = Array(@translates).map(&:to_s)
        @driving            = Array(@driving).map(&:to_s)
      end

      # Says whether this hecksagon marked its own bluebook `bounded`.
      #
      # @return [Boolean] whether `bounded` was declared on this block
      def bounded? = @bounded

      # Every bluebook this hecksagon brings into its domain's registry, gem and vendored alike.
      #
      # @return [Array<String>] the bluebooks' names as the registry holds them, in the order
      #   they were attached
      def member_bluebooks = attachments.map(&:declaration_name)

      # Says whether this hecksagon attaches a bluebook, whatever its source.
      #
      # @param bluebook [String, Symbol] a bluebook's name as the registry holds it
      # @return [Boolean] whether that bluebook is attached here
      def attaches?(declaration) = member_bluebooks.include?(declaration.to_s)

      # Says whether a driving adapter may reach this hecksagon's domain: every adapter may when
      # none is declared, and only the declared ones may once any is.
      #
      # @param adapter [String, Symbol] a driving adapter's name, such as `"Mcp"`
      # @return [Boolean] whether `driven_by` admits that adapter
      def driven_by?(adapter) = driving.empty? || driving.include?(adapter.to_s)

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
      # @param default_database [String, nil] the connection every bluebook's
      #   database-taking persistence adapter uses unless its own settings name one,
      #   or `nil` if none is declared
      # @param default_adapter [String, nil] the persistence adapter every aggregate
      #   binds to unless its bluebook's hecksagon binds it, or `nil` if none is declared
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
