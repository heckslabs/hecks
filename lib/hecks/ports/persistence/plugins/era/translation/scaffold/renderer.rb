module Hecks
  module Translation
    module Scaffold
      # Render an edge into .bluebook text — confident rules inline,
      # ambiguities as parse-refusing `unresolved` constructs, never
      # comments, so an unresolved file can only boot into a refusal.
      module Renderer
        # Renders a scaffolded edge as loadable `.bluebook` translation source.
        #
        # @param edge [Scaffold::Edge] the edge to render
        # @return [String] the edge's `.bluebook` text, ending in a newline
        def render(edge)
          lines = ["Hecks.data_translation #{edge.domain.inspect}, from: #{edge.from.inspect}, to: #{edge.to.inspect} do"]
          edge.aggregates.each do |aggregate|
            header = "  aggregate #{aggregate.name.inspect}"
            header += ", was: #{aggregate.was.inspect}" if aggregate.was
            lines << "#{header} do"
            aggregate.rules.each { |rule| lines << "    #{render_rule(rule)}" } unless aggregate.rules.empty?
            lines << "  end"
          end
          edge.retired.each { |name| lines << "  retired #{name.inspect}" }
          lines << "end"
          "#{lines.join("\n")}\n"
        end

        # Renders one scaffolded rule as a line of `.bluebook` source.
        #
        # @param rule [Hash{Symbol => Object}] a rule Hash as `Differ#attribute_rules` builds
        #   it: `:kind` plus `:from`/`:to`, or `:from`/`:candidates` for `:unresolved`
        # @return [String, nil] the rendered line; nil if `rule[:kind]` is none of `:rename`,
        #   `:move`, `:retype` or `:unresolved`
        def render_rule(rule)
          case rule[:kind]
          when :rename then "rename :#{rule[:from]}, to: :#{rule[:to]}"
          when :move then "move #{rule[:from].inspect}, to: #{rule[:to].inspect}"
          when :retype then "retype #{rule[:from].inspect}, to: #{rule[:to].inspect}"
          when :unresolved
            candidates = rule[:candidates].map { |candidate| render_path(candidate) }.join(", ")
            "unresolved #{render_path(rule[:from])}, candidates: [#{candidates}]"
          end
        end

        # Renders a path as bluebook source: a Symbol literal when bare, a String literal
        # when dotted.
        #
        # @param path [String, Symbol] a bare or dotted path
        # @return [String] `":name"` for a bare path, `path.inspect` for a dotted one
        def render_path(path) = path.to_s.include?(".") ? path.to_s.inspect : ":#{path}"
      end
    end
  end
end
