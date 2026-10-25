require "fileutils"
require "json"
require_relative "../projections/command_schema"

module Hecks
  module RustBuild
    # `schemas.json` beside a generated domain's `ir.json`: each command's JSON Schema by
    # `Aggregate/Command`. The host has no Ruby, so it serves what the build projected here.
    module CommandSchemas
      FILE = "schemas.json".freeze

      module_function

      # @param bluebook [Bluebook::Chapter] the target domain's chapter
      # @param dir [String] the domain's generated directory
      # @return [String] the path written
      def write(bluebook, dir)
        files = Projections::CommandSchema.call(bluebook: bluebook)
        schemas = files.to_h do |path, text|
          [path.delete_prefix("#{bluebook.name}/").delete_suffix(".schema.json"), JSON.parse(text)]
        end
        FileUtils.mkdir_p(dir)
        File.join(dir, FILE).tap { |path| File.write(path, "#{JSON.pretty_generate(schemas)}\n") }
      end
    end
  end
end
