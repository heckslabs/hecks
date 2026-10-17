# frozen_string_literal: true

require_relative "findings"
require_relative "function_code"

module Hecks
  module Projections
    module Site
      class Edge
        # The part of the edge checks that reads the `EdgeFunction` rows and the routes that name
        # them: each row is well formed and safe to write into a function, each route names a row
        # that exists, and no row is left that nothing names.
        class FunctionChecks
          include Findings

          # The longest logical id a function takes; the name it is given in the account adds the
          # stack name, and CloudFront allows 64 characters in all.
          NAME_LIMIT = 40

          # @param edge [Edge] the edge being read, its rows set
          # @param rows [Array<Table::Row>] the route table's rows
          # @param vocabulary [Hash{Symbol => Array<String>}] the Site chapter's closed sets
          # @param problems [Array<String>] collects each problem found, one line each
          def initialize(edge, rows, vocabulary, problems)
            @edge = edge
            @rows = rows
            @vocabulary = vocabulary
            @problems = problems
          end

          # @return [void]
          def call
            @edge.functions.each { |function| check_function(function) }
            repeated(@edge.functions.map(&:name), "EdgeFunction", &:itself)
            check_derived_names
            check_routes
            check_unused
          end

          private

          def check_function(function)
            label = "EdgeFunction #{function.name}"
            check_name(label, function)
            member_of(label, "kind", function.kind, :edge_function_kind)
            check_host(label, "host", function.host)
            function.alias_list.each { |host| check_alias(label, function, host) }
            check_paths(label, function)
          end

          # Two logical ids that differ only in case would be given one function name.
          def check_derived_names
            names = @edge.functions.map { |function| function.name.to_s }.uniq
            names.group_by { |name| FunctionCode.kebab(name) }.each do |kebab, together|
              problem("EdgeFunction", "#{together.join(" and ")} would both be named #{kebab}") if together.size > 1
            end
          end

          def check_name(label, function)
            name = function.name.to_s
            problem(label, "is not a logical id") unless Checks::LOGICAL_ID.match?(name)
            problem(label, "is longer than #{NAME_LIMIT} characters") if name.size > NAME_LIMIT
          end

          def check_host(label, field, host)
            return if FunctionCode.host?(host)

            problem(label, "has #{field} #{host.inspect}; #{field == "alias" ? "an" : "a"} #{field} is a lowercase hostname " \
                           "such as app.example.test")
          end

          def check_alias(label, function, host)
            check_host(label, "alias", host)
            problem(label, "has alias #{host}, which is its host; an alias is another host") if host == function.host
          end

          def check_paths(label, function)
            problem(label, "needs at least one path to watch") if function.path_list.empty?
            function.path_list.each do |path|
              next if FunctionCode.path?(path)

              problem(label, "has path #{path.inspect}; a path is exact, starts with / and holds letters, digits and . _ ~ - /")
            end
          end

          # Every `edge:` names a row, and a route the CDN never sees has no edge to run it.
          def check_routes
            @rows.select(&:edge).each do |row|
              problem(row.path, "names edge #{row.edge}, which no EdgeFunction declares") unless @edge.function(row.edge)
              problem(row.path, "names edge #{row.edge} and has cdn false; the edge never sees it") unless row.cdn
            end
          end

          def check_unused
            named = @rows.select(&:edge).map(&:edge)
            @edge.functions.reject { |function| named.include?(function.name) }.each do |function|
              problem("EdgeFunction #{function.name}", "is named by no route; remove the row or add edge: to a route")
            end
          end
        end
      end
    end
  end
end
