# Loader — the folder convention.
#
# A domain is a directory containing a `bluebook/` folder, and that folder holds
# the domain's own declarations:
#
#   examples/pizzas/
#     bluebook/
#       pizzas.bluebook        the domain
#       pizzas.hecksagon       the wiring — Pizzas::Pizza.persisted_by("Sqlite")
#       pizzas.world           the per-deployment values
#     data/                    whatever the adapters write
#
# FAMILIES AND ADAPTERS ARE NOT IN THERE. A family is declared once and used
# across every domain's hexagon — that is the whole point of the inverted arrow,
# and two copies of one family is exactly the drift this project exists to kill.
# They live in a shared `boundary/` folder, found by walking up from the domain
# the way a tool finds its project root:
#
#   boundary/
#     persistence.family     the how-verb vocabulary
#     sqlite.adapter         the inverted arrow
#     memory.adapter
#
# Load order is DEPENDENCY order, not alphabetical: the shared boundary first so
# binds can type-check against it, then the domain, its wiring, and its values.
#
#   Loader.boot("examples/pizzas")  # => Dispatcher
module Hecksagain
  module Runtime
    class Loader
      SHARED_ORDER = %w[*.family *.adapter].freeze
      DOMAIN_ORDER = %w[*.family *.adapter *.bluebook *.hecksagon *.world].freeze

      BOUNDARY = "boundary"

      def self.boot(path, boundary: nil)
        directory = bluebook_directory(path)
        shared    = boundary_directory(boundary, directory)
        registry  = Registry.new(root: File.dirname(directory))

        Hecksagain.with_registry(registry) do
          load_each(shared, SHARED_ORDER) if shared
          load_each(directory, DOMAIN_ORDER)
        end

        registry.verify!
        bind_runtime(Dispatcher.new(registry))
      end

      def self.load_each(directory, patterns)
        patterns.each do |pattern|
          Dir[File.join(directory, pattern)].sort.each { |file| Kernel.load(file) }
        end
      end

      # Accepts either the domain directory or its bluebook/ folder directly.
      def self.bluebook_directory(path)
        expanded = File.expand_path(path)
        nested   = File.join(expanded, "bluebook")

        return nested   if File.directory?(nested)
        return expanded if File.directory?(expanded)

        raise Errno::ENOENT, "no such domain directory: #{path}"
      end

      # An explicit boundary wins ; otherwise walk up until one turns up. A
      # domain with no boundary above it is fine — it simply has to declare its
      # own families, which is what a standalone example does.
      def self.boundary_directory(given, directory)
        return File.expand_path(given) if given

        current = directory
        loop do
          candidate = File.join(current, BOUNDARY)
          return candidate if File.directory?(candidate)

          parent = File.dirname(current)
          return nil if parent == current

          current = parent
        end
      end

      # The classes were constructed while the bluebook was read, before any
      # runtime existed. Boot is where they learn which one they belong to.
      def self.bind_runtime(dispatcher)
        dispatcher.registry.bluebooks.each_value do |bluebook|
          bluebook.aggregates.each { |aggregate| aggregate.ruby_class.runtime = dispatcher }
        end
        dispatcher
      end
    end
  end
end
