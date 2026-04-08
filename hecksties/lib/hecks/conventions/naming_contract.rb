# = Hecks::Conventions::Names
#
# Single source of truth for all naming conventions in Hecks.
# Include in any class/module for bare method calls:
#
#   include Hecks::Conventions::Names
#   bluebook_module_name("Pizzas")     # => "PizzasDomain"
#   bluebook_aggregate_slug("Pizza")   # => "pizzas"
#   domain_command_method("CreatePizza", "Pizza") # => :create
#
module Hecks::Conventions

  # Hecks::Conventions::Names
  #
  # Single source of truth for all naming conventions: module names, slugs, FQNs, and route paths.
  #
    module Names
      module_function

      # "Pizzas" → "PizzasDomain"
      def bluebook_module_name(name)
        Hecks::Utils.sanitize_constant(name) + "Bluebook"
      end

      # "Pizzas" → "pizzas_domain"
      def bluebook_gem_name(name)
        Hecks::Utils.underscore(Hecks::Utils.sanitize_constant(name)) + "_bluebook"
      end

      # "pizza order" → "PizzaOrder"
      def bluebook_constant_name(name)
        Hecks::Utils.sanitize_constant(name)
      end

      # "GovernancePolicy" → "governance_policy"
      def bluebook_snake_name(name)
        Hecks::Utils.underscore(name)
      end

      # "Pizza" → "pizzas"
      def bluebook_aggregate_slug(name)
        s = Hecks::Utils.underscore(Hecks::Utils.sanitize_constant(name))
        s.end_with?("s") ? s : s + "s"
      end

      # "Blog" → "blog"
      def domain_slug(name)
        Hecks::Utils.underscore(name)
      end

      # ("create", "Pizza") → "CreatePizza"
      def domain_command_name(verb, aggregate_name)
        parts = verb.to_s.split("_")
        if parts.size == 1
          parts.first.capitalize + Hecks::Utils.sanitize_constant(aggregate_name)
        else
          parts.map(&:capitalize).join
        end
      end

      # "post" → "post"
      def domain_referenced_name(foreign_key)
        foreign_key.to_s.sub(/_id$/, "")
      end

      # "CreatePizza" on "Pizza" → :create
      def domain_command_method(cmd_name, agg_name)
        Hecks::Conventions::CommandContract.method_name(cmd_name, agg_name)
      end

      # ("PizzasDomain", "Pizza", "CreatePizza") → "PizzasDomain::Pizza::Commands::CreatePizza"
      def bluebook_command_fqn(domain_mod_name, agg_name, cmd_name)
        "#{domain_mod_name}::#{agg_name}::Commands::#{cmd_name}"
      end

      # ("PizzasDomain", "Pizza", "CreatedPizza") → "PizzasDomain::Pizza::Events::CreatedPizza"
      def bluebook_event_fqn(domain_mod_name, agg_name, event_name)
        "#{domain_mod_name}::#{agg_name}::Events::#{event_name}"
      end

      # ("PizzasDomain", "Pizza", "CanCreate") → "PizzasDomain::Pizza::Policies::CanCreate"
      def bluebook_policy_fqn(domain_mod_name, agg_name, policy_name)
        "#{domain_mod_name}::#{agg_name}::Policies::#{policy_name}"
      end

      # Builds { fqn_string => [role_names] } for all commands with actor declarations.
      #
      #   Names.actor_roles_for(domain, domain_mod)
      #   # => { "CatsDomain::Cat::Commands::Adopt" => ["Admin", "Vet"] }
      def actor_roles_for(domain, domain_mod)
        map = {}
        domain.aggregates.each do |agg|
          agg.commands.each do |cmd|
            next if cmd.actors.empty?
            map[bluebook_command_fqn(domain_mod.name, agg.name, cmd.name)] = cmd.actors.map(&:name)
          end
        end
        map
      end

      # "PizzasDomain::Pizza::Commands::CreatePizza" → "PizzasDomain::Pizza"
      # Extracts the aggregate module path from a fully-qualified command class name.
      def aggregate_module_from_command(command_class_name)
        command_class_name.split("::")[0..-3].join("::")
      end

      # Resolves the command class constant from a domain module.
      #
      #   Names.resolve_command_const(PizzasDomain, "Pizza", "CreatePizza")
      #   # => PizzasDomain::Pizza::Commands::CreatePizza
      def resolve_command_const(mod, agg_name, cmd_name)
        mod.const_get("#{agg_name}::Commands::#{cmd_name}")
      end

      # ("Blog", "Post") → "/blog/posts"
      def domain_route_path(domain_name, aggregate_name)
        "/#{domain_slug(domain_name)}/#{bluebook_aggregate_slug(aggregate_name)}"
      end

      # "Pizzas" → "pizzas_domain"
      def bluebook_output_dir(domain_name)
        Hecks::Utils.underscore(Hecks::Utils.sanitize_constant(domain_name)) + "_bluebook"
      end
    end
end
