# frozen_string_literal: true

module Hecks
  module Projections
    module Site
      class Edge
        # A path pattern as CloudFront and the load balancer read it, and the one question the edge
        # asks of two of them: does the first match everything the second does.
        #
        # A route path names a parameter as `:slug`; the edge has no parameters, so a parameter
        # stands for `*`. Both services treat `*` as any run of characters, `/` included, and `?` as
        # one character, and match the whole path, so a pattern without either matches one path.
        module Pattern
          module_function

          # @param path [String] a route path such as `/blog/:slug.html` or `/cms/*`
          # @return [String] the pattern the edge reads for it, `/blog/*.html` for the first
          def edge(path) = path.gsub(/:[A-Za-z_]\w*/, "*")

          # @param pattern [String] an edge pattern
          # @return [Regexp] what it matches, from the start of a path to its end
          def regexp(pattern)
            source = pattern.each_char.map do |char|
              case char
              when "*" then ".*"
              when "?" then "."
              else Regexp.escape(char)
              end
            end
            Regexp.new("\\A#{source.join}\\z")
          end

          # Whether every path `specific` matches is also matched by `general`, tested by reading
          # `specific` as a literal string, so `/admin*` covers `/admin/members` and `/admin-inbox`
          # and `/cms/*` covers `/cms/_next/static/*`. A pattern covers itself.
          #
          # @param general [String] an edge pattern
          # @param specific [String] an edge pattern
          # @return [Boolean]
          def covers?(general, specific) = regexp(general).match?(specific)

          # @param general [String] an edge pattern
          # @param specific [String] an edge pattern
          # @return [Boolean] whether `general` covers `specific` and is not the same pattern
          def strictly_covers?(general, specific) = general != specific && covers?(general, specific)
        end
      end
    end
  end
end
