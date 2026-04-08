# Hecks::Generators::ExampleAppWriter
#
# Generates a runnable app.rb from domain IR. Infers event
# subscriptions, collection proxy demos, repository methods,
# query usage, and value object instantiation from the IR
# metadata. Used by ExampleGenerator.
#
#   writer = ExampleAppWriter.new(domain, aggregates)
#   writer.generate  # => "#!/usr/bin/env ruby\n..."
#
module Hecks
  module Generators
    class ExampleAppWriter
      include Hecks::NamingHelpers

      def initialize(domain, aggregates, name: nil)
        @domain = domain
        @aggregates = aggregates
        @name = name || domain.name
      end

      def generate
        lines = []
        lines << header
        lines << boot_section
        lines << event_subscriptions
        lines << run_commands_section
        lines << collection_proxy_section
        lines << repository_section
        lines << queries_section
        lines << value_objects_section
        lines << event_history_section
        lines.compact.join("\n")
      end

      private

      # --- naming ---

      def aggregate_var(agg)
        bluebook_snake_name(agg.name)
      end

      def command_method(agg, cmd)
        domain_command_method(cmd.name, agg.name)
      end

      def query_method(query)
        bluebook_snake_name(query.name)
      end

      def value_object_constant(agg, vo)
        "#{bluebook_module_name(@name)}::#{agg.name}::#{vo.name}"
      end

      def display_attr(obj)
        attr = obj.attributes.find { |a| a.type.to_s == "String" && !a.list? }
        attr ? attr.name : :id
      end

      def display_pair(agg)
        agg.attributes.select { |a| a.type.to_s == "String" && !a.list? }.first(2)
      end

      # --- sections ---

      def header
        <<~RUBY
          #!/usr/bin/env ruby
          #
          # #{@name} domain — generated from #{@name}Bluebook
          #
          # Run:  ruby -Ilib #{File.join("examples", bluebook_snake_name(@name), "#{bluebook_snake_name(@name)}.rb")}
          #
        RUBY
      end

      def boot_section
        <<~RUBY
          require "hecks"

          app = Hecks.boot(__dir__)
        RUBY
      end

      def event_subscriptions
        lines = ["\n# Subscribe to events"]
        @aggregates.flat_map(&:commands).each do |cmd|
          event = cmd.inferred_event_name
          sample = user_attrs(cmd).first
          body = sample ? "  puts \"  [event] #{event}: \#{event.#{sample.name}}\"" :
                          "  puts \"  [event] #{event}\""
          lines.push("app.on(#{event.inspect}) do |event|", body, "end", "")
        end
        lines.join("\n")
      end

      def run_commands_section
        lines = ["puts \"\\n--- Running commands ---\""]
        @aggregates.each do |agg|
          creates, updates = agg.commands.partition { |c| create_command?(agg, c) }
          var = aggregate_var(agg)

          lines << "\nputs \"\\nCreating #{var}s...\""
          creates.each_with_index do |cmd, i|
            label = i > 0 ? "#{var}#{i + 1}" : var
            args = user_attrs(cmd).map { |a| "#{a.name}: #{example_value(a, i)}" }.join(", ")
            lines << "#{label} = #{agg.name}.#{command_method(agg, cmd)}(#{args})"
          end

          updates.each do |cmd|
            args = build_update_args(agg, cmd)
            lines << "\nputs \"\\n#{cmd.description || cmd.name}...\""
            lines << "#{agg.name}.#{command_method(agg, cmd)}(#{args})"
          end
        end
        lines.join("\n")
      end

      def collection_proxy_section
        proxies = @aggregates.select { |a| list_attrs(a).any? }
        return nil if proxies.empty?

        lines = ["\nputs \"\\n--- Collection proxies ---\""]
        proxies.each do |agg|
          var = aggregate_var(agg)
          list_attrs(agg).each do |attr|
            vo = agg.value_objects.find { |v| v.name == attr.type.to_s }
            next unless vo
            2.times do |i|
              args = vo.attributes.map { |a| "#{a.name}: #{example_value(a, i)}" }.join(", ")
              lines << "#{var}.#{attr.name}.create(#{args})"
            end
            lines << "puts \"#{agg.name} #{attr.name}: \#{#{var}.#{attr.name}.count}\""
            lines << "#{var}.#{attr.name}.each do |item|"
            display = vo.attributes.map { |a| a.type.to_s == "String" ? "\#{item.#{a.name}}" : "x\#{item.#{a.name}}" }
            lines << "  puts \"  - #{display.join(" ")}\""
            lines << "end"
          end
        end
        lines.join("\n")
      end

      def repository_section
        agg = @aggregates.first
        return nil unless agg
        var = aggregate_var(agg)
        lines = ["\nputs \"\\n--- Repository methods ---\""]
        lines << "puts \"Total #{var}s: \#{#{agg.name}.count}\""
        lines << "found = #{agg.name}.find(#{var}.id)"
        lines << "puts \"Found: \#{found.#{display_attr(agg)}}\""
        lines << ""
        lines << "#{agg.name}.all.each do |item|"
        pair = display_pair(agg)
        if pair.size >= 2
          lines << "  puts \"  \#{item.#{pair[0].name}}: \#{item.#{pair[1].name}}\""
        else
          lines << "  puts \"  \#{item.#{display_attr(agg)}}\""
        end
        lines << "end"
        lines.join("\n")
      end

      def queries_section
        queries = @aggregates.flat_map { |a| a.queries.map { |q| [a, q] } }
        return nil if queries.empty?

        lines = ["\nputs \"\\n--- Query objects ---\""]
        queries.each do |agg, query|
          args = query_args(agg, query)
          lines << "results = #{agg.name}.#{query_method(query)}#{args}"
          lines << "puts \"#{query.name}: \#{results.map(&:#{display_attr(agg)}).join(\", \")}\""
        end
        lines.join("\n")
      end

      def query_args(agg, query)
        params = query.block&.parameters || []
        return "" if params.empty?
        sample = "\"#{string_samples(display_attr(agg).to_s).first}\""
        "(#{params.map { sample }.join(", ")})"
      end

      def value_objects_section
        vos = @aggregates.flat_map { |agg| agg.value_objects.map { |vo| [agg, vo] } }
        return nil if vos.empty?
        agg, vo = vos.first
        args = vo.attributes.map { |a| "#{a.name}: #{example_value(a, 0)}" }.join(", ")
        ["\n# Value objects are immutable",
         "item = #{value_object_constant(agg, vo)}.new(#{args})",
         "puts \"\\n#{vo.name}: \#{item.#{display_attr(vo)}} (frozen: \#{item.frozen?})\""].join("\n")
      end

      def event_history_section
        "\nputs \"\\n--- Event history ---\"\n" \
        "app.events.each_with_index do |event, i|\n" \
        "  name = event.class.name.split(\"::\").last\n" \
        "  puts \"\#{i + 1}. \#{name} at \#{event.occurred_at}\"\n" \
        "end\n"
      end

      # --- helpers ---

      def create_command?(agg, cmd) = cmd.references.none? { |r| r.type.to_s == agg.name }
      def user_attrs(cmd) = cmd.attributes.reject { |a| a.name.to_s == "aggregate_id" }
      def list_attrs(agg) = agg.attributes.select(&:list?)

      def build_update_args(agg, cmd)
        var = aggregate_var(agg)
        parts = cmd.references.map { |ref|
          ref_var = ref.type.to_s == agg.name ? var : aggregate_var(ref)
          "#{ref.name}: #{ref_var}.id"
        }
        user_attrs(cmd).each { |a| parts << "#{a.name}: #{example_value(a, 0)}" }
        parts.join(", ")
      end

      def example_value(attr, index = 0)
        case attr.type.to_s
        when "String"
          samples = string_samples(attr.name.to_s)
          "\"#{samples[index % samples.size]}\""
        when "Integer" then (index + 1).to_s
        when "Float" then "#{12.0 + index * 3}"
        else "\"example\""
        end
      end

      def string_samples(field)
        case field
        when /name/i         then %w[Margherita Pepperoni]
        when /description/i  then ["Classic", "Spicy"]
        when /customer/i     then %w[Alice Bob]
        when /status/i       then %w[pending active]
        else                      %w[example sample]
        end
      end
    end
  end
end
