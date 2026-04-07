# __DOMAIN_MODULE__::Middleware::Auth
#
# Port-based authorization middleware. Checks the current role against
# the PORTS table before every command dispatch. Raises GateAccessDenied
# if the role doesn't include the command action. Based on hecks_auth.
#
#   __DOMAIN_MODULE__.current_role = "customer"
#   Pizza.create_pizza(name: "Nope")  # => GateAccessDenied
#

module __DOMAIN_MODULE__
  module Middleware
    module Auth
      def self.call(command, next_handler)
        parts = command.class.name.split("::")
        agg_name = parts[-3]
        cmd_name = parts[-1]
        action = cmd_name.gsub(/([A-Z])/) { "_" + $1.downcase }.sub(/^_/, "")

        unless __DOMAIN_MODULE__.role_allows?(agg_name, action)
          raise __DOMAIN_MODULE__::GateAccessDenied,
            "Role '#{__DOMAIN_MODULE__.current_role}' cannot #{action} on #{agg_name}"
        end

        next_handler.call
      end
    end
  end
end
