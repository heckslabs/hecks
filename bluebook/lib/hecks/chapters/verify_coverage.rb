# Hecks::Chapters::CoverageVerifier
#
# Walks all .rb files in lib/ directories and checks each is covered
# by at least one chapter aggregate. Reports uncovered files. After
# the Kernel chapter is added, uncovered count should be zero —
# proving the Bluebook is a complete specification of Hecks.
#
#   result = Hecks::Chapters::CoverageVerifier.run(format: :progress)
#   result.uncovered  # => [] (hopefully!)
#
module Hecks
  module Chapters
    class CoverageVerifier
      Result = Struct.new(:pass_count, :errors, :uncovered, keyword_init: true)

      # Directories that contain framework implementation files.
      LIB_DIRS = %w[
        bluebook/lib hecksties/lib hecksagon/lib hecks_workshop/lib
        hecks_ai/lib hecks_on_rails/lib
        hecks_targets/ruby/lib hecks_targets/go/lib hecks_targets/node/lib
        hecksties/watchers/lib examples/lib
      ].freeze

      # Files that are entry points or glue — not aggregates.
      SKIP_PATTERNS = %w[
        /chapters/ /version.rb boot.rb boot_bluebook.rb features.rb
        bluebook.rb hecksagon.rb hecks_workshop.rb hecks_ai.rb
        hecks_on_rails.rb hecks_serve.rb
        hecks_targets.rb hecks_multidomain.rb
        self_compile.rb
      ].freeze

      def self.run(root: nil, format: :progress)
        root ||= File.expand_path("../../../..", __dir__)
        new(root, format).run
      end

      def initialize(root, format)
        @root = root
        @format = format
      end

      def run
        all_names = collect_aggregate_names
        lib_files = collect_lib_files
        uncovered = []
        pass_count = 0

        puts "\e[1mCoverage\e[0m" if @format == :documentation

        lib_files.each do |file|
          basename = File.basename(file, ".rb")
          if all_names.include?(basename) || all_names.include?(camelize(basename))
            pass_count += 1
            if @format == :documentation
              puts "  \e[32m.\e[0m #{relative(file)}"
            else
              print "."
            end
          else
            uncovered << relative(file)
            if @format == :documentation
              puts "  \e[33m?\e[0m #{relative(file)} (uncovered)"
            else
              print "\e[33m?\e[0m"
            end
          end
        end

        puts "" if @format == :documentation

        errors = uncovered.map do |f|
          { context: "Coverage/#{f}", message: "not covered by any chapter aggregate" }
        end

        Result.new(pass_count: pass_count, errors: errors, uncovered: uncovered)
      end

      private

      def collect_aggregate_names
        names = Set.new
        chapter_modules = Chapters.constants
          .map { |c| Chapters.const_get(c) }
          .select { |m| m.respond_to?(:definition) }

        chapter_modules.each do |mod|
          mod.definition.aggregates.each do |agg|
            names << agg.name
            names << underscore(agg.name)
          end
        end
        names
      end

      def collect_lib_files
        files = []
        LIB_DIRS.each do |dir|
          full = File.join(@root, dir)
          next unless File.directory?(full)
          Dir.glob(File.join(full, "**", "*.rb")).each do |f|
            rel = f.sub("#{@root}/", "")
            next if SKIP_PATTERNS.any? { |p| rel.include?(p) }
            files << f
          end
        end
        files.sort
      end

      def underscore(str)
        str.gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
           .gsub(/([a-z\d])([A-Z])/, '\1_\2')
           .downcase
      end

      def camelize(str)
        str.split("_").map(&:capitalize).join
      end

      def relative(path)
        path.sub("#{@root}/", "")
      end
    end
  end
end
