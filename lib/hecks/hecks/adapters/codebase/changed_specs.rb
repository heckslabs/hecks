# frozen_string_literal: true

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

            by_name.fetch(File.basename(file, ".rb") + "_spec.rb", [])
          end.uniq.sort
        end

        # @param changed [Array<String>] the changed files
        # @param specs [Array<String>] every spec file of the folder
        # @return [Array<String>] the changed Ruby files that map to no spec, for the report
        def unmapped(changed, specs)
          mapped = call(changed, specs)
          changed.select { |file| file.end_with?(".rb") && !mapped.include?(file) && call([file], specs).empty? }
        end
      end
    end
  end
end
