require "yaml"

module Hecks
  module Rails
    # Boots the app's domain before routes are drawn, from the `bluebook/` directory at the app's
    # root, and defines a model for each aggregate the app has not written one for. An optional
    # `bluebook.yml` beside it sets `environment:`.
    class Railtie < ::Rails::Railtie
      initializer "hecks.boot", before: :setup_main_autoloader do |app|
        directory = app.root.join("bluebook")
        if directory.directory?
          Booted.boot(directory.to_s, environment: Railtie.environment(app.root))
          Skins.discard_facades!
        end
      end

      config.to_prepare { Skins.generate! if Booted.booted? }

      initializer "hecks.controllers" do
        ActiveSupport.on_load(:action_controller) { extend Controller::Inheritance }
      end

      # The gem's pages sit behind the app's own views, so a view file the app writes wins.
      initializer "hecks.views" do
        views = File.expand_path("../../../app/views", __dir__)
        ActiveSupport.on_load(:action_controller) { append_view_path(views) }
      end

      # @param root [Pathname] the app's root
      # @return [String, nil] the `environment:` named in `bluebook.yml`, if the file exists
      def self.environment(root)
        file = root.join("bluebook.yml")
        file.file? ? YAML.safe_load_file(file.to_s).to_h["environment"] : nil
      end
    end
  end
end
