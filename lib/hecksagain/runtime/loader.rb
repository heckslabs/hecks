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
# PORTS AND ADAPTERS ARE NOT IN THERE, and they are not together either.
# They are the two halves of the inverted arrow and each gets its own folder,
# shared across every domain:
#
#   families/
#     persistence.family     the PORT — the how-verb and the signal
#   adapters/
#     sqlite.adapter         an IMPLEMENTATION — declares its family, and the
#     memory.adapter         config fields it needs
#
# Both are found by walking up from the domain, the way a tool finds its
# project root, so nothing has to be configured for the ordinary case.
#
# Load order is DEPENDENCY order, not alphabetical: families first (an adapter
# declares the family it implements, so the family has to exist), then
# adapters, then the domain, its wiring, its values.
#
#   Loader.boot("examples/pizzas")  # => Dispatcher
module Hecksagain
  module Runtime
    class Loader
      PORTS = "ports"
      ADAPTERS = "adapters"
      DOMAIN_ORDER = %w[*.port *.adapter *.bluebook *.hecksagon *.world].freeze

      def self.boot(path, shared: nil)
        directory = bluebook_directory(path)
        root      = shared_root(shared, directory)
        registry  = Registry.new(root: File.dirname(directory))

        Hecksagain.with_registry(registry) do
          # Ports ship WITH THE LIBRARY. A port is a framework-level contract —
          # `persisted_by`, `:reply` — not something a project declares, so it
          # is not looked for beside the domain.
          load_each(library_ports, %w[*.port])

          # Adapters are the project's choice of backend, shared across its
          # domains, so they ARE found by walking up.
          load_each(File.join(root, ADAPTERS), %w[*.adapter]) if root

          load_each(directory, DOMAIN_ORDER)
        end

        registry.verify!
        bind_runtime(Dispatcher.new(registry))
      end

      def self.load_each(directory, patterns)
        return unless File.directory?(directory)

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

      # The directory holding families/ and adapters/. An explicit one wins ;
      # otherwise walk up until one turns up. A domain with neither above it is
      # fine — it simply has to declare its own, which is what a standalone
      # example does.
      # The ports that ship with the library — lib/hecksagain/ports/.
      def self.library_ports
        File.expand_path("../ports", __dir__)
      end

      def self.shared_root(given, directory)
        return File.expand_path(given) if given

        current = directory
        loop do
          return current if File.directory?(File.join(current, PORTS)) ||
                            File.directory?(File.join(current, ADAPTERS))

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
