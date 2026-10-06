# frozen_string_literal: true

require_relative "../edge/pattern"
require_relative "navigation_checks"

module Hecks
  module Projections
    module Site
      class Table
        # What no single row can show, and what a row contradicts in itself once its defaults are
        # filled: a path declared twice, a switch the rows disagree on, a navigation entry that
        # cannot be linked to, an indexable route that is not public, a public route beneath a
        # prefix that is not.
        class Checks
          SWITCH_ID = /\A[a-z][a-z0-9_]*\z/

          # The navigation slots a row sits in.
          #
          # @param row [Row, Link] a row or link
          # @return [Array<String>] some of `desktop`, `mobile`, `footer`, `admin`
          def self.navigation(row)
            { "desktop" => row.nav_order, "mobile" => row.mobile_order, "footer" => row.footer_column,
              "admin" => row.admin_key }.compact.keys
          end

          # @param rows [Array<Row>] the table's rows, defaults filled in
          # @param problems [Array<String>] collects each problem found, one line each
          # @param links [Array<Link>] the table's extra navigation entries
          def initialize(rows, problems, links: [])
            @rows = rows
            @links = links
            @problems = problems
            @navigation = NavigationChecks.new(problems)
          end

          # @return [void]
          def call
            check_duplicate_paths
            check_switches
            @rows.each { |row| check_row(row) }
            @links.each { |link| @navigation.check_link(link) }
            check_unique((@rows + @links).filter_map(&:admin_key), "admin key")
            check_unique(@rows.map(&:source).grep(/\Aglobal:/), "source")
          end

          private

          def check_duplicate_paths
            seen = Hash.new { |hash, path| hash[path] = [] }
            @rows.each { |row| [row.path, *row.aliases].compact.each { |path| claim(seen, row, path) } }
          end

          def claim(seen, row, path)
            problem(path, "is declared twice") if seen[path].any? { |other| other.verbs.intersect?(row.verbs) }
            seen[path] << row
          end

          def check_switches
            @rows.reject { |row| row.switch.empty? }.group_by(&:switch).each do |id, rows|
              check_switch_agreement(id, rows)
            end
          end

          def check_switch_agreement(id, rows)
            return if rows.map(&:off).uniq.size == 1

            problem("switch #{id}", "is on for #{rows.reject(&:off).map(&:path).join(", ")} and off for the rest")
          end

          def check_row(row)
            path = row.path.to_s
            problem(path, "must start with /") unless path.start_with?("/")
            check_switch(row, path)
            check_redirect(row, path)
            check_aliases(row, path)
            @navigation.check_row(row, path)
            check_indexing(row, path)
            check_beneath_prefix(row, path)
            return unless row.preview == "draft" && row.source == "none"

            problem(path, "previews as a draft but has source none; a draft preview needs a global: or collection: source")
          end

          def check_switch(row, path)
            problem(path, "is off but names no switch (add switch: \"<id>\")") if row.off && row.switch.empty?
            return if row.switch.empty? || row.switch.match?(SWITCH_ID)

            problem(path, "has switch #{row.switch.inspect}; a switch is a lowercase id")
          end

          def check_redirect(row, path)
            targeted = %w[redirect rewrite].include?(row.kind)
            problem(path, "is a #{row.kind} and needs redirect_to") if targeted && row.redirect_to.to_s.empty?
            return unless !targeted && row.redirect_to

            problem(path, "has redirect_to but is a #{row.kind}; only a redirect or rewrite has a target")
          end

          def check_aliases(row, path)
            return if row.aliases.empty? || row.kind == "page"

            problem(path, "has aliases but is a #{row.kind}; aliases redirect to a page")
          end

          # A public route under a prefix that is not public (the sign-in page beside the admin
          # pages) inherits nothing from the prefix, so the row has to say what it is: its cache
          # class is declared, not derived from its auth.
          def check_beneath_prefix(row, path)
            return if row.auth != "public" || row.explicit_cache || row.path.nil?

            prefix = non_public_prefix(row)
            return unless prefix

            problem(path, "is public but sits beneath #{prefix.path}, which is #{prefix.auth}; " \
                          "name its cache class (cache: \"no_store\" for a sign-in page) to say that is meant")
          end

          def non_public_prefix(row)
            pattern = Edge::Pattern.edge(row.path)
            @rows.find do |other|
              other.auth != "public" && other.path && Edge::Pattern.strictly_covers?(Edge::Pattern.edge(other.path), pattern)
            end
          end

          def check_indexing(row, path)
            return unless row.indexable

            problem(path, "is indexable but is #{row.auth}") unless row.auth == "public"
            problem(path, "is indexable but is off") if row.off
          end

          def check_unique(values, name)
            values.tally.each { |value, count| problem("#{name} #{value}", "is used by #{count} routes") if count > 1 }
          end

          def problem(label, text) = @problems << "#{label} #{text}"
        end
      end
    end
  end
end
