module Hecksagain
  # A public Bluebook command/query address.
  #
  # Realm is deployment identity from a world. Domain@version pins a domain
  # contract; an unpinned domain is the world's configured latest alias.
  class Fqn
    class Invalid < ArgumentError; end

    attr_reader :realm, :domain, :version, :aggregate, :verb

    def self.command(realm:, domain:, aggregate:, command:, version: nil)
      new(realm: realm, domain: domain, version: version, aggregate: aggregate, verb: command, kind: :command)
    end

    def self.query(realm:, domain:, aggregate: nil, query:, version: nil)
      new(realm: realm, domain: domain, version: version, aggregate: aggregate, verb: query, kind: :query)
    end

    def self.parse(text)
      head, separator, verb = text.to_s.rpartition(".")
      raise Invalid, "FQN must be Realm::Domain::Aggregate.verb — got #{text.inspect}" if separator.empty?

      segments = head.split("::", -1)
      raise Invalid, "FQN must be Realm::Domain::Aggregate.verb — got #{text.inspect}" unless [1, 2, 3].include?(segments.length) && segments.none?(&:empty?) && !verb.empty?

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

    def self.command_name?(name) = /\A[A-Z][A-Za-z0-9]*\z/.match?(name.to_s)
    def self.query_name?(name)   = /\A[a-z][a-z0-9_]*\z/.match?(name.to_s)

    def initialize(realm:, domain:, version: nil, aggregate:, verb:, kind:)
      @realm     = realm && segment(realm, "realm")
      @domain    = segment(domain, "domain")
      @version   = version && segment(version, "version")
      @aggregate = aggregate && segment(aggregate, "aggregate")
      @verb      = segment(verb, "verb")
      @kind      = kind.to_sym

      valid = command? ? self.class.command_name?(@verb) : self.class.query_name?(@verb)
      raise Invalid, "#{@kind} FQN has an invalid verb #{@verb.inspect}" unless valid
    end

    def command? = @kind == :command
    def query?   = @kind == :query
    def kind     = @kind

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
      raise Invalid,
            "FQN domain version is malformed: #{value.inspect}" if domain.empty? || extra || (value.include?("@") && version.to_s.empty?)

      [domain, version]
    end

    def segment(value, label)
      text = value.to_s
      raise Invalid,
            "FQN #{label} cannot be empty or contain a separator" if text.empty? || text.include?("::") || text.include?(".") || text.include?("@")

      text
    end
  end
end
