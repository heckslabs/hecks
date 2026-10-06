module Hecks
  module Translation
    module Scaffold
      # Renders an edge as .bluebook text. Ambiguities become `unresolved` constructs, not
      # comments, so an unresolved file can only boot into a refusal.
      module Renderer
        # Renders a scaffolded edge as loadable `.bluebook` translation source.
        #
        # @param edge [Scaffold::Edge] the edge to render
        # @return [String] the `.bluebook` text, ending in a newline
        def render(edge)
          lines = [render_header(edge)]
          edge.aggregates.each { |aggregate| lines.concat(render_aggregate(aggregate)) }
          edge.retired.each { |name| lines << "  retired #{name.inspect}" }
          lines << "end"
          "#{lines.join("\n")}\n"
        end

        # Renders the line opening the edge's translation block.
        def render_header(edge)
          "Hecks.data_translation #{edge.domain.inspect}, from: #{edge.from.inspect}, to: #{edge.to.inspect} do"
        end

        # Renders one aggregate's block as lines.
        def render_aggregate(aggregate)
          header = "  aggregate #{aggregate.name.inspect}"
          header += ", was: #{aggregate.was.inspect}" if aggregate.was
          ["#{header} do", *aggregate.rules.map { |rule| "    #{render_rule(rule)}" }, "  end"]
        end

        # Renders one scaffolded rule as a line of `.bluebook` source.
        #
        # @param rule [Hash{Symbol => Object}] a rule as `Differ#attribute_rules` builds it
        # @return [String, nil] the rendered line; nil for an unknown `rule[:kind]`
        def render_rule(rule)
          case rule[:kind]
          when :rename then "rename :#{rule[:from]}, to: :#{rule[:to]}"
          when :move then "move #{rule[:from].inspect}, to: #{rule[:to].inspect}"
          when :retype then "retype #{rule[:from].inspect}, to: #{rule[:to].inspect}"
          when :unresolved then render_unresolved(rule)
          end
        end

        # Renders an ambiguity as an `unresolved` construct listing its candidate paths.
        def render_unresolved(rule)
          candidates = rule[:candidates].map { |candidate| render_path(candidate) }.join(", ")
          "unresolved #{render_path(rule[:from])}, candidates: [#{candidates}]"
        end

        # Renders a bare path as a Symbol literal and a dotted path as a String literal.
        def render_path(path) = path.to_s.include?(".") ? path.to_s.inspect : ":#{path}"
      end
    end
  end
end
