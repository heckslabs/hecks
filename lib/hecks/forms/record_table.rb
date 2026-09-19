require_relative "html"
require_relative "field_shape"

module Hecks
  module Forms
    # The one shape every renderer in this directory reads a record as —
    # `id` plus its state hash. `Runtime::Instance` already answers both,
    # so `repository.all`'s own records pass straight through; a query's
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
      # Picks which fields to show as columns: identity, lifecycle state, then scalar
      # attributes, capped at seven.
      #
      # @param aggregate [Bluebook::Aggregate] the aggregate whose records will be shown
      # @return [Array<Symbol>] up to 7 unique field names, in that order; excludes
      #   reference and list attributes
      def self.columns(aggregate)
        lifecycle = aggregate.lifecycle&.field
        scalars = aggregate.attributes.reject { |a| a.reference? || a.list? }.map(&:name)
        [*aggregate.identity_heads, lifecycle, *scalars].compact.uniq.first(7)
      end

      # Renders a list of records as an HTML table, one row per record.
      #
      # @param aggregate [Bluebook::Aggregate] the aggregate the records belong to
      # @param instances [Array<Runtime::Instance, Forms::Record>] the records to render;
      #   anything answering `#id`/`#state` works
      # @param domain [String] the owning chapter's name, for building each row's link
      # @return [String] the table markup; `"<p><em>No records.</em></p>"` when
      #   `instances` is empty
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

      # Renders one record's own table row, linked to its show page.
      #
      # @param instance [Runtime::Instance, Forms::Record] the record to render
      # @param aggregate [Bluebook::Aggregate] the aggregate the record belongs to
      # @param cols [Array<Symbol>] the column field names, as `columns` returns them
      # @param domain [String] the owning chapter's name, for building the row's link
      # @return [String] the `<tr>` markup
      def self.row(instance, aggregate, cols, domain)
        cells = cols.map { |name| "<td>#{Escape.html(cell(instance, name))}</td>" }.join
        # L12 — the id is free-form (S3): percent-encoded as the path
        # segment, HTML-escaped as the link text, and the assembled href
        # is itself attribute-escaped (belt-and-suspenders — nothing else
        # in `href` is untrusted, but this matches the convention used
        # everywhere else an href is built from parts).
        href = "/#{domain}/#{aggregate.hecks_name}/#{Escape.path(instance.id)}.html"
        "<tr><td><a href=\"#{Escape.attr(href)}\">#{Escape.html(instance.id)}</a></td>#{cells}</tr>"
      end

      # Reads one field's value for display, unwrapped to a single cell value.
      #
      # @param instance [Runtime::Instance, Forms::Record] the record to read
      # @param name [Symbol] the field name to read
      # @return [Object] the field's own value; for a Hash-shaped value object, its
      #   first member's value; `""` for `nil`
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
