require "rails/railtie"
require_relative "booting"
require_relative "model"
require_relative "routes"
require_relative "form_helper"

module Hecks
  module Rails
    # Plugs the adapter into a Rails app: boots the app's `bluebook/` once its initializers have
    # run, teaches the router `hecks_routes`, gives views `bluebook_form_for`, and answers a record
    # `Model.find` cannot find with a 404.
    #
    # `config.hecks.bluebook` names the domain directory (the app's `bluebook/` by default) and
    # `config.hecks.environment` the `environments/<name>` overlay (`Rails.env` by default).
    class Railtie < ::Rails::Railtie
      config.hecks = ActiveSupport::OrderedOptions.new
      config.action_dispatch.rescue_responses["Hecks::Rails::RecordNotFound"] = :not_found

      initializer "hecks.boot", after: :load_config_initializers do |app|
        settings = app.config.hecks
        Hecks::Rails.boot!((settings.bluebook || app.root.join("bluebook")).to_s,
                           environment: (settings.environment || ::Rails.env).to_s)
      end

      initializer "hecks.routes" do
        ActiveSupport.on_load(:action_controller) { ActionDispatch::Routing::Mapper.include(Hecks::Rails::Routes) }
      end

      initializer "hecks.form_helper" do
        ActiveSupport.on_load(:action_view) { include Hecks::Rails::FormHelper }
      end
    end
  end
end
