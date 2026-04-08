# Hecks::LoadExtensions
#
# Discovers and loads extensions from all component directories.
# Extensions register themselves in Hecks.extension_registry when required.
# Called by Boot to auto-detect available extensions.
#
#   Hecks::LoadExtensions.require_all    # load everything
#   Hecks::LoadExtensions.require_auto   # load only the default set
#   Hecks::LoadExtensions.require_one(:audit)
#
module Hecks
  # Handles discovery and loading of Hecks extensions across all components.
  # Extensions are Ruby files under +hecks/extensions/+ in any component's
  # +lib/+ directory. They register themselves in +Hecks.extension_registry+
  # when required.
  #
  # Extensions are categorized as either persistence (sqlite, postgres, etc.)
  # or non-persistence (serve, ai, auth, audit, pii). Persistence extensions
  # are loaded explicitly via the +adapter+ keyword in boot/configure.
  # Non-persistence extensions are auto-loaded at boot time.
  module LoadExtensions
    # Extensions loaded automatically at boot (non-persistence).
    AUTO = %i[serve ai auth audit pii validations filesystem_store metrics claude].freeze

    # Loads a single extension by name via the load path.
    # Silently does nothing if the extension cannot be loaded
    # (e.g., missing dependencies).
    #
    # @param name [Symbol, String] the extension name (e.g., +:audit+, +:serve+)
    # @return [void]
    def self.require_one(name)
      require "hecks/extensions/#{name}"
    rescue LoadError
      nil
    end

    # @see require_one
    def self.require_if_available(name)
      require_one(name)
    end

    # Loads all extensions in the AUTO list. Called during +Hecks.boot+ to
    # ensure standard non-persistence extensions are available.
    #
    # @return [void]
    def self.require_auto
      AUTO.each { |name| require_one(name) }
    end

    # Loads every extension found across all component lib/ directories.
    #
    # @return [void]
    def self.require_all
      extension_files.each { |f| require f }
    end

    # Returns the names of all available extensions by scanning all
    # component lib/ directories for extension files.
    #
    # @return [Array<Symbol>] extension names
    def self.available
      extension_files.map { |f| File.basename(f, ".rb").to_sym }.uniq.sort
    end

    # Finds all extensions/*.rb files across all load path entries.
    #
    # @return [Array<String>] absolute paths to extension files
    def self.extension_files
      $LOAD_PATH.flat_map do |dir|
        Dir[File.join(dir, "hecks", "extensions", "*.rb")]
      end.uniq.sort
    end
    private_class_method :extension_files
  end
end
