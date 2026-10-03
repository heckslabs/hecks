# frozen_string_literal: true

module Hecks
  module Projections
    module Site
      class Edge
        # The CloudFront behaviours a route table needs.
        #
        # Each route through the CDN resolves to the behaviour its origin, cache class, methods and
        # compression give it. A route needs none of its own when the behaviour that would match its
        # path anyway (the nearest broader route's, else the default one) is the same. The rest keep
        # the order the table declares, which is the order CloudFront matches in, and a route that
        # a broader, different one before it would shadow is refused.
        class Behaviours
          # The default behaviour's path: the row that holds the settings of everything else.
          DEFAULT_PATH = "/*"

          # @param edge [Edge] the edge being built; its rows are set
          # @param rows [Array<Table::Row>] the route table's rows
          # @param problems [Array<String>] collects each problem found, one line each
          def initialize(edge, rows, problems)
            @edge = edge
            @rows = rows
            @problems = problems
          end

          # @return [Hash{Symbol => Object}] `:default` the default behaviour and `:list` the
          #   others, each as `Cdn.behavior_lines` takes it, `:path` set on those of the list
          def call
            candidates = resolved
            default = candidates.delete(DEFAULT_PATH) || {}
            kept = candidates.reject { |pattern, entry| same?(nearest_cover(candidates, pattern, default), entry) }
            check_order(kept.values)
            { default: default.except(:path), list: kept.values }
          end

          private

          def same?(one, other) = one.except(:path) == other.except(:path)

          # Each CDN route's edge pattern to its behaviour; rows on one pattern with different verbs
          # share it, their methods united.
          def resolved
            groups = @rows.select(&:cdn).group_by { |row| Pattern.edge(row.path) }
            groups.to_h do |pattern, rows|
              entries = rows.map { |row| entry(row, pattern) }
              disagree = entries.map { |entry| entry.except(:methods) }.uniq.size > 1
              problem(pattern, "is declared by #{rows.size} routes that resolve to different behaviours") if disagree
              [pattern, entries.first.merge(methods: methods(rows))]
            end
          end

          def entry(row, pattern)
            policy = @edge.policy(row.cache, row.origin)
            {
              path: pattern, origin: @edge.upstream(row.origin).id, methods: methods([row]),
              viewer_protocol: protocol(row), compress: row.compress,
              cache_policy: Checks.resolve(policy.cache),
              origin_request_policy: reference(policy.origin_request),
              response_headers_policy: reference(policy.response_headers)
            }
          end

          def reference(text) = text.nil? || text == "none" ? nil : Checks.resolve(text)

          # CloudFront takes three sets of methods: read, read with `OPTIONS`, and all.
          def methods(rows)
            verbs = rows.flat_map(&:verbs).uniq
            return Deploy::Fargate::Cdn::METHODS.fetch("all") unless (verbs - ["GET"]).empty?

            assets = rows.all? { |row| row.origin == "assets" }
            Deploy::Fargate::Cdn::METHODS.fetch(assets ? "get_head" : "read")
          end

          # A public page that is only read, from the website or the assets, may be asked for over
          # http and redirected; anything else (a form, an API, a signed or admin page, a route of
          # the cms or the domain) is served over https only.
          def protocol(row)
            plain = row.auth == "public" && row.verbs == ["GET"] && %w[website assets].include?(row.origin)
            plain ? "redirect-to-https" : "https-only"
          end

          # The behaviour CloudFront would match for `pattern` were it not in the list: that of the
          # most specific broader pattern, else the default behaviour.
          def nearest_cover(candidates, pattern, default)
            covers = candidates.keys.select { |other| Pattern.strictly_covers?(other, pattern) }
            nearest = covers.find { |one| covers.none? { |other| Pattern.strictly_covers?(one, other) } }
            nearest ? candidates.fetch(nearest) : default
          end

          def check_order(list)
            list.each_with_index do |later, index|
              list.first(index).each do |earlier|
                next unless Pattern.strictly_covers?(earlier[:path], later[:path]) && !same?(earlier, later)

                problem(later[:path], "is shadowed by #{earlier[:path]}, which comes first and matches it; " \
                                      "declare #{later[:path]} before #{earlier[:path]}")
              end
            end
          end

          def problem(label, text) = @problems << "#{label} #{text}"
        end
      end
    end
  end
end
