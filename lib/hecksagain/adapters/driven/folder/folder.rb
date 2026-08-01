module Hecksagain
  module Adapters
    class Folder
      DOMAIN_ORDER = %w[*.port *.adapter *.bluebook translations/*.bluebook *.hecksagon *.world].freeze
      PORTS        = "ports"
      ADAPTERS     = "adapters"

      def initialize(settings: {}, root: nil)
        @settings = settings
        @root     = root
      end

      def load_library
        load_each(library(PORTS),    %w[*/*.port])
        load_each(library(ADAPTERS), %w[*/*.adapter */*/*.adapter])
      end

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

      def bluebook_directory(path)
        expanded = File.expand_path(path)
        nested   = File.join(expanded, "bluebook")

        return nested   if File.directory?(nested)
        return expanded if File.directory?(expanded)

        raise Errno::ENOENT, "no such domain directory: #{path}"
      end

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

      def library(folder)
        File.expand_path("../../../#{folder}", __dir__)
      end
    end
  end
end
