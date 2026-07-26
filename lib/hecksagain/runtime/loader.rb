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
# PORTS AND ADAPTERS ARE NOT IN THERE. They are the two halves of the inverted
# arrow, and each ships with the library beside its implementation:
#
#   lib/hecksagain/ports/
#     persistence.port       the PORT — the how-verb and the signal
#   lib/hecksagain/adapters/
#     sqlite.adapter         the DECLARATION — its port, and the config it needs
#     sqlite.rb              the IMPLEMENTATION — the same thing said in Ruby
#     memory.adapter
#     memory.rb
#
# A declaration and its implementation are one thing described two ways, so
# they live together. A project that brings its OWN port or adapter puts them
# in a ports/ or adapters/ folder above its domains, found by walking up — the
# library's are loaded first, so a project's can only add, never silently
# replace.
#
# Load order is DEPENDENCY order, not alphabetical: ports declare the verb, an
# adapter declares a port, the hecksagon names both, the world supplies values.
#
#   Loader.boot("examples/pizzas")  # => Dispatcher
module Hecksagain
  module Runtime
    class Loader
      PORTS    = "ports"
      ADAPTERS = "adapters"
      DOMAIN_ORDER = %w[*.port *.adapter *.bluebook *.hecksagon *.world].freeze

      def self.boot(path, shared: nil)
        directory = bluebook_directory(path)
        root      = shared_root(shared, directory)
        registry  = Registry.new(root: File.dirname(directory))

        Hecksagain.with_registry(registry) do
          # The library's own — always.
          load_each(library(PORTS),    %w[*.port])
          load_each(library(ADAPTERS), %w[*.adapter])

          # A project's own, if it has any. Loaded after, so they add rather
          # than silently replace.
          if root
            load_each(File.join(root, PORTS),    %w[*.port])
            load_each(File.join(root, ADAPTERS), %w[*.adapter])
          end

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

      # A folder shipped with the library, resolved relative to this file so it
      # is found wherever the gem lives.
      def self.library(folder)
        File.expand_path("../#{folder}", __dir__)
      end

      # Accepts either the domain directory or its bluebook/ folder directly.
      def self.bluebook_directory(path)
        expanded = File.expand_path(path)
        nested   = File.join(expanded, "bluebook")

        return nested   if File.directory?(nested)
        return expanded if File.directory?(expanded)

        raise Errno::ENOENT, "no such domain directory: #{path}"
      end

      # A directory above the domain holding the project's OWN ports/ or
      # adapters/. An explicit one wins ; otherwise walk up until one turns up.
      # Finding none is the ordinary case — most projects use only the
      # library's.
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
