require_relative "html"
require_relative "field_shape"

module Hecks
  module Forms
    # A record as every renderer here reads it: `id` plus its state hash.
    # Query results are flat hashes, so they are wrapped in one before rendering.
    Record = Struct.new(:id, :state)

    # Records (a Record or anything answering `#id`/`#state`) as an HTML table.
    module RecordTable
      # Identity, lifecycle state, then scalar attributes, capped at seven columns.
      def self.columns(aggregate)
        lifecycle = aggregate.lifecycle&.field
        scalars = aggregate.attributes.reject { |a| a.reference? || a.list? }.map(&:name)
        [*aggregate.identity_heads, lifecycle, *scalars].compact.uniq.first(7)
      end

      # Renders records as an HTML table, one row per record.
      def self.render(aggregate, instances, domain:)
        cols = columns(aggregate)
        head = (["id"] + cols).map { |name| "<th>#{Escape.html(Humanize.label(name.to_s))}</th>" }.join
        rows = instances.map { |instance| row(instance, aggregate, cols, domain) }
        return "<p><em>No records.</em></p>" if rows.empty?

        <<~HTML
          <div class="table-scroll"><table>
            <thead><tr>#{head}</tr></thead>
            <tbody>#{rows.join}</tbody>
          </table></div>
        HTML
      end

      def self.row(instance, aggregate, cols, domain)
        cells = cols.map { |name| "<td>#{Escape.html(cell(instance, name))}</td>" }.join
        # The id is free-form, so it is percent-encoded in the path.
        href = "/#{domain}/#{aggregate.hecks_name}/#{Escape.path(instance.id)}.html"
        "<tr><td><a href=\"#{Escape.attr(href)}\">#{Escape.html(instance.id)}</a></td>#{cells}</tr>"
      end

      def self.cell(instance, name)
        # `state` holds a `Runtime::Value` wherever an attribute is a value object.
        value = Runtime::Value.materialize(instance.state[name])
        case value
        when Hash then value.values.first
        when nil then ""
        else value
        end
      end
    end
  end
end
