require "fileutils"

module Hecks
  module CLI
    # Writes the files `hecks init` and `hecks interview` produce, never replacing one (ADR 0087).
    #
    # Every target is checked before the first is written, so a refusal leaves nothing half-written.
    module DomainWriter
      module_function

      # @param files [Hash{String => String}] each file's path under the target, and its text
      # @param target [String] the absolute path of the domain directory
      # @return [Array<String>] the paths written, relative to the target
      # @raise [ArgumentError] when any file, or a bluebook the files would add, is already there
      def write!(files, target)
        taken = taken(files, target)
        raise ArgumentError, "nothing written; already there: #{taken.join(', ')}" unless taken.empty?

        files.each do |path, text|
          full = File.join(target, path)
          FileUtils.mkdir_p(File.dirname(full))
          File.write(full, text)
        end
        files.keys
      end

      # @param files [Hash{String => String}] the files about to be written
      # @param target [String] the domain directory
      # @return [Array<String>] the paths in the way, relative to the target
      def taken(files, target)
        taken = files.keys.select { |path| File.exist?(File.join(target, path)) }
        if files.keys.any? { |path| path.match?(%r{\Abluebook/[^/]+\.bluebook\z}) }
          taken |= Dir.glob(File.join(target, "bluebook", "*.bluebook")).map { |full| full.delete_prefix("#{target}/") }
        end
        taken
      end
    end
  end
end
