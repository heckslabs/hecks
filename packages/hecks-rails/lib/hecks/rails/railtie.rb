require "yaml"

module Hecks
  module Rails
    # Boots the app's domain before routes are drawn, from the `bluebook/` directory at the app's
    # root. An optional `bluebook.yml` beside it sets `environment:`.
    class Railtie < ::Rails::Railtie
      initializer "hecks.boot", before: :set_routes_reloader_hook do |app|
        directory = app.root.join("bluebook")
        Booted.boot(directory.to_s, environment: Railtie.environment(app.root)) if directory.directory?
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
