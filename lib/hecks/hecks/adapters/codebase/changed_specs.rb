# frozen_string_literal: true

require "open3"

module Hecks
  module Adapters
    module Codebase
      # Which specs a set of changed files runs, by name alone: a changed spec runs itself, and a
      # changed source file runs the spec of the same name (`lib/x/thing.rb` runs `thing_spec.rb`).
      #
      # A file that maps to no spec is reported, not guessed at, so a change to a file no spec
      # names runs nothing rather than the whole suite.
      module ChangedSpecs
        module_function

        # @param changed [Array<String>] the changed files, relative to the folder
        # @param specs [Array<String>] every spec file of the folder, relative to the folder
        # @return [Array<String>] the specs to run, sorted and without duplicates
        def call(changed, specs)
          by_name = specs.group_by { |spec| File.basename(spec) }
          changed.flat_map do |file|
            next [file] if specs.include?(file)

            by_name.fetch("#{File.basename(file, ".rb")}_spec.rb", [])
          end.uniq.sort
        end

        # @param changed [Array<String>] the changed files
        # @param specs [Array<String>] every spec file of the folder
        # @return [Array<String>] the changed Ruby files that map to no spec, for the report
        def unmapped(changed, specs)
          mapped = call(changed, specs)
          changed.select { |file| file.end_with?(".rb") && !mapped.include?(file) && call([file], specs).empty? }
        end

        # The files that differ from the ref, tracked and untracked, relative to the folder.
        #
        # @param tree [Tree] the folder under git
        # @param base [String] the ref to compare against
        # @return [Array<String>] the changed files
        # @raise [ConsoleCapture::Failure] when git refuses, with what it said
        def changed_files(tree, base)
          diff, status = Open3.capture2e("git", "-C", tree.root, "diff", "--name-only", base, "--")
          raise ConsoleCapture::Failure, diff.strip unless status.success?

          untracked, = Open3.capture2("git", "-C", tree.root, "ls-files", "--others", "--exclude-standard")
          (diff.lines + untracked.lines).map(&:strip).reject(&:empty?).uniq
        end
      end
    end
  end
end
