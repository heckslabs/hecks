# Hecks::AI::IDE::WorkshopSession
#
# Wraps a Workshop WebRunner for IDE integration. Loads a domain from
# a Bluebook path, evaluates safe commands, and returns state for
# autocomplete and the domain tree panel.
#
#   session = WorkshopSession.new("/path/to/PizzasBluebook")
#   session.execute("Pizza")       # => { output: "...", error: nil }
#   session.execute("Pizza.attr :name, String")
#   session.completions            # => ["Pizza", "Order", "attr", ...]
#
module Hecks
  module AI
    module IDE
      class WorkshopSession
        attr_reader :domain_name

        def initialize(bluebook_path, project_dir:)
          full = File.expand_path(bluebook_path, project_dir)
          @runner = Hecks::Workshop::WorkshopRunner.new(name: nil)
          ws = load_bluebook(full)
          @runner.instance_variable_set(:@workshop, ws)
          @parser = Hecks::Workshop::WebRunner::CommandParser.new(@runner)
          @domain_name = ws.name
        end

        def execute(input)
          @parser.execute(input)
        end

        def state
          ws = workshop
          aggs = ws.aggregate_builders.map do |name, builder|
            ir = builder.build
            {
              name: name,
              attributes: ir.attributes.map { |a| { name: a.name.to_s, type: a.type.to_s } },
              commands: ir.commands.map(&:name),
              queries: ir.queries.map(&:name)
            }
          end
          { domain: ws.name, mode: ws.play? ? "play" : "sketch", aggregates: aggs }
        end

        def completions
          ws = workshop
          names = ws.aggregate_builders.keys
          commands = %w[validate describe play! build help remove inspect visualize]
          methods = %w[attr command query value_object entity reference_to
                       validation invariant lifecycle specification]
          names + commands + methods
        end

        def diagram
          ws = workshop
          aggs = ws.aggregate_builders.map do |name, builder|
            ir = builder.build
            refs = ir.references.map { |r| { name: r.name.to_s, target: r.type.to_s } }
            vos = ir.value_objects.map(&:name)
            { name: name, attrs: ir.attributes.size, cmds: ir.commands.size,
              refs: refs, value_objects: vos }
          end
          build_mermaid(aggs)
        end

        private

        def build_mermaid(aggs)
          lines = ["classDiagram"]
          names = aggs.map { |a| a[:name] }
          aggs.each do |a|
            lines << "  class #{a[:name]} { #{a[:attrs]} attrs · #{a[:cmds]} cmds }"
            a[:refs].each do |r|
              lines << "  #{a[:name]} --> #{r[:target]} : #{r[:name]}" if names.include?(r[:target])
            end
            a[:value_objects].each do |vo|
              lines << "  #{a[:name]} *-- #{vo}"
            end
          end
          lines.join("\n")
        end

        private

        def workshop
          @runner.instance_variable_get(:@workshop)
        end

        def load_bluebook(path)
          Kernel.load(path)
          domain = Hecks.last_domain
          ws = Hecks::Workshop.new(domain.name)
          domain.aggregates.each do |agg|
            ws.aggregate_builders[agg.name] =
              Hecks::DSL::AggregateRebuilder.from_aggregate(agg)
          end
          ws
        end
      end
    end
  end
end
