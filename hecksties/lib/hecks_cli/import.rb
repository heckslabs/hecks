require_relative "import/schema_parser"
require_relative "import/model_parser"
require_relative "import/domain_assembler"

module Hecks
  # Hecks::Import
  #
  # Reverse-engineers a Rails application into a Hecks domain definition.
  # Parses db/schema.rb for structure and app/models/*.rb for behavior
  # (validations, enums, state machines). Outputs valid Hecks DSL.
  #
  #   Hecks::Import.from_rails("/path/to/rails/app")
  #   # => "Hecks.domain \"Blog\" do\n  aggregate \"Post\" do\n    ..."
  #
  module Import
    def self.from_rails(app_path, domain_name: nil)
      schema_path = File.join(app_path, "db", "schema.rb")
      models_dir  = File.join(app_path, "app", "models")
      domain_name ||= Hecks::Utils.sanitize_constant(File.basename(File.expand_path(app_path)))

      schema_data = SchemaParser.new(schema_path).parse
      model_data  = File.directory?(models_dir) ? ModelParser.new(models_dir).parse : {}
      DomainAssembler.new(schema_data, model_data, domain_name: domain_name).assemble
    end

    def self.from_schema(schema_path, domain_name: "MyDomain")
      schema_data = SchemaParser.new(schema_path).parse
      DomainAssembler.new(schema_data, {}, domain_name: domain_name).assemble
    end
  end
end
