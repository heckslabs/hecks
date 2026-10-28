# frozen_string_literal: true

require_relative "../deploy/fargate/cdn"
require_relative "table"
require_relative "edge/pattern"
require_relative "edge/row_reader"
require_relative "edge/checks"
require_relative "edge/behaviours"
require_relative "edge/rules"
require_relative "edge/function_code"

module Hecks
  module Projections
    module Site
      # What a site's route table says about the edge: the CloudFront behaviours and the load
      # balancer's listener rules that send each route to the server and cache that serve it.
      #
      # The routes are the table's own `Route` rows. What a table cannot know, the names a template
      # gives its policies, origins, target groups and listener, a project declares as `member`
      # rows of five more value objects of the same bluebook: `Edge` (the template and listener),
      # `EdgePolicy`, `EdgeOrigin`, `EdgeRule` and `EdgeFunction` (a viewer-request function a route
      # names with `edge:`). `docs/site-routes.md` lists their fields. A project that declares none
      # of the five has no edge to project.
      class Edge
        Setting  = Struct.new(:template, :listener, :secret_header, :secret_value, :alb, keyword_init: true)
        Policy   = Struct.new(:cache_class, :origin, :cache, :origin_request, :response_headers, keyword_init: true)
        Upstream = Struct.new(:origin, :id, :target_group, keyword_init: true)
        Rule     = Struct.new(:rule, :priority, :origin, keyword_init: true)

        # A function the generator writes: `kind` says which, and the rest are its settings, the
        # lists as comma-separated text.
        Function = Struct.new(:name, :kind, :host, :aliases, :paths, keyword_init: true) do
          # @return [Array<String>] the alias hosts that are redirected
          def alias_list = split(aliases)

          # @return [Array<String>] the exact paths the function watches
          def path_list = split(paths)

          private

          def split(text) = Hecks::Text.comma_list(text)
        end

        # The value objects a project declares its edge rows in, by the kind of record each holds.
        OBJECTS = { setting: "Edge", policy: "EdgePolicy", upstream: "EdgeOrigin", rule: "EdgeRule",
                    function: "EdgeFunction" }.freeze

        # The fields each kind of row may carry, with the Ruby class each takes.
        FIELDS = {
          setting:  { template: String, listener: String, secret_header: String, secret_value: String, alb: :bool },
          policy:   { cache_class: String, origin: String, cache: String, origin_request: String,
                    response_headers: String },
          upstream: { origin: String, id: String, target_group: String },
          rule:     { rule: String, priority: Integer, origin: String },
          function: { name: String, kind: String, host: String, aliases: String, paths: String }
        }.freeze

        # The fields a row of each kind must carry. The template may instead be named to the tool.
        REQUIRED = { setting: [], policy: %i[cache_class cache], upstream: %i[origin id],
                     rule: %i[rule priority origin], function: %i[name kind host aliases paths] }.freeze

        STRUCTS = { setting: Setting, policy: Policy, upstream: Upstream, rule: Rule, function: Function }.freeze

        # @return [Setting] the template and the listener
        attr_reader :setting
        # @return [Array<Policy>] the cache class to policy mapping
        attr_reader :policies
        # @return [Array<Upstream>] the origin mapping
        attr_reader :upstreams
        # @return [Array<Rule>] the listener rules
        attr_reader :rules
        # @return [Array<Function>] the edge functions the generator writes
        attr_reader :functions
        # @return [Hash{Symbol => Object}] the default behaviour as `Cdn.behavior_lines` takes it
        attr_reader :default_behaviour
        # @return [Array<Hash{Symbol => Object}>] the other behaviours, in matching order
        attr_reader :behaviours
        # @return [Array<Hash{Symbol => Object}>] each listener rule with the paths it carries
        attr_reader :listener_rules

        # Reads and checks the edge a bluebook declares.
        #
        # @param bluebook [Bluebook::Declaration] the bluebook that declares the route table
        # @param table [Table] the checked route table
        # @param vocabulary [Hash{Symbol => Array<String>}] the Site bluebook's closed sets
        # @param template [String, nil] the template the caller names, which stands in for the
        #   `Edge` row's own `template:`
        # @return [Edge, nil] the checked edge, or nil when the bluebook declares none and no route
        #   names an edge function
        # @raise [Table::Invalid] when a row is refused or the edge contradicts the routes
        def self.read(declaration, table:, vocabulary:, template: nil)
          declared = OBJECTS.transform_values { |name| Table.rows_of(declaration, name) }
          return nil if declared.values.all?(&:empty?) && table.rows.none?(&:edge)

          problems = []
          records = declared.to_h { |kind, members| [kind, build(kind, members, problems)] }
          new(records, table: table, vocabulary: vocabulary, problems: problems, template: template)
        end

        # @param kind [Symbol] a key of `OBJECTS`
        # @param members [Array<Hash{Symbol => Object}>] the declared rows
        # @param problems [Array<String>] collects each problem found
        # @return [Array<Struct>] the rows that carry known, well-typed fields
        def self.build(kind, members, problems) = RowReader.new(kind, problems).call(members)
        private_class_method :build

        # @param records [Hash{Symbol => Array<Struct>}] the rows of each kind
        # @param table [Table] the checked route table
        # @param vocabulary [Hash{Symbol => Array<String>}] the closed sets
        # @param problems [Array<String>] the problems already found in reading the rows
        # @param template [String, nil] the template the caller names, if any
        # @raise [Table::Invalid] naming every problem when there is one
        def initialize(records, table:, vocabulary:, problems:, template: nil)
          assign(records)
          Checks.new(self, table.rows, vocabulary, problems, template_named: !template.nil?).call
          build_outputs(table, problems) if problems.empty?
          return if problems.empty?

          raise Table::Invalid, "the edge is refused:\n#{problems.map { |line| "  - #{line}" }.join("\n")}"
        end

        # Reads the checked rows into the accessors, then builds what the routes need from them.
        def assign(records)
          @setting = records.fetch(:setting).first
          @policies = records.fetch(:policy)
          @upstreams = records.fetch(:upstream)
          @rules = records.fetch(:rule)
          @functions = records.fetch(:function)
        end
        private :assign

        def build_outputs(table, problems)
          @listener_rules = alb? ? Rules.new(self, table.rows, problems).call : []
          built = Behaviours.new(self, table.rows, problems).call
          @default_behaviour = built.fetch(:default)
          @behaviours = built.fetch(:list)
        end
        private :build_outputs

        # @return [Boolean] whether the project has a load balancer, and so listener rules; true
        #   unless the `Edge` row says `alb: false`
        def alb? = setting.nil? || setting.alb != false

        # @return [String, nil] the listener the `Edge` row names, or `nil` without an `Edge` row
        def listener = setting&.listener

        # @return [String, nil] the secret header the `Edge` row names
        def secret_header = setting.secret_header

        # @param name [String] a logical id
        # @return [Function, nil] the function row of that name
        def function(name) = functions.find { |candidate| candidate.name == name }

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
