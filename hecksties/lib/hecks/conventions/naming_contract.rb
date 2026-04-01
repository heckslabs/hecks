# = Hecks::Conventions::Names
#
# Single source of truth for all naming conventions in Hecks.
# Include in any class/module for bare method calls:
#
#   include Hecks::Conventions::Names
#   domain_module_name("Pizzas")     # => "PizzasDomain"
#   domain_aggregate_slug("Pizza")   # => "pizzas"
#   domain_command_method("CreatePizza", "Pizza") # => :create
#
module Hecks::Conventions

    module Names
      module_function

      # "Pizzas" → "PizzasDomain"
      def domain_module_name(name)
        Hecks::Utils.sanitize_constant(name) + "Domain"
      end

      # "Pizzas" → "pizzas_domain"
      def domain_gem_name(name)
        Hecks::Utils.underscore(Hecks::Utils.sanitize_constant(name)) + "_domain"
      end

      # "pizza order" → "PizzaOrder"
      def domain_constant_name(name)
        Hecks::Utils.sanitize_constant(name)
      end

      # "GovernancePolicy" → "governance_policy"
      def domain_snake_name(name)
        Hecks::Utils.underscore(name)
      end

      # "Pizza" → "pizzas"
      def domain_aggregate_slug(name)
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

      # ("Blog", "Post") → "/blog/posts"
      def domain_route_path(domain_name, aggregate_name)
        "/#{domain_slug(domain_name)}/#{domain_aggregate_slug(aggregate_name)}"
      end

      # "Pizzas" → "pizzas_domain"
      def domain_output_dir(domain_name)
        Hecks::Utils.underscore(Hecks::Utils.sanitize_constant(domain_name)) + "_domain"
      end
    end
end
