Hecks::Chapters.load_aggregates(
  Hecks::Cli::CliTools,
  base_dir: File.expand_path("..", __dir__)
)

module Hecks
  class CLI < Thor
    # Hecks::CLI::Gem
    #
    # Gem packaging commands -- delegates to GemBuilder to build and install
    # all Hecks component gems from their subdirectories.
    #
    #   hecks gem build
    #   hecks gem install
    #
    class Gem < Thor
      desc "build", "Build all component gems and the meta-gem"
      # Builds every component gem from its own directory, then the meta-gem.
      #
      # @return [void]
      def build
        root = gem_root
        return unless root
        builder(root).build
      end

      desc "install", "Build and install all component gems locally"
      # Builds and installs every component gem, then the meta-gem.
      #
      # @return [void]
      def install
        root = gem_root
        return unless root
        builder(root).install
      end

      private

      def builder(root)
        GemBuilder.new(root, output: method(:say))
      end

      def gem_root
        root = Dir.pwd
        gemspec = ::File.join(root, "hecks.gemspec")
        unless ::File.exist?(gemspec)
          say "hecks.gemspec not found at #{root}", :red
          return nil
        end
        root
      end
    end
  end
end
