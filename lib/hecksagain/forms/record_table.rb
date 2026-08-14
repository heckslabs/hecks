require_relative "html"
require_relative "field_shape"

module Hecksagain
  module Forms
    # The one shape every renderer in this directory reads a record as —
    # `id` plus its state hash. `Runtime::Instance` already answers both,
    # so `repository.all`'s own records pass straight through; a QUERY's
    # answer does not (`QueryInterpreter#call` flattens `{id:}.merge(state)`
    # into one hash with no method to call — see
    # docs/command-form-and-query-form-bluebook.md's note on why), so
    # app.rb wraps those results in one of these before they ever reach a
    # renderer, and every renderer here only has to know one shape.
    Record = Struct.new(:id, :state)

    # An array of Record (or anything answering `#id`/`#state` — a
    # Runtime::Instance qualifies without wrapping) -> an HTML table.
    # Shared by the aggregate index page (record_renderer.rb) and a
    # query's own results (query_form_renderer.rb) — the same records
    # read the same columns either way.
    module RecordTable
      def self.columns(aggregate)
        lifecycle = aggregate.lifecycle&.field
        scalars = aggregate.attributes.reject { |a| a.reference? || a.list? }.map(&:name)
        [*aggregate.identity_heads, lifecycle, *scalars].compact.uniq.first(7)
      end

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
        href = "/#{domain}/#{aggregate.hecks_name}/#{instance.id}.html"
        "<tr><td><a href=\"#{Escape.attr(href)}\">#{Escape.html(instance.id)}</a></td>#{cells}</tr>"
      end

      def self.cell(instance, name)
        # `state` holds `Runtime::Value` wherever an attribute is a value
        # object, not a plain Hash — `.materialize` is the runtime's own
        # unwrap (value.rb), the same one a `to_h` read anywhere else in
        # this codebase goes through, so a table cell agrees with every
        # other reader about what a stored field actually contains.
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
