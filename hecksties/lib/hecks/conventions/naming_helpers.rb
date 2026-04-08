# = Hecks::Conventions::NamingHelpers
#
# Mixin that provides naming convention helpers as regular methods.
# Include in any class or module — methods propagate through include
# chains, so mixins-into-mixins work correctly.
#
#   include Hecks::Conventions::NamingHelpers
#   bluebook_module_name("Pizzas")     # => "PizzasDomain"
#   bluebook_aggregate_slug("Pizza")   # => "pizzas"
#   domain_command_method("CreatePizza", "Pizza") # => :create
#
module Hecks::Conventions
  # Hecks::Conventions::NamingHelpers
  #
  # Mixin delegating all naming convention methods to Hecks::Conventions::Names for include chains.
  #
  module NamingHelpers
    private

    def bluebook_module_name(name)
      Hecks::Conventions::Names.bluebook_module_name(name)
    end

    def bluebook_gem_name(name)
      Hecks::Conventions::Names.bluebook_gem_name(name)
    end

    def bluebook_constant_name(name)
      Hecks::Conventions::Names.bluebook_constant_name(name)
    end

    def bluebook_snake_name(name)
      Hecks::Conventions::Names.bluebook_snake_name(name)
    end

    def bluebook_aggregate_slug(name)
      Hecks::Conventions::Names.bluebook_aggregate_slug(name)
    end

    def domain_slug(name)
      Hecks::Conventions::Names.domain_slug(name)
    end

    def domain_command_name(verb, aggregate_name)
      Hecks::Conventions::Names.domain_command_name(verb, aggregate_name)
    end

    def domain_referenced_name(foreign_key)
      Hecks::Conventions::Names.domain_referenced_name(foreign_key)
    end

    def domain_command_method(cmd_name, agg_name)
      Hecks::Conventions::Names.domain_command_method(cmd_name, agg_name)
    end

    def bluebook_command_fqn(domain_mod_name, agg_name, cmd_name)
      Hecks::Conventions::Names.bluebook_command_fqn(domain_mod_name, agg_name, cmd_name)
    end

    def bluebook_event_fqn(domain_mod_name, agg_name, event_name)
      Hecks::Conventions::Names.bluebook_event_fqn(domain_mod_name, agg_name, event_name)
    end

    def bluebook_policy_fqn(domain_mod_name, agg_name, policy_name)
      Hecks::Conventions::Names.bluebook_policy_fqn(domain_mod_name, agg_name, policy_name)
    end

    def actor_roles_for(domain, domain_mod)
      Hecks::Conventions::Names.actor_roles_for(domain, domain_mod)
    end

    def aggregate_module_from_command(command_class_name)
      Hecks::Conventions::Names.aggregate_module_from_command(command_class_name)
    end

    def resolve_command_const(mod, agg_name, cmd_name)
      Hecks::Conventions::Names.resolve_command_const(mod, agg_name, cmd_name)
    end

    def domain_route_path(domain_name, aggregate_name)
      Hecks::Conventions::Names.domain_route_path(domain_name, aggregate_name)
    end

    def bluebook_output_dir(domain_name)
      Hecks::Conventions::Names.bluebook_output_dir(domain_name)
    end
  end
end
