require_relative "html"
require_relative "field_shape"
require_relative "record_table"

module Hecks
  module Forms
    # The index and show pages every aggregate gets, whether or not it declares a query.
    # They read the repository directly, like `AggregateDoor#all`/`#find`.
    module RecordRenderer
      # Renders the page listing every record of one aggregate.
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

      def self.creating_links(domain, aggregate)
        creators = aggregate.commands.select(&:creates?)
        return "" if creators.empty?

        links = creators.map do |cmd|
          %(<a class="button" href="/#{domain}/#{aggregate.hecks_name}/#{cmd.hecks_name}.html">) \
            "+ #{Escape.html(cmd.hecks_name)}</a>"
        end
        %(<div class="actions">#{links.join}</div>)
      end

      # Renders one record's state plus the commands and queries it can dispatch next.
      # Returns nil when no record has that id.
      def self.show(registry:, domain:, aggregate:, id:)
        instance = registry.repository(domain, aggregate).find(id)
        return nil unless instance

        state = instance.state
        current = aggregate.lifecycle && state[aggregate.lifecycle.field]
        <<~HTML
          <h1>#{Escape.html("#{domain}::#{aggregate.hecks_name}")} <span class="mono">#{Escape.html(id)}</span></h1>
          #{lifecycle_badge(aggregate, current)}
          #{state_table(state)}
          <h2>Commands</h2>
          #{command_links(domain, aggregate, id, current)}
          #{query_links(domain, aggregate)}
        HTML
      end

      # @return [String, nil] the badge naming the lifecycle field and its state; nil when the
      #   record has no lifecycle state
      def self.lifecycle_badge(aggregate, current)
        return unless current

        %(<span class="badge role">#{Escape.html(aggregate.lifecycle.field)}: #{Escape.html(current)}</span>)
      end

      def self.state_table(state)
        rows = state.map do |key, value|
          "<tr><th>#{Escape.html(Humanize.label(key.to_s))}</th><td>#{Escape.html(render_value(value))}</td></tr>"
        end
        %(<div class="table-scroll"><table><tbody>#{rows.join}</tbody></table></div>)
      end

      # A stored field is a `Runtime::Value` wherever its attribute is a value object.
      def self.render_value(value)
        case (value = Runtime::Value.materialize(value))
        when Hash then value.map { |k, v| "#{k}: #{render_value(v)}" }.join(", ")
        when Array then value.map { |v| render_value(v) }.join("; ")
        else value.to_s
        end
      end

      # Omits lifecycle transitions that dispatch would refuse from the current state.
      def self.command_links(domain, aggregate, id, current_state)
        commands = aggregate.commands.reject(&:creates?).select { |cmd| applies?(aggregate, cmd, current_state) }
        return "<p><em>No commands act on an existing #{Escape.html(aggregate.hecks_name)}.</em></p>" if commands.empty?

        items = commands.map { |cmd| command_item(domain, aggregate, cmd, id) }
        %(<ul class="verb-list">#{items.join}</ul>)
      end

      # @return [String] the list item linking to the command's form, addressed to record `id`
      def self.command_item(domain, aggregate, cmd, id)
        # The id is free-form, so it is percent-encoded as a query value.
        href = "/#{domain}/#{aggregate.hecks_name}/#{cmd.hecks_name}.html?to=#{Escape.url(id)}"
        %(<li><a href="#{Escape.attr(href)}"><span>#{Escape.html(cmd.hecks_name)}</span>) \
          "<span class=\"kind\">#{Escape.html(cmd.goal.to_s)}</span></a></li>"
      end

      def self.applies?(aggregate, command, current_state)
        transitions = aggregate.lifecycle&.transitions_for(command.hecks_name) || []
        return true if transitions.empty?

        transitions.any? { |t| t.from.nil? || Array(t.from).map(&:to_s).include?(current_state.to_s) }
      end

      def self.query_links(domain, aggregate)
        return "" if aggregate.queries.empty?

        items = aggregate.queries.map { |query| verb_item(domain, aggregate, query, "query") }
        %(<h2>Queries</h2><ul class="verb-list">#{items.join}</ul>)
      end

      def self.verb_list(domain, aggregate)
        commands = aggregate.commands.reject(&:creates?)
        return "" if commands.empty? && aggregate.queries.empty?

        cmd_items = commands.map { |c| verb_item(domain, aggregate, c, "command") }
        query_items = aggregate.queries.map { |q| verb_item(domain, aggregate, q, "query") }
        %(<h2>Every command &amp; query on #{Escape.html(aggregate.hecks_name)}</h2>) \
          "<ul class=\"verb-list\">#{(cmd_items + query_items).join}</ul>"
      end

      # @param kind [String] the word shown beside the verb, `"command"` or `"query"`
      # @return [String] the list item linking to the verb's own page
      def self.verb_item(domain, aggregate, verb, kind)
        %(<li><a href="/#{domain}/#{aggregate.hecks_name}/#{verb.hecks_name}.html">) \
          "<span>#{Escape.html(verb.hecks_name)}</span><span class=\"kind\">#{kind}</span></a></li>"
      end
    end
  end
end
