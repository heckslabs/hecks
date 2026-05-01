# Hecks::Compiler::SourceCollector
#
# Collects all Hecks framework source files in load order by
# introspecting $LOADED_FEATURES after requiring "hecks". Returns
# the exact order Ruby resolved dependencies.
#
#   files = Hecks::Compiler::SourceCollector.collect(lib_root: "lib")
#   files.each { |path| puts path }
#
module Hecks
  module Compiler
    module SourceCollector
      # Returns an ordered list of absolute paths for all Hecks source
      # files currently loaded under lib_root. Triggers a full domain
      # boot to capture lazily-loaded runtime files.
      #
      # @param lib_root [String] absolute path to the lib/ directory
      # @return [Array<String>] file paths in load order
      def self.collect(lib_root:)
        lib_root = File.expand_path(lib_root)
        trigger_lazy_loads(lib_root)
        $LOADED_FEATURES.select { |f|
          f.end_with?(".rb") && f.start_with?(lib_root)
        }
      end

      # Boots a minimal domain to force all lazy require_relative
      # calls in the runtime to execute, capturing them in
      # $LOADED_FEATURES.
      def self.trigger_lazy_loads(lib_root)
        return if @lazy_triggered
        @lazy_triggered = true
        pizzas = File.join(lib_root, "..", "examples", "pizzas")
        Hecks.boot(pizzas) if File.directory?(pizzas)
      rescue => e
        # Non-fatal: we'll still bundle what we have
        warn "[v0] Warning: lazy load trigger failed: #{e.message}"
      end

      # Returns the lib/ directory by walking up from this file.
      def self.default_lib_root
        File.expand_path("../..", __dir__)
      end
    end
  end
end
