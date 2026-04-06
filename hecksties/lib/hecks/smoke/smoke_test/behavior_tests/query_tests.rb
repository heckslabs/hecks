# HecksTemplating::SmokeTest::QueryTests
#
# Tests domain queries, scopes, and specifications over HTTP.
# Each method walks the domain IR and exercises the corresponding
# HTTP routes via GET requests.
#
#   test_queries(results)
#   test_scopes(results)
#   test_specifications(results)
#
module HecksTemplating
  class SmokeTest
    module QueryTests
      private

      def test_queries(results)
        @domain.aggregates.each do |agg|
          plural = underscore(agg.name) + "s"
          agg.queries.each do |query|
            query_snake = underscore(query.name)
            path = HecksTemplating::RouteContract.query_path(plural, query_snake)
            path += "?value=example" if query.block.arity > 0
            results << check_get(path, "#{agg.name} query #{query.name}")
          end
        end
      end

      def test_scopes(results)
        @domain.aggregates.each do |agg|
          plural = underscore(agg.name) + "s"
          agg.scopes.each do |scope|
            path = HecksTemplating::RouteContract.scope_path(plural, scope.name)
            path += "?value=example" if scope.callable?
            results << check_get(path, "#{agg.name} scope #{scope.name}")
          end
        end
      end

      def test_specifications(results)
        @domain.aggregates.each do |agg|
          plural = underscore(agg.name) + "s"
          id = fetch_first_id(plural)
          next unless id

          agg.specifications.each do |spec|
            spec_snake = underscore(spec.name)
            path = "#{HecksTemplating::RouteContract.spec_path(plural, spec_snake)}?id=#{id}"
            results << check_get(path, "#{agg.name} spec #{spec.name}")
          end
        end
      end
    end
  end
end
