# = HecksTemplating::NamingHelpers
#
# Mixin that provides naming convention helpers as regular methods.
# Include in any class or module — methods propagate through include
# chains, so mixins-into-mixins work correctly.
#
#   include HecksTemplating::NamingHelpers
#   domain_module_name("Pizzas")     # => "PizzasDomain"
#   domain_aggregate_slug("Pizza")   # => "pizzas"
#   domain_command_method("CreatePizza", "Pizza") # => :create
#
module HecksTemplating
  # HecksTemplating::NamingHelpers
  #
  # Mixin providing naming convention helpers as regular methods for classes and modules that include it.
  #
  module NamingHelpers
    private

    def domain_module_name(name)
      HecksTemplating::Names.domain_module_name(name)
    end

    def domain_gem_name(name)
      HecksTemplating::Names.domain_gem_name(name)
    end

    def domain_constant_name(name)
      HecksTemplating::Names.domain_constant_name(name)
    end

    def domain_snake_name(name)
      HecksTemplating::Names.domain_snake_name(name)
    end

    def domain_aggregate_slug(name)
      HecksTemplating::Names.domain_aggregate_slug(name)
    end

    def domain_slug(name)
      HecksTemplating::Names.domain_slug(name)
    end

    def domain_command_name(verb, aggregate_name)
      HecksTemplating::Names.domain_command_name(verb, aggregate_name)
    end

    def domain_referenced_name(foreign_key)
      HecksTemplating::Names.domain_referenced_name(foreign_key)
    end

    def domain_command_method(cmd_name, agg_name)
      HecksTemplating::Names.domain_command_method(cmd_name, agg_name)
    end

    def domain_route_path(domain_name, aggregate_name)
      HecksTemplating::Names.domain_route_path(domain_name, aggregate_name)
    end

    def domain_output_dir(domain_name)
      HecksTemplating::Names.domain_output_dir(domain_name)
    end
  end
end
