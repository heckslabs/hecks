# frozen_string_literal: true

require_relative "../deploy/fargate/cdn"
require_relative "table"
require_relative "edge/pattern"
require_relative "edge/checks"
require_relative "edge/behaviours"
require_relative "edge/rules"

module Hecks
  module Projections
    module Site
      # What a site's route table says about the edge: the CloudFront behaviours and the load
      # balancer's listener rules that send each route to the server and cache that serve it.
      #
      # The routes are the table's own `Route` rows. What a table cannot know, the names a template
      # gives its policies, origins, target groups and listener, a project declares as `member`
      # rows of four more value objects of the same chapter: `Edge` (the template and listener),
      # `EdgePolicy`, `EdgeOrigin` and `EdgeRule`. `docs/site-routes.md` lists their fields. A
      # project that declares none of the four has no edge to project.
      class Edge
        Setting  = Struct.new(:template, :listener, :secret_header, :secret_value, keyword_init: true)
        Policy   = Struct.new(:cache_class, :origin, :cache, :origin_request, :response_headers, keyword_init: true)
        Upstream = Struct.new(:origin, :id, :target_group, keyword_init: true)
        Rule     = Struct.new(:rule, :priority, :origin, keyword_init: true)

        # The value objects a project declares its edge rows in, by the kind of record each holds.
        OBJECTS = { setting: "Edge", policy: "EdgePolicy", upstream: "EdgeOrigin", rule: "EdgeRule" }.freeze

        # The fields each kind of row may carry, with the Ruby class each takes.
        FIELDS = {
          setting:  { template: String, listener: String, secret_header: String, secret_value: String },
          policy:   { cache_class: String, origin: String, cache: String, origin_request: String,
                    response_headers: String },
          upstream: { origin: String, id: String, target_group: String },
          rule:     { rule: String, priority: Integer, origin: String }
        }.freeze

        # The fields a row of each kind must carry.
        REQUIRED = { setting: [:template], policy: %i[cache_class cache], upstream: %i[origin id],
                     rule: %i[rule priority origin] }.freeze

        STRUCTS = { setting: Setting, policy: Policy, upstream: Upstream, rule: Rule }.freeze

        # @return [Setting] the template and the listener
        attr_reader :setting
        # @return [Array<Policy>] the cache class to policy mapping
        attr_reader :policies
        # @return [Array<Upstream>] the origin mapping
        attr_reader :upstreams
        # @return [Array<Rule>] the listener rules
        attr_reader :rules
        # @return [Hash{Symbol => Object}] the default behaviour as `Cdn.behavior_lines` takes it
        attr_reader :default_behaviour
        # @return [Array<Hash{Symbol => Object}>] the other behaviours, in matching order
        attr_reader :behaviours
        # @return [Array<Hash{Symbol => Object}>] each listener rule with the paths it carries
        attr_reader :listener_rules

        # Reads and checks the edge a chapter declares.
        #
        # @param chapter [Bluebook::Chapter] the chapter that declares the route table
        # @param table [Table] the checked route table
        # @param vocabulary [Hash{Symbol => Array<String>}] the Site chapter's closed sets
        # @return [Edge, nil] the checked edge, or nil when the chapter declares none
        # @raise [Table::Invalid] when a row is refused or the edge contradicts the routes
        def self.read(chapter, table:, vocabulary:)
          declared = OBJECTS.transform_values { |name| Table.rows_of(chapter, name) }
          return nil if declared.values.all?(&:empty?)

          problems = []
          records = declared.to_h { |kind, members| [kind, build(kind, members, problems)] }
          new(records, table: table, vocabulary: vocabulary, problems: problems)
        end

        # @param kind [Symbol] a key of `OBJECTS`
        # @param members [Array<Hash{Symbol => Object}>] the declared rows
        # @param problems [Array<String>] collects each problem found
        # @return [Array<Struct>] the rows that carry known, well-typed fields
        def self.build(kind, members, problems)
          members.each_with_index.map do |member, index|
            label = "#{OBJECTS.fetch(kind)} row #{index + 1}"
            unknown = member.keys - FIELDS.fetch(kind).keys
            if unknown.any?
              problems << "#{label} has no field #{unknown.join(', ')}; fields are #{FIELDS.fetch(kind).keys.join(', ')}"
            end
            (REQUIRED.fetch(kind) - member.keys).each { |field| problems << "#{label} needs #{field}" }
            typed = member.slice(*FIELDS.fetch(kind).keys).select do |field, value|
              value.is_a?(FIELDS.fetch(kind).fetch(field)) || (problems << "#{label} has #{field} #{value.inspect}; " \
                                                                           "#{field} is a #{FIELDS.fetch(kind).fetch(field)}")
            end
            STRUCTS.fetch(kind).new(**typed)
          end
        end
        private_class_method :build

        # @param records [Hash{Symbol => Array<Struct>}] the rows of each kind
        # @param table [Table] the checked route table
        # @param vocabulary [Hash{Symbol => Array<String>}] the closed sets
        # @param problems [Array<String>] the problems already found in reading the rows
        # @raise [Table::Invalid] naming every problem when there is one
        def initialize(records, table:, vocabulary:, problems:)
          @setting = records.fetch(:setting).first
          @policies = records.fetch(:policy)
          @upstreams = records.fetch(:upstream)
          @rules = records.fetch(:rule)
          Checks.new(self, table.rows, vocabulary, problems).call
          if problems.empty?
            @listener_rules = Rules.new(self, table.rows, problems).call
            built = Behaviours.new(self, table.rows, problems).call
            @default_behaviour = built.fetch(:default)
            @behaviours = built.fetch(:list)
          end
          return if problems.empty?

          raise Table::Invalid, "the edge is refused:\n#{problems.map { |line| "  - #{line}" }.join("\n")}"
        end

        # @param origin [String] an origin of the Origin set
        # @return [Upstream, nil] its CloudFront origin and target group
        def upstream(origin) = upstreams.find { |candidate| candidate.origin == origin }

        # The policy mapping for a class on an origin: the row naming both, else the one naming the
        # class alone.
        #
        # @param cache_class [String] a cache class
        # @param origin [String] an origin
        # @return [Policy, nil]
        def policy(cache_class, origin)
          matching = policies.select { |candidate| candidate.cache_class == cache_class }
          matching.find { |candidate| candidate.origin == origin } || matching.find { |candidate| candidate.origin.nil? }
        end
      end
    end
  end
end
