# Loader — the folder convention.
#
# A domain is a directory containing a `bluebook/` folder, and that folder holds
# every declaration for the domain:
#
#   examples/pizzas/
#     bluebook/
#       persistence.family     — the how-verb vocabulary
#       sqlite.adapter         — the inverted arrow
#       pizzas.bluebook        — the domain
#       pizzas.hecksagon       — the wiring
#       pizzas.world           — the per-deployment values
#     data/                    — whatever the adapters write
#
# Load order is not alphabetical, it is DEPENDENCY order: families and adapters
# first (so binds can type-check), then the domain, then the wiring, then the
# values.
#
#   Loader.boot("examples/pizzas")  # => Dispatcher
module Hecksagain
  module Runtime
    class Loader
      LOAD_ORDER = %w[*.family *.adapter *.bluebook *.hecksagon *.world].freeze

      def self.boot(path)
        directory = bluebook_directory(path)
        registry  = Registry.new(root: File.dirname(directory))

        Hecksagain.with_registry(registry) do
          LOAD_ORDER.each do |pattern|
            Dir[File.join(directory, pattern)].sort.each { |file| Kernel.load(file) }
          end
        end

        registry.verify!
        Dispatcher.new(registry)
      end

      # Accepts either the domain directory or its bluebook/ folder directly.
      def self.bluebook_directory(path)
        expanded = File.expand_path(path)
        nested   = File.join(expanded, "bluebook")

        return nested   if File.directory?(nested)
        return expanded if File.directory?(expanded)

        raise Errno::ENOENT, "no such domain directory: #{path}"
      end
    end
  end
end
