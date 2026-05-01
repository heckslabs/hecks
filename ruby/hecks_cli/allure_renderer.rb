# Hecks::CLI::AllureRenderer
#
# Renders a domain as an interactive terminal UI using panel expressions.
# Each IR concept expresses itself with a color, icon, and render_mode.
# No gems — raw ANSI. Composed from source by Hecks.
#
#   renderer = AllureRenderer.new("pizzas.bluebook")
#   renderer.run
#
module Hecks
  class CLI
    class AllureRenderer
      COLORS = {
        attribute:    "\e[32m",  command:      "\e[34m",
        event:        "\e[35m",  lifecycle:    "\e[95m",
        policy:       "\e[31m",  value_object: "\e[33m",
        reference:    "\e[33m",  given:        "\e[93m",
        mutation:     "\e[36m",
      }.freeze

      ICONS = {
        attribute: "A", command: "⌘", event: "⚡", lifecycle: "↻",
        policy: "P", value_object: "◇", reference: "→",
        given: "✓", mutation: "Δ",
      }.freeze

      R = "\e[0m"
      B = "\e[1m"
      D = "\e[2m"

      def initialize(bluebook_path)
        @path = bluebook_path
      end

      def run
        @domain = boot_domain
        clear
        header
        aggregates
        policies
        footer
        prompt_loop
      end

      private

      def boot_domain
        Hecks::DSL::AggregateBuilder::VoTypeResolution.with_vo_constants do
          Kernel.load(File.expand_path(@path))
        end
        Hecks.last_domain
      end

      def clear = print("\e[2J\e[H")

      def header
        n = @domain.name
        ac = @domain.aggregates.size
        cc = @domain.aggregates.sum { |a| a.commands.size }
        pc = @domain.policies.size
        w = [n.length + 20, 60].max
        puts "┌#{"─" * w}┐"
        puts "│#{B} #{n} #{R}#{"— #{ac} aggregates, #{cc} commands, #{pc} policies".ljust(w - n.length - 2)}│"
        puts "└#{"─" * w}┘"
        puts
      end

      def aggregates
        @domain.aggregates.each_with_index { |a, i| aggregate_panel(a, i); puts }
      end

      def aggregate_panel(agg, idx)
        desc = agg.description.to_s.empty? ? "" : " — #{agg.description}"
        puts "#{B}[#{idx + 1}] #{agg.name}#{R}#{D}#{desc}#{R}"

        section(:attribute, agg.attributes) do |a|
          d = a.default ? " = #{a.default}" : ""
          "#{a.name} : #{a.type}#{d}"
        end

        section(:value_object, agg.value_objects) do |vo|
          "#{vo.name} (#{vo.attributes.map(&:name).join(", ")})"
        end

        refs = agg.respond_to?(:references) ? Array(agg.references) : []
        section(:reference, refs) { |r| r.respond_to?(:type) ? r.type.to_s : r.name.to_s }

        section(:command, agg.commands) do |c|
          actor = c.respond_to?(:actors) && !c.actors.empty? ? c.actors.first : nil
          actors = actor ? " [#{actor.respond_to?(:name) ? actor.name : actor}]" : ""
          emits = c.respond_to?(:emits) && c.emits ? " → #{c.emits}" : ""
          g = c.givens.size
          m = c.mutations.size
          beh = (g + m) > 0 ? " (#{g}g #{m}m)" : ""
          "#{c.name}#{actors}#{emits}#{beh}"
        end

        evts = agg.respond_to?(:events) ? Array(agg.events) : []
        section(:event, evts) { |e| e.respond_to?(:name) ? e.name : e.to_s }

        lifecycle_panel(agg)
        behavior_details(agg)
      end

      def section(concept, items)
        return if items.nil? || items.empty?
        c = COLORS[concept]; ic = ICONS[concept]
        puts "    #{c}#{ic} #{concept.to_s.gsub("_", " ").capitalize}s (#{items.size})#{R}"
        items.each { |item| puts "      #{c}#{yield(item)}#{R}" }
      end

      def lifecycle_panel(agg)
        return unless agg.respond_to?(:lifecycle) && agg.lifecycle
        lc = agg.lifecycle
        c = COLORS[:lifecycle]; ic = ICONS[:lifecycle]
        puts "    #{c}#{ic} Lifecycle#{R} :#{lc.field} (default: #{lc.default})"
        lc.transitions.each do |cmd_name, t|
          from = t.respond_to?(:from) && t.from ? " from: \"#{t.from}\"" : ""
          target = t.respond_to?(:target) ? t.target : t.to_s
          puts "      #{c}#{cmd_name} => \"#{target}\"#{from}#{R}"
        end
      end

      def behavior_details(agg)
        agg.commands.each do |cmd|
          has_g = !cmd.givens.empty?
          has_m = !cmd.mutations.empty?
          next unless has_g || has_m
          puts "      #{D}#{cmd.name}:#{R}"
          cmd.givens.each do |g|
            puts "        #{COLORS[:given]}#{ICONS[:given]} given: #{g.message}#{R}"
          end
          cmd.mutations.each do |m|
            puts "        #{COLORS[:mutation]}#{ICONS[:mutation]} then_#{m.operation} :#{m.field} #{m.value}#{R}"
          end
        end
      end

      def policies
        return if @domain.policies.empty?
        puts "#{B}Policies#{R}"
        @domain.policies.each do |p|
          c = COLORS[:policy]
          puts "  #{c}#{ICONS[:policy]} #{p.name}: #{p.event_name} → #{p.trigger_command}#{R}"
        end
        puts
      end

      def footer
        puts "#{D}#{"─" * 60}"
        puts "  [1-#{@domain.aggregates.size}] Focus aggregate  [q] Quit  [r] Refresh#{R}"
      end

      def prompt_loop
        loop do
          print "\n#{B}allure>#{R} "
          input = $stdin.gets&.strip
          break if input.nil? || input == "q"
          case input
          when "r" then run
          when /^\d+$/
            i = input.to_i - 1
            if i >= 0 && i < @domain.aggregates.size
              clear; header; aggregate_panel(@domain.aggregates[i], i); puts; footer
            else
              puts "  Out of range (1-#{@domain.aggregates.size})"
            end
          else puts "  Unknown: #{input}"
          end
        end
      end
    end
  end
end
