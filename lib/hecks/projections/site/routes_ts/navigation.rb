# frozen_string_literal: true

module Hecks
  module Projections
    module Site
      module RoutesTs
        # The four navigation arrays of `routes.ts`: desktop, mobile, footer and admin.
        #
        # They hold every entry that has a slot, a switched-off page's too: an entry of an off page
        # carries its `switch` and `on: false`, and the site drops it while `pageIsOn(switch)` is
        # false. An entry of a page that is on carries neither.
        module Navigation
          module_function

          # @param table [Table] a checked table
          # @return [String] the four `NAV_*` constants, as TypeScript
          def render(table)
            items = table.rows + table.links
            [nav_const("NAV_DESKTOP", "The desktop navigation: a page with no group is its own entry; a group holds its pages.",
                       desktop(items)),
             nav_const("NAV_MOBILE", "The mobile navigation, in its own order.", mobile(items)),
             nav_const("NAV_FOOTER", "The footer columns, left to right, each with its links.", footer(items)),
             nav_const("NAV_ADMIN", "The admin navigation: each admin page under its key.", admin(items))].join("\n\n")
          end

          def nav_const(name, comment, entries)
            body = entries.map { |entry| "  #{RoutesTs.literal(entry)}," }
            "// #{comment}\nexport const #{name} = #{body.empty? ? "[]" : "[\n#{body.join("\n")}\n]"} as const;"
          end

          # One link: a row's or a link's path and label, the fragment a link names, and for a page
          # that is off the switch that turns it on.
          def entry(item, **before)
            link = { **before, path: item.path, label: item.label }
            link[:fragment] = item.fragment if item.respond_to?(:fragment) && item.fragment
            if item.off
              link[:switch] = item.switch
              link[:on] = false
            end
            link
          end

          def order_key(item, order) = [order, item.path, item.respond_to?(:fragment) ? item.fragment.to_s : ""]

          def desktop(items)
            entries = []
            items.reject { |item| item.nav_order.nil? }.sort_by { |item| order_key(item, item.nav_order) }
                 .each { |item| place(entries, item) }
            entries
          end

          # Adds the item to its group's entry, opening the group's entry when it is the first.
          def place(entries, item)
            group = item.nav_group
            slot = group && entries.find { |candidate| candidate[:group] == group }
            slot ? slot[:items] << entry(item) : entries << { group: group, items: [entry(item)] }
          end

          def mobile(items)
            items.reject { |item| item.mobile_order.nil? }.sort_by { |item| order_key(item, item.mobile_order) }
                 .map { |item| item.mobile_heading ? entry(item, heading: item.mobile_heading) : entry(item) }
          end

          def footer(items)
            ordered = items.select(&:footer_column).sort_by { |item| order_key(item, item.footer_order) }
            columns = ordered.group_by(&:footer_column)
            columns.sort_by { |name, group| [group.first.footer_order, name] }
                   .map { |name, group| { column: name, items: group.map { |item| entry(item) } } }
          end

          def admin(items)
            items.select(&:admin_key).sort_by { |item| [item.admin_order, item.admin_key] }
                 .map { |item| entry(item, key: item.admin_key) }
          end
        end
      end
    end
  end
end
