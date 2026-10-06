# frozen_string_literal: true

require_relative "table/row_builder"
require_relative "table/link_builder"
require_relative "table/checks"

module Hecks
  module Projections
    module Site
      # A client's route table, read from its chapter and checked against the Site chapter's
      # vocabulary.
      #
      # The rows are the `member` lines of a `value_object "Route"` in any chapter of the project
      # (the Site chapter's own `Route` aggregate names the fields and the closed sets). This class
      # reads them, fills each row's defaults (the cache class from the auth and kind, the render
      # from the kind, the path from a `command:` or `query:` source), and refuses a table that
      # contradicts itself, naming every problem at once.
      class Table
        # A table the projection refuses; the message lists each problem on its own line.
        class Invalid < ArgumentError; end

        # The name of the value object a client declares its rows in.
        ROW_OBJECT = "Route"

        # The name of the value object a client declares its extra navigation entries in.
        LINK_OBJECT = "NavLink"

        # @return [Array<Row>] the rows, in the order the client declared them
        attr_reader :rows

        # @return [Array<Link>] the extra navigation entries, in the order the client declared them
        attr_reader :links

        # Finds the one chapter of a project that declares the route table.
        #
        # @param registry [Runtime::Registry] the registry the project booted into
        # @return [Bluebook::Chapter] the chapter holding the `Route` value object with member rows
        # @raise [Invalid] when no chapter, or more than one, declares one
        def self.chapter(registry)
          holders = registry.bluebooks.values.reject { |chapter| chapter.name == "Site" }
                            .select { |chapter| rows_of(chapter).any? }
          raise Invalid, "no chapter declares a value_object \"#{ROW_OBJECT}\" with member rows" if holders.empty?
          return holders.first if holders.one?

          raise Invalid, "#{holders.size} chapters declare a value_object \"#{ROW_OBJECT}\": " \
                         "#{holders.map(&:name).join(", ")}; a project has one route table"
        end

        # Reads and checks one chapter's route table.
        #
        # @param chapter [Bluebook::Chapter] the chapter that declares the rows
        # @param registry [Runtime::Registry] the registry the project booted into: it holds the
        #   Site chapter and, for a `command:` or `query:` source, the command or query
        # @return [Table] the checked table
        # @raise [Invalid] when the Site chapter is not attached or a row is refused
        def self.read(chapter, registry:)
          new(rows_of(chapter), vocabulary: vocabulary(registry), registry: registry,
                                links: rows_of(chapter, LINK_OBJECT))
        end

        # @param registry [Runtime::Registry] a registry holding the Site chapter
        # @return [Hash{Symbol => Array<String>}] each constrained field to its allowed values, and
        #   `:http_method` to the verbs a route may answer
        # @raise [Invalid] when the registry does not hold the Site chapter
        def self.vocabulary(registry)
          site = registry.bluebook("Site") or
            raise Invalid, "the project does not attach the Site chapter (attaches \"Site\")"
          route = site.aggregate("Route")
          members = lambda do |name|
            route.value_objects.find { |object| object.hecks_name == name }.members.map { |member| member.fetch(:value) }
          end
          RowBuilder::VOCABULARY.transform_values(&members).merge(http_method: members.call("HttpMethod"))
        end

        # @param chapter [Bluebook::Chapter] a chapter to search
        # @param object [String] the name of the value object whose rows are wanted
        # @return [Array<Hash{Symbol => Object}>] the member rows of its value objects of that name
        def self.rows_of(chapter, object = ROW_OBJECT)
          chapter.aggregates.flat_map(&:value_objects)
                 .select { |candidate| candidate.hecks_name == object }.flat_map(&:members)
        end

        # @param members [Array<Hash{Symbol => Object}>] the declared member rows
        # @param vocabulary [Hash{Symbol => Array<String>}] the closed sets
        # @param registry [Runtime::Registry, nil] where a `command:` or `query:` source is looked
        #   up; nil skips that check
        # @param links [Array<Hash{Symbol => Object}>] the declared `NavLink` rows
        # @raise [Invalid] when a row is refused
        def initialize(members, vocabulary:, registry: nil, links: [])
          problems = []
          builder = RowBuilder.new(vocabulary: vocabulary, registry: registry, problems: problems)
          @rows = members.each_with_index.map { |member, index| builder.call(member, index) }
          link_builder = LinkBuilder.new(@rows, problems)
          @links = links.each_with_index.map { |member, index| link_builder.call(member, index) }
          Checks.new(@rows, problems, links: @links).call
          return if problems.empty?

          raise Invalid, "the route table is refused:\n#{problems.map { |line| "  - #{line}" }.join("\n")}"
        end

        # The navigation slots a row or link sits in.
        #
        # @param row [Row, Link] a row or link
        # @return [Array<String>] some of `desktop`, `mobile`, `footer`, `admin`
        def navigation(row) = Checks.navigation(row)
      end
    end
  end
end
