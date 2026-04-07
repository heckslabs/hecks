module Hecks
  module Generators
    module Infrastructure
      class DomainGemGenerator < Hecks::Generator
        # Hecks::Generators::Infrastructure::DomainGemGenerator::LlmsTxtWriter
        #
        # Mixin that generates an llms.txt file for domain gems produced by
        # DomainGemGenerator. The llms.txt provides AI assistants with structured
        # context about the domain: aggregates, attributes, commands, queries,
        # validation rules, invariants, policy chains, and usage examples.
        #
        #   # Mixed into DomainGemGenerator:
        #   generate_llms_txt(root, gem_name, mod)
        #
        module LlmsTxtWriter
          include HecksTemplating::NamingHelpers
          private

          # Writes an llms.txt file into the generated gem root directory.
          #
          # @param root [String] absolute path to the gem root directory
          # @param gem_name [String] snake_case gem name (e.g. "pizzas_domain")
          # @param mod [String] PascalCase domain module name (e.g. "PizzasDomain")
          # @return [void]
          def generate_llms_txt(root, gem_name, mod)
            lines = []
            lines << "# llms.txt"
            lines << ""
            lines << "## Domain: #{@domain.name}"
            lines << ""

            @domain.aggregates.each do |agg|
              lines.concat(llms_aggregate_section(agg, gem_name, mod))
            end

            lines.concat(llms_validations_section)
            lines.concat(llms_invariants_section)
            lines.concat(llms_policies_section)
            lines.concat(llms_usage_section(gem_name, mod))

            write_file(root, "llms.txt", lines.join("\n"))
          end

          # Build the aggregate section for llms.txt.
          #
          # @param agg [Hecks::DomainModel::Structure::Aggregate]
          # @param gem_name [String]
          # @param mod [String]
          # @return [Array<String>]
          def llms_aggregate_section(agg, gem_name, mod)
            lines = []
            lines << "### Aggregate: #{agg.name}"
            lines << ""

            unless agg.attributes.empty?
              lines << "**Attributes:**"
              agg.attributes.each do |attr|
                lines << "- `#{attr.name}`: #{Hecks::Utils.type_label(attr)}"
              end
              lines << ""
            end

            unless agg.commands.empty?
              lines << "**Commands:**"
              agg.commands.each_with_index do |cmd, i|
                event = agg.events[i]
                params = cmd.attributes.map { |a| "#{a.name}: #{Hecks::Utils.type_label(a)}" }.join(", ")
                event_note = event ? " -> #{event.name}" : ""
                lines << "- `#{cmd.name}(#{params})`#{event_note}"
              end
              lines << ""
            end

            unless agg.queries.empty?
              lines << "**Queries:**"
              agg.queries.each { |q| lines << "- #{q.name}" }
              lines << ""
            end

            unless agg.specifications.empty?
              lines << "**Specifications:**"
              agg.specifications.each { |s| lines << "- #{s.name}" }
              lines << ""
            end

            lines
          end

          # Build a combined validation rules section.
          #
          # @return [Array<String>]
          def llms_validations_section
            all_validations = @domain.aggregates.flat_map do |agg|
              agg.validations.map { |v| [agg.name, v] }
            end
            return [] if all_validations.empty?

            lines = ["### Validation Rules", ""]
            all_validations.each do |agg_name, v|
              rules = []
              rules << "required" if v.rules[:presence]
              rules << "type: #{v.rules[:type]}" if v.rules[:type]
              rules << "unique" if v.rules[:uniqueness]
              v.rules.each do |rule, value|
                next if %i[presence type uniqueness].include?(rule)
                rules << "#{rule}: #{value}"
              end
              lines << "- #{agg_name}##{v.field}: #{rules.join(', ')}"
            end
            lines << ""
            lines
          end

          # Build a combined invariants section.
          #
          # @return [Array<String>]
          def llms_invariants_section
            all_invariants = @domain.aggregates.flat_map do |agg|
              agg.invariants.map { |inv| [agg.name, inv] }
            end
            return [] if all_invariants.empty?

            lines = ["### Invariants", ""]
            all_invariants.each do |agg_name, inv|
              lines << "- #{agg_name}: #{inv.message}"
            end
            lines << ""
            lines
          end

          # Build a combined policies section with reactive flow chains.
          #
          # @return [Array<String>]
          def llms_policies_section
            all_policies = @domain.policies.map { |p| [nil, p] }
            @domain.aggregates.each do |agg|
              agg.policies.each { |p| all_policies << [agg.name, p] }
            end
            return [] if all_policies.empty?

            lines = ["### Policy Chains", ""]
            all_policies.each do |agg_name, pol|
              scope = agg_name ? "#{agg_name}: " : "Domain: "
              if pol.reactive?
                async_note = pol.async ? " [async]" : ""
                lines << "- #{scope}#{pol.event_name} -> #{pol.name} -> #{pol.trigger_command}#{async_note}"
              else
                lines << "- #{scope}#{pol.name} (guard)"
              end
            end
            lines << ""
            lines
          end

          # Build the usage examples section.
          #
          # @param gem_name [String]
          # @param mod [String]
          # @return [Array<String>]
          def llms_usage_section(gem_name, mod)
            lines = ["## Usage Examples", "", "```ruby", "require \"#{gem_name}\"", ""]
            lines << "app = Hecks.boot(__dir__)"
            lines << ""

            first_agg = @domain.aggregates.first
            if first_agg && !first_agg.commands.empty?
              cmd = first_agg.commands.first
              snake = domain_snake_name(domain_constant_name(first_agg.name))
              params = cmd.attributes.map { |a| "#{a.name}: ..." }.join(", ")
              lines << "# Run a command"
              lines << "app.#{snake}.#{domain_snake_name(cmd.name)}(#{params})"
              lines << ""
            end

            if first_agg
              snake = domain_snake_name(domain_constant_name(first_agg.name))
              lines << "# Query the repository"
              lines << "app.#{snake}[1]  # find by id"
              lines << ""
            end

            lines << "```"
            lines << ""
            lines
          end
        end
      end
    end
  end
end
