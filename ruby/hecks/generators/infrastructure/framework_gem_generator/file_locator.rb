module Hecks
  module Generators
    module Infrastructure
      class FrameworkGemGenerator
        # Hecks::Generators::Infrastructure::FrameworkGemGenerator::FileLocator
        #
        # Maps aggregate names to actual file paths in a gem by matching
        # the snake_cased aggregate name against .rb files in lib/.
        # Tries exact match first, then stripped prefixes, then suffix match.
        #
        #   locator = FileLocator.new("hecksagon")
        #   locator.locate("GateBuilder")     # => "hecksagon/dsl/gate_builder.rb"
        #   locator.locate("HecksSqlite")     # => "hecks/extensions/sqlite.rb"
        #   locator.locate("NonExistent")     # => nil
        #
        class FileLocator
          def initialize(gem_root)
            @gem_root = gem_root
            @lib_root = File.join(gem_root, "lib")
            @index    = build_index
          end

          def locate(aggregate_name)
            snake = Hecks::Utils.underscore(aggregate_name)

            # Exact basename match
            return @index[snake] if @index[snake]

            # Strip "hecks_" prefix (e.g., HecksCqrs → cqrs)
            stripped = snake.sub(/\Ahecks_/, "")
            return @index[stripped] if stripped != snake && @index[stripped]

            # Strip "hecksagon_" prefix
            stripped2 = snake.sub(/\Ahecksagon_/, "")
            return @index[stripped2] if stripped2 != snake && @index[stripped2]

            # Suffix match — find files ending with the snake name
            @index.each do |basename, path|
              return path if basename.end_with?(snake) || snake.end_with?(basename)
            end

            nil
          end

          private

          def build_index
            return {} unless Dir.exist?(@lib_root)

            idx = {}
            Dir.glob(File.join(@lib_root, "**", "*.rb")).each do |abs|
              rel      = abs.sub("#{@lib_root}/", "")
              basename = File.basename(rel, ".rb")
              # Skip chapter definitions — they describe the gem, not implement it
              next if rel.include?("chapters/")
              # First match wins; prefer shorter paths (less nesting)
              idx[basename] = rel unless idx.key?(basename)
            end
            idx
          end
        end
      end
    end
  end
end
