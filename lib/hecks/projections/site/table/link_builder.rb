# frozen_string_literal: true

module Hecks
  module Projections
    module Site
      class Table
        # One extra navigation entry that points at a route the table declares, optionally at a
        # fragment of its page. `off` and `switch` are copied from the route it points at.
        Link = Struct.new(:path, :fragment, :label, :nav_group, :nav_order, :mobile_order, :mobile_heading,
                          :footer_column, :footer_order, :admin_key, :admin_order, :off, :switch, :auth,
                          keyword_init: true)

        # Turns a declared `NavLink` member into a `Link`: checks its fields and their types, and
        # copies the facts it shares with the route it points at.
        class LinkBuilder
          # The fields a link may carry, with the Ruby class each takes.
          FIELDS = { path: String, fragment: String, label: String, nav_group: String, nav_order: Integer,
                     mobile_order: Integer, mobile_heading: String, footer_column: String,
                     footer_order: Integer, admin_key: String, admin_order: Integer }.freeze

          # @param rows [Array<Row>] the table's rows, which a link points at
          # @param problems [Array<String>] collects each problem found, one line each
          def initialize(rows, problems)
            @rows = rows
            @problems = problems
          end

          # @param member [Hash{Symbol => Object}] the declared fields of one link
          # @param index [Integer] the link's position, for a message about a link with no path
          # @return [Link] the link; its problems are in `problems`
          def call(member, index)
            label = "NavLink #{member[:path] || "row #{index + 1}"}"
            fields = checked_fields(member, label)
            target = @rows.find { |row| row.path == fields[:path] && row.verbs.include?("GET") }
            problem(label, "points at no route that answers GET; declare the route first") unless target
            link = Link.new(**fields, off: target ? target.off : false, switch: target ? target.switch : "",
                                      auth: target ? target.auth : "public")
            link.footer_order ||= 0 if link.footer_column
            link.admin_order ||= 0 if link.admin_key
            link
          end

          private

          def checked_fields(member, label)
            member.each_key do |key|
              problem(label, "has no field #{key}; fields are #{FIELDS.keys.join(', ')}") unless FIELDS.key?(key)
            end
            known = member.slice(*FIELDS.keys)
            known.each do |key, value|
              next if value.is_a?(FIELDS.fetch(key))

              problem(label, "has #{key} #{value.inspect}; #{key} is a #{FIELDS.fetch(key)}")
            end
            problem(label, "needs a path") unless known[:path]
            known
          end

          def problem(label, text) = @problems << "#{label} #{text}"
        end
      end
    end
  end
end
