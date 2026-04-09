# Hecks::ValidationRules::Structure::FileCoverage
#
# @domain AcceptanceTest
#
# Validates that every Ruby file in the project's lib directories is
# covered by at least one chapter aggregate. Uncovered files mean the
# bluebook is incomplete — there's implementation without a domain model.
#
#   rule = FileCoverage.new(domain)
#   rule.errors  # => ["crud.rb not covered by any aggregate"]
#
module Hecks
  module ValidationRules
    module Structure

    class FileCoverage < BaseRule
      SKIP_PATTERNS = %w[
        /chapters/ /version.rb boot.rb features.rb
        bluebook.rb hecksagon.rb
      ].freeze

      def errors
        return [] unless scan_dirs.any?
        result = []
        names = aggregate_names
        lib_files.each do |file|
          basename = File.basename(file, ".rb")
          unless names.include?(basename) || names.include?(camelize(basename))
            result << error("#{relative(file)} not covered by any aggregate",
              hint: "Add an aggregate named '#{camelize(basename)}' to a chapter")
          end
        end
        result
      end

      def warnings
        errors
      end

      private

      def aggregate_names
        names = Set.new
        @domain.aggregates.each do |agg|
          names << agg.name
          names << underscore(agg.name)
        end
        names
      end

      def scan_dirs
        root = project_root
        return [] unless root
        %w[lib].map { |d| File.join(root, d) }.select { |d| Dir.exist?(d) }
      end

      def lib_files
        scan_dirs.flat_map do |dir|
          Dir.glob(File.join(dir, "**", "*.rb")).reject do |f|
            SKIP_PATTERNS.any? { |p| f.include?(p) }
          end
        end.sort
      end

      def project_root
        return nil unless @domain.respond_to?(:source_path) && @domain.source_path
        path = File.dirname(@domain.source_path)
        3.times do
          return path if File.exist?(File.join(path, "Gemfile")) || Dir.exist?(File.join(path, "hecks"))
          path = File.dirname(path)
        end
        nil
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
        root = project_root
        root ? path.sub("#{root}/", "") : path
      end
    end
    Hecks.register_validation_rule(FileCoverage)
    end
  end
end
