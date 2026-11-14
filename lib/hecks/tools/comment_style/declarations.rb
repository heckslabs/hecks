# frozen_string_literal: true

require_relative "declaration_file"

module Hecks
  module Tools
    module CommentStyle
      # The declaration files among a run's paths, and what their comment blocks add to the run's
      # violations and to the baseline. Mixed into {Run}.
      module Declarations
        # The files a directory holds that declare: a vendored package is another project's and
        # is checked there.
        #
        # @param paths [Array<String>] files or directories
        # @return [Array<String>] the declaration files, sorted
        def declaration_files(paths)
          found = paths.flat_map do |path|
            File.directory?(path) ? Dir[File.join(path, "**", DECLARATION_FILES)] : [path].select { |file| declares?(file) }
          end
          found.reject { |file| file.include?(VENDORED) }.sort.uniq
        end

        # @param file [String] a path
        # @return [Boolean] whether it is a declaration file by its name
        def declares?(file) = File.fnmatch(DECLARATION_FILES, File.basename(file), File::FNM_EXTGLOB)

        private

        def declaration_violations
          @declarations.flat_map { |path| DeclarationFile.new(path).violations(baseline: @baseline) }
        end

        # Every declaration block over its cap, in the baseline's own shape.
        def declaration_baseline
          @declarations.each_with_object({}) do |path, held|
            blocks = DeclarationFile.new(path).long_blocks
            held[path.delete_prefix("./")] = blocks.to_h { |block| [block.key, block.lines] } if blocks.any?
          end
        end
      end
    end
  end
end
