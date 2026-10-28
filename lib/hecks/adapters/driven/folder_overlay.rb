module Hecks
  module Adapters
    # The files a copy of a domain keeps for itself, loaded after the domain's own: its overlay,
    # its bluebooks' local worlds, and a named environment's overlay. `Folder` mixes this in.
    module FolderOverlay
      # The overlay one copy of a domain keeps for itself, such as the database its own runs
      # record to. `.gitignore` keeps it out of the repository, so no other copy ever reads it.
      LOCAL_OVERLAY = "local".freeze

      # A bluebook's local files, `<chapter>.local.hecksagon` and `<chapter>.local.world`: where a
      # copy, or a client's working directory, opts a bluebook into persistence, the hecksagon with
      # `persisted_by` and the world with the values. The base names no persistence, so Memory is
      # the default.
      LOCAL_FILES = %w[*.local.hecksagon *.local.world].freeze

      # The name of a file that is local: a `.local.hecksagon` or a `.local.world`.
      LOCAL_FILE_NAME = /\.local\.(hecksagon|world)\z/

      # Loads the copy's own overlay, then its local files (beside the domain, then in the working
      # directory), then an environment's overlay, each `.hecksagon` then `.world`, when present.
      # The environment loads last, so `memory` still wins over a local database.
      #
      # @param directory [String] the directory holding the `environments/` folder
      # @param environment [String, nil] the environment name; nil loads no named overlay
      # @return [void]
      def load_overlay(directory, environment)
        load_each(directory, overlay_files(LOCAL_OVERLAY))
        [directory, Dir.pwd].uniq.each { |where| load_each(where, LOCAL_FILES) }
        load_each(directory, overlay_files(environment)) if environment && environment != LOCAL_OVERLAY
      end

      # The `.hecksagon` and `.world` files of one named overlay, relative to the domain.
      #
      # @param name [String] the overlay's name
      # @return [Array<String>] the two patterns
      def overlay_files(name)
        %w[hecksagon world].map { |kind| File.join("environments", "#{name}.#{kind}") }
      end

      # A local file belongs to the overlay phase, which loads it after the base, so a base glob
      # such as `*.world` does not pick it up first.
      #
      # @param file [String] a file a pattern matched
      # @param pattern [String] the pattern that matched it
      # @return [Boolean] whether the file waits for the overlay phase
      def left_to_overlay?(file, pattern)
        file.match?(LOCAL_FILE_NAME) && !LOCAL_FILES.include?(pattern)
      end
    end
  end
end
