# frozen_string_literal: true

module Hecks
  module Projections
    module Site
      class Table
        # What no single row can show, and what a row contradicts in itself once its defaults are
        # filled: a path declared twice, a switch the rows disagree on, an off route that sits in a
        # navigation, an indexable route that is not public.
        class Checks
          SWITCH_ID = /\A[a-z][a-z0-9_]*\z/
          PUBLIC_MENUS = %w[desktop mobile footer].freeze

          # The navigation slots a row sits in.
          #
          # @param row [Row] a row
          # @return [Array<String>] some of `desktop`, `mobile`, `footer`, `admin`
          def self.navigation(row)
            { "desktop" => row.nav_order, "mobile" => row.mobile_order, "footer" => row.footer_column,
              "admin" => row.admin_key }.compact.keys
          end

          # @param rows [Array<Row>] the table's rows, defaults filled in
          # @param problems [Array<String>] collects each problem found, one line each
          def initialize(rows, problems)
            @rows = rows
            @problems = problems
          end

          # @return [void]
          def call
            check_duplicate_paths
            check_switches
            @rows.each { |row| check_row(row) }
            check_unique(@rows.filter_map(&:admin_key), "admin key")
            check_unique(@rows.map(&:source).grep(/\Aglobal:/), "source")
          end

          private

          def check_duplicate_paths
            seen = Hash.new { |hash, path| hash[path] = [] }
            @rows.each do |row|
              [row.path, *row.aliases].compact.each do |path|
                problem(path, "is declared twice") if seen[path].any? { |other| other.verbs.intersect?(row.verbs) }
                seen[path] << row
              end
            end
          end

          def check_switches
            @rows.reject { |row| row.switch.empty? }.group_by(&:switch).each do |id, rows|
              next if rows.map(&:off).uniq.size == 1

              problem("switch #{id}", "is on for #{rows.reject(&:off).map(&:path).join(', ')} and off for the rest")
            end
          end

          def check_row(row)
            path = row.path.to_s
            problem(path, "must start with /") unless path.start_with?("/")
            check_switch(row, path)
            check_redirect(row, path)
            check_navigation(row, path)
            check_indexing(row, path)
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
            if !targeted && row.redirect_to
              problem(path, "has redirect_to but is a #{row.kind}; only a redirect or rewrite has a target")
            end
            return if row.aliases.empty? || row.kind == "page"

            problem(path, "has aliases but is a #{row.kind}; aliases redirect to a page")
          end

          def check_navigation(row, path)
            slots = self.class.navigation(row)
            return if slots.empty?

            problem(path, "is off and sits in the #{slots.join(' and ')} navigation") if row.off
            problem(path, "sits in the navigation but is a #{row.kind}; only a page does") unless row.kind == "page"
            problem(path, "sits in the navigation and has a parameter") if path.match?(/[:*]/)
            problem(path, "sits in the navigation and has no label") if row.label.to_s.empty?
            check_menu_audience(row, path, slots)
          end

          def check_menu_audience(row, path, slots)
            public_slots = slots & PUBLIC_MENUS
            if row.auth != "public" && public_slots.any?
              problem(path, "is an admin page in the #{public_slots.join(' and ')} navigation")
            end
            problem(path, "is public and sits in the admin navigation") if row.auth == "public" && slots.include?("admin")
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
