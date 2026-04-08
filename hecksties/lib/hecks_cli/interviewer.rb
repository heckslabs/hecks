# Hecks::Interviewer
#
# Conversational onboarding that walks a user through defining a domain
# interactively. Asks for domain name, aggregates, attributes, and commands,
# then builds a Domain IR via BluebookBuilder and serializes it as DSL source.
#
# Accepts `ask` and `say` callables for testability (defaults to Thor shell).
#
#   interviewer = Hecks::Interviewer.new(ask: method(:ask), say: method(:say))
#   dsl_source  = interviewer.run
#
module Hecks
  # Hecks::Interviewer
  #
  # Conversational CLI onboarding wizard for defining a new domain interactively.
  #
  class Interviewer
    def initialize(ask:, say:)
      @ask = ask
      @say = say
    end

    def run
      name = ask_domain_name
      aggregates = ask_aggregates
      domain = build_domain(name, aggregates)
      show_summary(domain)
      return nil unless confirm?

      Hecks::DslSerializer.new(domain).serialize
    end

    private

    def ask_domain_name
      loop do
        answer = @ask.call("Domain name:")
        next @say.call("Domain name cannot be blank.", :red) if answer.to_s.strip.empty?
        return Hecks::Utils.sanitize_constant(answer.strip)
      end
    end

    def ask_aggregates
      aggregates = []
      @say.call("")
      @say.call("Now let's define your aggregates (the core entities in your domain).")
      @say.call("Press Enter with a blank name when you're done.")

      loop do
        answer = @ask.call("Aggregate name (blank to finish):")
        break if answer.to_s.strip.empty?

        agg_name = Hecks::Utils.sanitize_constant(answer.strip)
        attrs = ask_attributes(agg_name)
        commands = ask_commands(agg_name)
        aggregates << { name: agg_name, attributes: attrs, commands: commands }
      end

      aggregates
    end

    def ask_attributes(agg_name)
      attrs = []
      @say.call("  Attributes for #{agg_name} (format: name:Type, blank to finish):")

      loop do
        answer = @ask.call("    attribute:")
        break if answer.to_s.strip.empty?

        parts = answer.strip.split(":", 2)
        attr_name = parts[0].strip
        attr_type = resolve_type((parts[1] || "String").strip)
        attrs << { name: attr_name, type: attr_type }
      end

      attrs
    end

    def ask_commands(agg_name)
      commands = []
      @say.call("  Commands for #{agg_name} (blank to finish):")

      loop do
        answer = @ask.call("    command:")
        break if answer.to_s.strip.empty?
        commands << answer.strip
      end

      commands
    end

    def resolve_type(type_str)
      case type_str.downcase
      when "string"   then "String"
      when "integer"  then "Integer"
      when "float"    then "Float"
      when "boolean"  then "Boolean"
      when "date"     then "Date"
      when "datetime" then "DateTime"
      else type_str
      end
    end

    def build_domain(name, aggregates)
      builder = Hecks::DSL::BluebookBuilder.new(name)
      aggregates.each do |agg|
        builder.aggregate(agg[:name]) do
          agg[:attributes].each { |a| attribute a[:name].to_sym, Object.const_get(a[:type]) rescue a[:type] }
          agg[:commands].each do |cmd_name|
            command(cmd_name) do
              agg[:attributes].each { |a| attribute a[:name].to_sym, Object.const_get(a[:type]) rescue a[:type] }
            end
          end
        end
      end
      builder.build
    end

    def show_summary(domain)
      @say.call("")
      @say.call("--- Domain Summary ---", :green)
      @say.call("Domain: #{domain.name}")
      domain.aggregates.each do |agg|
        @say.call("  Aggregate: #{agg.name}")
        agg.attributes.each { |a| @say.call("    - #{a.name}: #{a.type}") }
        agg.commands.each { |c| @say.call("    > #{c.name}") }
      end
      @say.call("---------------------", :green)
    end

    def confirm?
      answer = @ask.call("Write this domain? [Y/n]:")
      !answer.to_s.strip.match?(/\An(o)?\z/i)
    end
  end
end
