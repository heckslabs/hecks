require_relative "html"
require_relative "field_shape"
require_relative "record_table"

module Hecks
  module Forms
    # The two pages a `.bluebook` doesn't declare but a browsing developer
    # always wants: every record of an aggregate, and one record's own
    # state plus what it can legally do next. Neither is a `query` — they
    # read the repository directly, the same way `AggregateDoor#all`/`#find`
    # do (facade/surface/aggregate_door.rb) — so they exist for every
    # aggregate whether or not its bluebook declared a query at all.
    module RecordRenderer
      # Renders one aggregate's index page: every record as a table, plus creating and
      # verb links.
      #
      # @param registry [Runtime::Registry] the booted registry to read the repository from
      # @param domain [String] the owning chapter's name
      # @param aggregate [Bluebook::Aggregate] the aggregate to list
      # @return [String] the page body markup
      def self.index(registry:, domain:, aggregate:)
        instances = registry.repository(domain, aggregate).all
        <<~HTML
          <h1>#{Escape.html("#{domain}::#{aggregate.hecks_name}")}</h1>
          #{%(<p class="goal">#{Escape.html(aggregate.description)}</p>) if aggregate.description}
          #{creating_links(domain, aggregate)}
          <h2>Records (#{instances.size})</h2>
          #{RecordTable.render(aggregate, instances, domain: domain)}
          #{verb_list(domain, aggregate)}
        HTML
      end

      # Renders one link per creating command, to that command's own form page.
      #
      # @param domain [String] the owning chapter's name
      # @param aggregate [Bluebook::Aggregate] the aggregate whose creating commands to link
      # @return [String] the link row markup; `""` when the aggregate declares no
      #   creating command
      def self.creating_links(domain, aggregate)
        creators = aggregate.commands.select(&:creates?)
        return "" if creators.empty?

        links = creators.map do |cmd|
          %(<a class="button" href="/#{domain}/#{aggregate.hecks_name}/#{cmd.hecks_name}.html">) \
            "+ #{Escape.html(cmd.hecks_name)}</a>"
        end
        %(<div class="actions">#{links.join}</div>)
      end

      # Renders one record's own state, its lifecycle badge, and the commands and
      # queries that act on it.
      #
      # @param registry [Runtime::Registry] the booted registry to read the repository from
      # @param domain [String] the owning chapter's name
      # @param aggregate [Bluebook::Aggregate] the aggregate the record belongs to
      # @param id [String] the record's identity
      # @return [String, nil] the page body markup; `nil` when the repository holds no
      #   such record
      def self.show(registry:, domain:, aggregate:, id:)
        instance = registry.repository(domain, aggregate).find(id)
        return nil unless instance

        state = instance.state
        current = aggregate.lifecycle && state[aggregate.lifecycle.field]
        <<~HTML
          <h1>#{Escape.html("#{domain}::#{aggregate.hecks_name}")} <span class="mono">#{Escape.html(id)}</span></h1>
          #{%(<span class="badge role">#{Escape.html(aggregate.lifecycle.field)}: #{Escape.html(current)}</span>) if current}
          #{state_table(state)}
          <h2>Commands</h2>
          #{command_links(domain, aggregate, id, current)}
          #{query_links(domain, aggregate)}
        HTML
      end

      # Renders a record's full state as a two-column key/value table.
      #
      # @param state [Hash{Symbol => Object}] the record's state, as `Runtime::Instance#state`
      #   holds it
      # @return [String] the table markup
      def self.state_table(state)
        rows = state.map do |key, value|
          "<tr><th>#{Escape.html(Humanize.label(key.to_s))}</th><td>#{Escape.html(render_value(value))}</td></tr>"
        end
        %(<div class="table-scroll"><table><tbody>#{rows.join}</tbody></table></div>)
      end

      # Renders one state value as display text, unwrapping value objects, Hashes and
      # Arrays recursively.
      #
      # `Value.materialize` first — a stored field is a `Runtime::Value`
      # wherever its attribute is a value object, not a plain Hash (see
      # record_table.rb's own note on the same read).
      #
      # @param value [Object] a state field's raw value
      # @return [String] `"key: value"` pairs joined by `", "` for a Hash; elements
      #   joined by `"; "` for an Array; `value.to_s` otherwise
      def self.render_value(value)
        case (value = Runtime::Value.materialize(value))
        when Hash then value.map { |k, v| "#{k}: #{render_value(v)}" }.join(", ")
        when Array then value.map { |v| render_value(v) }.join("; ")
        else value.to_s
        end
      end

      # Renders one link per command that could actually apply to this record right now.
      #
      # Every non-creating command, except a lifecycle transition that does
      # not apply from the record's current state — the same rule
      # `Rules#admissible_transition` enforces at dispatch, read here so a
      # link that would only refuse is never offered in the first place.
      #
      # @param domain [String] the owning chapter's name
      # @param aggregate [Bluebook::Aggregate] the aggregate the record belongs to
      # @param id [String] the record's identity, linked as the command's `to=`
      # @param current_state [String, Symbol, nil] the record's current lifecycle value;
      #   `nil` when the aggregate declares no lifecycle
      # @return [String] one `<li>` link per applicable command; a message naming none
      #   apply when there are none
      def self.command_links(domain, aggregate, id, current_state)
        commands = aggregate.commands.reject(&:creates?).select { |cmd| applies?(aggregate, cmd, current_state) }
        return "<p><em>No commands act on an existing #{Escape.html(aggregate.hecks_name)}.</em></p>" if commands.empty?

        items = commands.map do |cmd|
          # L12 — the id is free-form (S3): percent-encoded as the query
          # value (a raw `&` here would smuggle a second bogus query
          # parameter), then the assembled href is attribute-escaped as
          # usual.
          href = "/#{domain}/#{aggregate.hecks_name}/#{cmd.hecks_name}.html?to=#{Escape.url(id)}"
          %(<li><a href="#{Escape.attr(href)}"><span>#{Escape.html(cmd.hecks_name)}</span>) \
            "<span class=\"kind\">#{Escape.html(cmd.goal.to_s)}</span></a></li>"
        end
        %(<ul class="verb-list">#{items.join}</ul>)
      end

      # Tells whether a command's own lifecycle transitions admit the record's current
      # state, the same rule `Rules#admissible_transition` enforces at dispatch.
      #
      # @param aggregate [Bluebook::Aggregate] the aggregate the command belongs to
      # @param command [Bluebook::Command] the command to check
      # @param current_state [String, Symbol, nil] the record's current lifecycle value
      # @return [Boolean] true when the command declares no lifecycle transitions at
      #   all, or when one of its transitions has no `from` or lists `current_state`
      #   among its `from` values
      def self.applies?(aggregate, command, current_state)
        transitions = aggregate.lifecycle&.transitions_for(command.hecks_name) || []
        return true if transitions.empty?

        transitions.any? { |t| t.from.nil? || Array(t.from).map(&:to_s).include?(current_state.to_s) }
      end

      # Renders one link per declared query, under a "Queries" heading.
      #
      # @param domain [String] the owning chapter's name
      # @param aggregate [Bluebook::Aggregate] the aggregate whose queries to link
      # @return [String] the queries section markup; `""` when the aggregate declares
      #   no query
      def self.query_links(domain, aggregate)
        return "" if aggregate.queries.empty?

        items = aggregate.queries.map do |query|
          %(<li><a href="/#{domain}/#{aggregate.hecks_name}/#{query.hecks_name}.html">) \
            "<span>#{Escape.html(query.hecks_name)}</span><span class=\"kind\">query</span></a></li>"
        end
        %(<h2>Queries</h2><ul class="verb-list">#{items.join}</ul>)
      end

      # Renders the aggregate's full command-and-query list, unfiltered by lifecycle
      # state — the index page's own "everything this aggregate can do" section.
      #
      # @param domain [String] the owning chapter's name
      # @param aggregate [Bluebook::Aggregate] the aggregate to list
      # @return [String] the full list markup; `""` when the aggregate declares neither
      #   a non-creating command nor a query
      def self.verb_list(domain, aggregate)
        commands = aggregate.commands.reject(&:creates?)
        return "" if commands.empty? && aggregate.queries.empty?

        cmd_items = commands.map do |c|
          %(<li><a href="/#{domain}/#{aggregate.hecks_name}/#{c.hecks_name}.html">) \
            "<span>#{Escape.html(c.hecks_name)}</span><span class=\"kind\">command</span></a></li>"
        end
        query_items = aggregate.queries.map do |q|
          %(<li><a href="/#{domain}/#{aggregate.hecks_name}/#{q.hecks_name}.html">) \
            "<span>#{Escape.html(q.hecks_name)}</span><span class=\"kind\">query</span></a></li>"
        end
        %(<h2>Every command &amp; query on #{Escape.html(aggregate.hecks_name)}</h2>) \
          "<ul class=\"verb-list\">#{(cmd_items + query_items).join}</ul>"
      end
    end
  end
end
