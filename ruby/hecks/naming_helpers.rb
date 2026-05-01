# = HecksTemplating::NamingHelpers
#
# Mixin that provides naming convention helpers as regular methods.
# Include in any class or module — methods propagate through include
# chains, so mixins-into-mixins work correctly.
#
#   include HecksTemplating::NamingHelpers
#   bluebook_module_name("Pizzas")     # => "PizzasDomain"
#   bluebook_aggregate_slug("Pizza")   # => "pizzas"
#   domain_command_method("CreatePizza", "Pizza") # => :create
#
module HecksTemplating
  # HecksTemplating::NamingHelpers
  #
  # Mixin providing naming convention helpers as regular methods for classes and modules that include it.
  #
  module NamingHelpers
    private

    def bluebook_module_name(name)
      HecksTemplating::Names.bluebook_module_name(name)
    end

    def bluebook_gem_name(name)
      HecksTemplating::Names.bluebook_gem_name(name)
    end

    def bluebook_constant_name(name)
      HecksTemplating::Names.bluebook_constant_name(name)
    end

    def bluebook_snake_name(name)
      HecksTemplating::Names.bluebook_snake_name(name)
    end

    def bluebook_aggregate_slug(name)
      HecksTemplating::Names.bluebook_aggregate_slug(name)
    end

    def bluebook_slug(name)
      HecksTemplating::Names.domain_slug(name)
    end

    def bluebook_command_name(verb, aggregate_name)
      HecksTemplating::Names.bluebook_command_name(verb, aggregate_name)
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

    def bluebook_output_dir(domain_name)
      HecksTemplating::Names.bluebook_output_dir(domain_name)
    end
  end
end
