require "hecks"
require "hecks/forms"
require "active_model"
require "action_controller"
require_relative "rails/actor"
require_relative "rails/booted"
require_relative "rails/command_routes"
require_relative "rails/available_commands"
require_relative "rails/arguments"
require_relative "rails/validating"
require_relative "rails/references"
require_relative "rails/model"
require_relative "rails/skins"
require_relative "rails/routes"
require_relative "rails/app"
require_relative "rails/pages"
require_relative "rails/rendering"
require_relative "rails/actors_controller"
require_relative "rails/controller"
require_relative "rails/form_helper"
require_relative "rails/railtie" if defined?(Rails::Railtie)

module Hecks
  # A Rails app as a driving adapter over a booted Hecks domain.
  #
  # Rails authenticates, routes and renders; the domain decides. A model here holds no
  # validations, callbacks or associations, because every rule is declared in the bluebook and a
  # second author for a rule is the divergence this layer exists to avoid.
  #
  # Nothing here names the runtime's classes: a refusal is `Hecks::Refused`, a caller is bound
  # through `Hecks.as_caller`, and a booted domain is reached through `Hecks::Rails::Booted`.
  module Rails
    extend Actor
  end
end
