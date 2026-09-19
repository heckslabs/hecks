module Hecks
  # A public Bluebook command/query address.
  #
  # Realm is deployment identity from a world. Domain@version pins a domain
  # contract; an unpinned domain is the world's configured latest alias.
  class Fqn
    class Invalid < ArgumentError; end

    attr_reader :realm, :domain, :version, :aggregate, :verb, :kind

    # Builds the FQN of one command on an aggregate.
    #
    # @param realm [String, nil] deployment identity from the world, or nil for an
    #   unrealmed address
    # @param domain [String] the domain name
    # @param aggregate [String] the aggregate name the command belongs to
    # @param command [String] the command's PascalCase verb
    # @param version [String, nil] the pinned domain version, or nil for the
    #   world's configured latest alias
    # @return [Fqn] the command address
    # @raise [Fqn::Invalid] if any segment is empty or contains a separator, or if
    #   `command` is not a valid PascalCase command name
    def self.command(realm:, domain:, aggregate:, command:, version: nil)
      new(realm: realm, domain: domain, version: version, aggregate: aggregate, verb: command, kind: :command)
    end

    # Builds the FQN of one query, either on an aggregate or domain-level.
    #
    # @param realm [String, nil] deployment identity from the world, or nil for an
    #   unrealmed address
    # @param domain [String] the domain name
    # @param query [String] the query's snake_case verb
    # @param aggregate [String, nil] the aggregate the query belongs to, or nil for
    #   a domain-level read model
    # @param version [String, nil] the pinned domain version, or nil for the
    #   world's configured latest alias
    # @return [Fqn] the query address
    # @raise [Fqn::Invalid] if any segment is empty or contains a separator, or if
    #   `query` is not a valid snake_case query name
    def self.query(realm:, domain:, query:, aggregate: nil, version: nil)
      new(realm: realm, domain: domain, version: version, aggregate: aggregate, verb: query, kind: :query)
    end

    # One order-dependent parse pipeline: split -> shape-validate -> dispatch
    # on segment count -> split domain/version -> classify kind -> cross-
    # field validate -> construct. Each step consumes locals (segments, verb,
    # kind) the step before it derived; splitting would mean threading all of
    # them back out as parameters/returns between new methods, for no
    # readability gain over reading the pipeline top to bottom once.
    #
    # @param text [String] a `Realm::Domain::Aggregate.verb` address, with domain
    #   optionally `@version`-pinned and aggregate optional for a domain-level query
    # @return [Fqn] the parsed address
    # @raise [Fqn::Invalid] if `text` is not shaped like a FQN, its verb is neither
    #   PascalCase nor snake_case, its domain version is malformed, or it names a
    #   domain-level command
    # rubocop:disable-next Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
    def self.parse(text)
      head, separator, verb = text.to_s.rpartition(".")
      raise Invalid, "FQN must be Realm::Domain::Aggregate.verb — got #{text.inspect}" if separator.empty?

      segments = head.split("::", -1)
      valid_fqn = [1, 2, 3].include?(segments.length) && segments.none?(&:empty?) && !verb.empty?
      raise Invalid, "FQN must be Realm::Domain::Aggregate.verb — got #{text.inspect}" unless valid_fqn

      realm, domain_spec, aggregate = case segments.length
                                      when 3 then segments
                                      # A two-segment lowercase address is the
                                      # public realm/domain form for a
                                      # domain-level read model.
                                      when 2 then query_name?(verb) ? [segments[0], segments[1], nil] : [nil, *segments]
                                      else [nil, segments.first, nil]
                                      end
      domain, version = split_domain(domain_spec)
      kind = if command_name?(verb)
               :command
             elsif query_name?(verb)
               :query
             else
               raise Invalid, "FQN verb must be PascalCase command or snake_case query — got #{text.inspect}"
             end

      raise Invalid, "domain-level FQNs are query-only — got #{text.inspect}" if aggregate.nil? && kind == :command

      new(realm: realm, domain: domain, version: version, aggregate: aggregate, verb: verb, kind: kind)
    end

    # Whether `name` is a valid command verb: PascalCase.
    #
    # @param name [String, Symbol, #to_s] the candidate verb
    # @return [Boolean] true if `name` matches the PascalCase command shape
    def self.command_name?(name) = /\A[A-Z][A-Za-z0-9]*\z/.match?(name.to_s)

    # Whether `name` is a valid query verb: snake_case.
    #
    # @param name [String, Symbol, #to_s] the candidate verb
    # @return [Boolean] true if `name` matches the snake_case query shape
    def self.query_name?(name)   = /\A[a-z][a-z0-9_]*\z/.match?(name.to_s)

    # @param realm [String, nil] deployment identity from the world, or nil for an
    #   unrealmed address
    # @param domain [String] the domain name
    # @param aggregate [String, nil] the aggregate name, or nil for a domain-level query
    # @param verb [String] the command or query verb
    # @param kind [Symbol, String] `:command` or `:query`
    # @param version [String, nil] the pinned domain version, or nil for the
    #   world's configured latest alias
    # @raise [Fqn::Invalid] if any segment is empty or contains a separator, or if
    #   `verb` does not match the shape required by `kind`
    def initialize(realm:, domain:, aggregate:, verb:, kind:, version: nil)
      @realm     = realm && segment(realm, "realm")
      @domain    = segment(domain, "domain")
      @version   = version && segment(version, "version")
      @aggregate = aggregate && segment(aggregate, "aggregate")
      @verb      = segment(verb, "verb")
      @kind      = kind.to_sym

      valid = command? ? self.class.command_name?(@verb) : self.class.query_name?(@verb)
      raise Invalid, "#{@kind} FQN has an invalid verb #{@verb.inspect}" unless valid
    end

    # Whether this address names a command.
    #
    # @return [Boolean] true if this address's kind is `:command`
    def command? = @kind == :command

    # Whether this address names a query.
    #
    # @return [Boolean] true if this address's kind is `:query`
    def query?   = @kind == :query

    def to_s
      domain = @version ? "#{@domain}@#{@version}" : @domain
      [[@realm, domain, @aggregate].compact.join("::"), @verb].join(".")
    end

    def ==(other) = other.is_a?(Fqn) && to_s == other.to_s
    alias eql? ==
    def hash = to_s.hash

    private

    def self.split_domain(value)
      domain, version, extra = value.to_s.split("@", 3)
      if domain.empty? || extra || (value.include?("@") && version.to_s.empty?)
        raise Invalid,
              "FQN domain version is malformed: #{value.inspect}"
      end

      [domain, version]
    end
    private_class_method :split_domain

    def segment(value, label)
      text = value.to_s
      if text.empty? || text.include?("::") || text.include?(".") || text.include?("@")
        raise Invalid,
              "FQN #{label} cannot be empty or contain a separator"
      end

      text
    end
  end
end
