# frozen_string_literal: true

module Hecks
  module Projections
    module Site
      # The requests a live site must answer as its route table says, and the verdict on each
      # answer. It sends nothing: the caller makes the requests and hands each response back.
      # A route with a parameter or a prefix (`/blog/:slug.html`, `/auth/*`) has no one URL to ask.
      #
      # - an `admin` route refuses an anonymous GET (and POST, where it takes one), uncached
      # - an indexable `public` page answers 200 and names its canonical link
      # - a row that is `off` answers 404, and a `redirect` row redirects to `redirect_to`
      # - a path no row declares answers 404
      class Probe
        # One request to make and what a good answer to it looks like.
        #
        # @!attribute [r] label
        #   @return [String] what is being checked, for the report
        # @!attribute [r] verb
        #   @return [String] GET or POST
        # @!attribute [r] path
        #   @return [String] the path to ask
        # @!attribute [r] expect
        #   @return [Symbol] one of `:refused`, `:page`, `:missing`, `:redirect`
        # @!attribute [r] to
        #   @return [String, nil] where a `:redirect` must lead
        Check = Struct.new(:label, :verb, :path, :expect, :to, keyword_init: true)

        # What one answer was: its status, its headers (lower-case names) and its body.
        Response = Struct.new(:status, :headers, :body, keyword_init: true)

        # The statuses that turn an anonymous caller away from an admin route.
        REFUSED = [301, 302, 303, 307, 308, 401, 403].freeze

        # The redirect statuses.
        REDIRECTS = [301, 302, 303, 307, 308].freeze

        # @param rows [Array<Table::Row>] the checked rows of a route table
        # @param run [String] the run's name, which makes the missing path unique to it
        def initialize(rows, run:)
          @rows = rows
          @run = run
        end

        # @return [Array<Check>] every request worth making, in the table's order, then the
        #   path that must not exist
        def checks
          @rows.select { |row| askable?(row) }.flat_map { |row| for_row(row) } + [missing]
        end

        # Judges one answer.
        #
        # @param check [Check] the request that was made
        # @param response [Response] what came back
        # @return [String, nil] why the answer is wrong, or nil when it is right
        def verdict(check, response)
          case check.expect
          when :refused  then refused(response)
          when :page     then page(response)
          when :missing  then response.status == 404 ? nil : "expected 404, got HTTP #{response.status}"
          when :redirect then redirect(check, response)
          end
        end

        private

        def askable?(row) = !row.path.empty? && !row.path.match?(/[:*]/)

        def for_row(row)
          return [off(row)] if row.off
          return admin(row) if row.auth == "admin"
          return [redirecting(row)] if row.kind == "redirect" && row.redirect_to
          return [page_of(row)] if page?(row)

          []
        end

        def page?(row) = row.auth == "public" && row.kind == "page" && row.indexable && row.verbs.include?("GET")

        def off(row) = Check.new(label: "#{row.path} is switched off: 404", verb: "GET", path: row.path, expect: :missing)

        def admin(row)
          row.verbs.select { |verb| %w[GET POST].include?(verb) }.map do |verb|
            Check.new(label: "#{verb} #{row.path} without a session is refused and not cached",
                      verb: verb, path: row.path, expect: :refused)
          end
        end

        def redirecting(row)
          Check.new(label: "#{row.path} redirects to #{row.redirect_to}", verb: "GET", path: row.path,
                    expect: :redirect, to: row.redirect_to)
        end

        def page_of(row)
          Check.new(label: "#{row.path} answers 200 with a canonical link", verb: "GET", path: row.path, expect: :page)
        end

        def missing
          Check.new(label: "a path no row declares is a real 404", verb: "GET", path: "/probe-#{@run}-missing",
                    expect: :missing)
        end

        def refused(response)
          return "expected a redirect, 401 or 403, got HTTP #{response.status}" unless REFUSED.include?(response.status)
          return nil if response.status >= 400

          control = response.headers["cache-control"].to_s
          return nil unless control.match?(/public|max-age=[1-9]/) && !control.match?(/no-store|private/)

          "the redirect is cacheable (Cache-Control: #{control})"
        end

        def page(response)
          return "expected 200, got HTTP #{response.status}" unless response.status == 200
          return nil if response.body.to_s.match?(/<link[^>]+rel=["']canonical["']/i)

          "the page has no canonical link"
        end

        def redirect(check, response)
          return "expected a redirect, got HTTP #{response.status}" unless REDIRECTS.include?(response.status)

          location = response.headers["location"].to_s
          return nil if location == check.to || (location.end_with?(check.to) && location.start_with?("http"))

          "redirects to #{location.inspect}, expected #{check.to.inspect}"
        end
      end
    end
  end
end
