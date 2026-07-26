# Folder — the loading adapter's implementation : the folder convention.
#
# A domain is a directory containing a `bluebook/` folder holding its own
# declarations — the .bluebook, its .hecksagon, its .world. Ports and adapters
# are NOT in there : they ship with the library, one folder each, named for what
# they hold.
#
#   lib/hecksagain/ports/persistence/persistence.port      the CONTRACT
#   lib/hecksagain/adapters/driven/sqlite/sqlite.adapter   the DECLARATION
#   lib/hecksagain/adapters/driven/sqlite/sqlite.rb        the IMPLEMENTATION
#
# A declaration and its implementation are one thing said two ways, so they sit
# together. The adapter does NOT sit inside the port : the port must never name
# its adapters, and that inversion is what makes a new backend purely additive.
#
# Adapters split by SIDE. `driven/` are edges that LEAVE the domain — the domain
# composes a call, the adapter runs it. `driving/` is the inverse, an external
# clock or caller reaching IN to dispatch.
#
# Load order is DEPENDENCY order, never alphabetical : a port declares the verb,
# an adapter declares a port, the hecksagon names both, the world supplies
# values. Alphabetical would boot a hecksagon before the adapter it binds.
module Hecksagain
  module Adapters
    class Folder
      DOMAIN_ORDER = %w[*.port *.adapter *.bluebook *.hecksagon *.world].freeze
      PORTS        = "ports"
      ADAPTERS     = "adapters"

      def initialize(settings: {}, root: nil)
        @settings = settings
        @root     = root
      end

      # Every declaration the library itself ships, in dependency order. One
      # folder per port and per adapter, so the glob reaches one level in.
      def load_library
        load_each(library(PORTS),    %w[*/*.port])
        load_each(library(ADAPTERS), %w[*/*.adapter */*/*.adapter])
      end

      # A project's own ports and adapters, if it has any. Loaded AFTER the
      # library's, so they add rather than silently replace.
      def load_project(root)
        return unless root

        load_each(File.join(root, PORTS),    %w[*.port */*.port])
        load_each(File.join(root, ADAPTERS), %w[*.adapter */*.adapter */*/*.adapter])
      end

      def load_domain(directory) = load_each(directory, DOMAIN_ORDER)

      def load_each(directory, patterns)
        return unless File.directory?(directory)

        patterns.each do |pattern|
          Dir[File.join(directory, pattern)].sort.each { |file| Kernel.load(file) }
        end
      end

      # Accepts either the domain directory or its bluebook/ folder directly.
      def bluebook_directory(path)
        expanded = File.expand_path(path)
        nested   = File.join(expanded, "bluebook")

        return nested   if File.directory?(nested)
        return expanded if File.directory?(expanded)

        raise Errno::ENOENT, "no such domain directory: #{path}"
      end

      # A directory above the domain holding the project's OWN ports/ or
      # adapters/. An explicit one wins ; otherwise walk up until one turns up.
      # Finding none is the ordinary case — most projects use only the library's.
      def shared_root(given, directory)
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

      # A folder shipped with the library, resolved relative to THIS file so it
      # is found wherever the gem lives. Two levels up from
      # adapters/driven/folder/ is lib/hecksagain/.
      def library(folder)
        File.expand_path("../../../#{folder}", __dir__)
      end
    end
  end
end
