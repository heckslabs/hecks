module Hecksagain
  module Translation
    module Scaffold
      # Render an edge into .bluebook text — confident rules inline,
      # ambiguities as parse-refusing `unresolved` constructs, never
      # comments, so an unresolved file can only boot into a refusal.
      module Renderer
        def render(edge)
          lines = ["Hecks.data_translation #{edge.domain.inspect}, from: #{edge.from.inspect}, to: #{edge.to.inspect} do"]
          edge.aggregates.each do |aggregate|
            header = "  aggregate #{aggregate.name.inspect}"
            header += ", was: #{aggregate.was.inspect}" if aggregate.was
            if aggregate.rules.empty?
              lines << "#{header} do"
            else
              lines << "#{header} do"
              aggregate.rules.each { |rule| lines << "    #{render_rule(rule)}" }
            end
            lines << "  end"
          end
          edge.retired.each { |name| lines << "  retired #{name.inspect}" }
          lines << "end"
          "#{lines.join("\n")}\n"
        end

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

        def render_path(path) = path.include?(".") ? path.inspect : ":#{path}"
      end
    end
  end
end
