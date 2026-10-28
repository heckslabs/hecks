# frozen_string_literal: true

require_relative "table/row_builder"
require_relative "table/link_builder"
require_relative "table/checks"

module Hecks
  module Projections
    module Site
      # A client's route table, read from its bluebook and checked against the Site bluebook's
      # vocabulary.
      #
      # The rows are the `member` lines of a `value_object "Route"` in any bluebook of the project
      # (the Site bluebook's own `Route` aggregate names the fields and the closed sets). This class
      # reads them, fills each row's defaults (the cache class from the auth and kind, the render
      # from the kind, the path from a `command:` or `query:` source), and refuses a table that
      # contradicts itself, naming every problem at once.
      class Table
        # A table the projection refuses; the message lists each problem on its own line.
        class Invalid < ArgumentError; end

        # The name of the value object a client declares its rows in.
        ROW_OBJECT = "Route"

        # A parameter or a wildcard: what makes a route path stand for more than one page.
        PARAMETER_OR_WILDCARD = /[:*]/

        # The name of the value object a client declares its extra navigation entries in.
        LINK_OBJECT = "NavLink"

        # @return [Array<Row>] the rows, in the order the client declared them
        attr_reader :rows

        # @return [Array<Link>] the extra navigation entries, in the order the client declared them
        attr_reader :links

        # Finds the one bluebook of a project that declares the route table.
        #
        # @param registry [Runtime::Registry] the registry the project booted into
        # @return [Bluebook::Declaration] the bluebook holding the `Route` value object with member
        #   rows
        # @raise [Invalid] when no bluebook, or more than one, declares one
        def self.declaration(registry)
          declarations = registry.bluebooks.values
          holders = declarations.reject { |declaration| declaration.name == "Site" }
          holders = holders.select { |declaration| rows_of(declaration).any? }
          raise Invalid, "no bluebook declares a value_object \"#{ROW_OBJECT}\" with member rows" if holders.empty?
          return holders.first if holders.one?

          raise Invalid, "#{holders.size} bluebooks declare a value_object \"#{ROW_OBJECT}\": " \
                         "#{holders.map(&:name).join(", ")}; a project has one route table"
        end

        # Reads and checks one bluebook's route table.
        #
        # @param bluebook [Bluebook::Declaration] the bluebook that declares the rows
        # @param registry [Runtime::Registry] the registry the project booted into: it holds the
        #   Site bluebook and, for a `command:` or `query:` source, the command or query
        # @return [Table] the checked table
        # @raise [Invalid] when the Site bluebook is not attached or a row is refused
        def self.read(declaration, registry:)
          new(rows_of(declaration), vocabulary: vocabulary(registry), registry: registry,
                                links: rows_of(declaration, LINK_OBJECT))
        end

        # @param registry [Runtime::Registry] a registry holding the Site bluebook
        # @return [Hash{Symbol => Array<String>}] each constrained field to its allowed values, and
        #   `:http_method` to the verbs a route may answer and `:edge_function_kind` to the kinds of
        #   `EdgeFunction` row
        # @raise [Invalid] when the registry does not hold the Site bluebook
        def self.vocabulary(registry)
          site = registry.bluebook("Site") or
            raise Invalid, "the project does not attach the Site bluebook (attaches \"Site\")"
          route = site.aggregate("Route")
          members = lambda do |name|
            closed_set = route.value_objects.find { |object| object.hecks_name == name }
            closed_set.members.map { |member| member.fetch(:value) }
          end
          closed = RowBuilder::VOCABULARY.transform_values(&members)
          closed.merge(http_method: members.call("HttpMethod"), edge_function_kind: members.call("EdgeFunctionKind"))
        end

        # @param bluebook [Bluebook::Declaration] a bluebook to search
        # @param object [String] the name of the value object whose rows are wanted
        # @return [Array<Hash{Symbol => Object}>] the member rows of its value objects of that name
        def self.rows_of(declaration, object = ROW_OBJECT)
          objects = declaration.aggregates.flat_map(&:value_objects)
          objects.select { |candidate| candidate.hecks_name == object }.flat_map(&:members)
        end

        # @param members [Array<Hash{Symbol => Object}>] the declared member rows
        # @param vocabulary [Hash{Symbol => Array<String>}] the closed sets
        # @param registry [Runtime::Registry, nil] where a `command:` or `query:` source is looked
        #   up; nil skips that check
        # @param links [Array<Hash{Symbol => Object}>] the declared `NavLink` rows
        # @raise [Invalid] when a row is refused
        def initialize(members, vocabulary:, registry: nil, links: [])
          problems = []
          @rows = build_all(members, RowBuilder.new(vocabulary: vocabulary, registry: registry, problems: problems))
          @links = build_all(links, LinkBuilder.new(@rows, problems))
          Checks.new(@rows, problems, links: @links).call
          return if problems.empty?

          raise Invalid, "the route table is refused:\n#{problems.map { |line| "  - #{line}" }.join("\n")}"
        end

        # @param members [Array<Hash{Symbol => Object}>] declared rows or links
        # @param builder [#call] a `RowBuilder` or `LinkBuilder`
        # @return [Array<Row, Link>] what the builder makes of each, in order
        def build_all(members, builder) = members.each_with_index.map { |member, index| builder.call(member, index) }
        private :build_all

        # The navigation slots a row or link sits in.
        #
        # @param row [Row, Link] a row or link
        # @return [Array<String>] some of `desktop`, `mobile`, `footer`, `admin`
        def navigation(row) = Checks.navigation(row)
      end
    end
  end
end
