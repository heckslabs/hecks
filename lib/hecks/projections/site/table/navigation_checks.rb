# frozen_string_literal: true

module Hecks
  module Projections
    module Site
      class Table
        # What a row or an extra link in the navigation must satisfy: a GET with a label and no
        # parameter, a heading only where it has a mobile slot, and a menu its audience may see.
        class NavigationChecks
          FRAGMENT = /\A[A-Za-z0-9][\w:.-]*\z/
          PUBLIC_MENUS = %w[desktop mobile footer].freeze

          # @param problems [Array<String>] collects each problem found, one line each
          def initialize(problems)
            @problems = problems
          end

          # @param row [Row] a row whose defaults are filled in
          # @param path [String] the row's path, as the problems name it
          # @return [void]
          def check_row(row, path)
            slots = Checks.navigation(row)
            return if slots.empty?

            unless row.verbs.include?("GET")
              problem(path, "sits in the navigation but answers #{row.verbs.join(",")}; a link is a GET")
            end
            problem(path, "sits in the navigation and has a parameter") if path.match?(/[:*]/)
            problem(path, "sits in the navigation and has no label") if row.label.to_s.empty?
            check_heading(row, path)
            check_menu_audience(row, path, slots)
          end

          # @param link [Link] an extra navigation entry
          # @return [void]
          def check_link(link)
            path = "NavLink #{link.path}"
            slots = Checks.navigation(link)
            problem(path, "sits in no navigation; give it nav_order, mobile_order, footer_column or admin_key") if slots.empty?
            check_link_target(link, path)
            check_heading(link, path)
            check_menu_audience(link, path, slots)
          end

          private

          def check_link_target(link, path)
            problem(path, "has a parameter; a link is to one page") if link.path.to_s.match?(/[:*]/)
            problem(path, "has no label") if link.label.to_s.empty?
            return unless link.fragment && !link.fragment.match?(FRAGMENT)

            problem(path, "has fragment #{link.fragment.inspect}; a fragment is an element id, written without #")
          end

          def check_heading(item, path)
            return unless item.mobile_heading
            return problem(path, "has a mobile_heading but no mobile_order") if item.mobile_order.nil?

            problem(path, "has an empty mobile_heading") if item.mobile_heading.strip.empty?
          end

          def check_menu_audience(row, path, slots)
            public_slots = slots & PUBLIC_MENUS
            if row.auth != "public" && public_slots.any?
              problem(path, "is an admin page in the #{public_slots.join(" and ")} navigation")
            end
            problem(path, "is public and sits in the admin navigation") if row.auth == "public" && slots.include?("admin")
          end

          def problem(label, text) = @problems << "#{label} #{text}"
        end
      end
    end
  end
end
