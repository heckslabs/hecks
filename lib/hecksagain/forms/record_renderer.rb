require_relative "html"
require_relative "field_shape"
require_relative "record_table"

module Hecksagain
  module Forms
    # The two pages a `.bluebook` doesn't declare but a browsing developer
    # always wants: every record of an aggregate, and one record's own
    # state plus what it can legally do next. Neither is a `query` — they
    # read the repository directly, the same way `AggregateDoor#all`/`#find`
    # do (facade/surface/aggregate_door.rb) — so they exist for every
    # aggregate whether or not its bluebook declared a query at all.
    module RecordRenderer
      def self.index(registry:, domain:, aggregate:)
        instances = registry.repository(domain, aggregate).all
        <<~HTML
          <h1>#{Escape.html("#{domain}::#{aggregate.hecks_name}")}</h1>
          #{aggregate.description ? %(<p class="goal">#{Escape.html(aggregate.description)}</p>) : ''}
          #{creating_links(domain, aggregate)}
          <h2>Records (#{instances.size})</h2>
          #{RecordTable.render(aggregate, instances, domain: domain)}
          #{verb_list(domain, aggregate)}
        HTML
      end

      def self.creating_links(domain, aggregate)
        creators = aggregate.commands.select(&:creates?)
        return "" if creators.empty?

        links = creators.map { |cmd| %(<a class="button" href="/#{domain}/#{aggregate.hecks_name}/#{cmd.hecks_name}.html">+ #{Escape.html(cmd.hecks_name)}</a>) }
        %(<div class="actions">#{links.join}</div>)
      end

      def self.show(registry:, domain:, aggregate:, id:)
        instance = registry.repository(domain, aggregate).find(id)
        return nil unless instance

        state = instance.state
        current = aggregate.lifecycle && state[aggregate.lifecycle.field]
        <<~HTML
          <h1>#{Escape.html("#{domain}::#{aggregate.hecks_name}")} <span class="mono">#{Escape.html(id)}</span></h1>
          #{current ? %(<span class="badge role">#{Escape.html(aggregate.lifecycle.field)}: #{Escape.html(current)}</span>) : ''}
          #{state_table(state)}
          <h2>Commands</h2>
          #{command_links(domain, aggregate, id, current)}
          #{query_links(domain, aggregate)}
        HTML
      end

      def self.state_table(state)
        rows = state.map { |key, value| "<tr><th>#{Escape.html(Humanize.label(key.to_s))}</th><td>#{Escape.html(render_value(value))}</td></tr>" }
        %(<div class="table-scroll"><table><tbody>#{rows.join}</tbody></table></div>)
      end

      # `Value.materialize` first — a stored field is a `Runtime::Value`
      # wherever its attribute is a value object, not a plain Hash (see
      # record_table.rb's own note on the same read).
      def self.render_value(value)
        case (value = Runtime::Value.materialize(value))
        when Hash then value.map { |k, v| "#{k}: #{render_value(v)}" }.join(", ")
        when Array then value.map { |v| render_value(v) }.join("; ")
        else value.to_s
        end
      end

      # Every non-creating command, EXCEPT a lifecycle transition that does
      # not apply from the record's current state — the same rule
      # `Rules#admissible_transition` enforces at dispatch, read here so a
      # link that would only refuse is never offered in the first place.
      def self.command_links(domain, aggregate, id, current_state)
        commands = aggregate.commands.reject(&:creates?).select { |cmd| applies?(aggregate, cmd, current_state) }
        return "<p><em>No commands act on an existing #{Escape.html(aggregate.hecks_name)}.</em></p>" if commands.empty?

        items = commands.map do |cmd|
          href = "/#{domain}/#{aggregate.hecks_name}/#{cmd.hecks_name}.html?id=#{Escape.attr(id)}"
          %(<li><a href="#{href}"><span>#{Escape.html(cmd.hecks_name)}</span><span class="kind">#{Escape.html(cmd.goal.to_s)}</span></a></li>)
        end
        %(<ul class="verb-list">#{items.join}</ul>)
      end

      def self.applies?(aggregate, command, current_state)
        transitions = aggregate.lifecycle&.transitions_for(command.hecks_name) || []
        return true if transitions.empty?

        transitions.any? { |t| t.from.nil? || Array(t.from).map(&:to_s).include?(current_state.to_s) }
      end

      def self.query_links(domain, aggregate)
        return "" if aggregate.queries.empty?

        items = aggregate.queries.map do |query|
          %(<li><a href="/#{domain}/#{aggregate.hecks_name}/#{query.hecks_name}.html"><span>#{Escape.html(query.hecks_name)}</span><span class="kind">query</span></a></li>)
        end
        %(<h2>Queries</h2><ul class="verb-list">#{items.join}</ul>)
      end

      def self.verb_list(domain, aggregate)
        commands = aggregate.commands.reject(&:creates?)
        return "" if commands.empty? && aggregate.queries.empty?

        cmd_items = commands.map { |c| %(<li><a href="/#{domain}/#{aggregate.hecks_name}/#{c.hecks_name}.html"><span>#{Escape.html(c.hecks_name)}</span><span class="kind">command</span></a></li>) }
        query_items = aggregate.queries.map { |q| %(<li><a href="/#{domain}/#{aggregate.hecks_name}/#{q.hecks_name}.html"><span>#{Escape.html(q.hecks_name)}</span><span class="kind">query</span></a></li>) }
        %(<h2>Every command &amp; query on #{Escape.html(aggregate.hecks_name)}</h2><ul class="verb-list">#{(cmd_items + query_items).join}</ul>)
      end
    end
  end
end
