Hecks::Chapters.load_aggregates(
  Hecks::Chapters::Cli::CliImport,
  base_dir: File.expand_path("import", __dir__)
)
  # Hecks::Import
  #
  # Reverse-engineers a Rails application into a Hecks domain definition.
  # Parses db/schema.rb for structure and app/models/*.rb for behavior
  # (validations, enums, state machines). Outputs valid Hecks DSL.
  #
  #   Hecks::Import.from_rails("/path/to/rails/app")
  #   # => "Hecks.domain \"Blog\" do\n  aggregate \"Post\" do\n    ..."
  #

module Hecks
  # Hecks::Import
  #
  # Reverse-engineers a Rails application into a Hecks domain definition by parsing schema and models.
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

    def self.from_directory(path, domain_name: nil)
      schema_path = File.join(path, "db", "schema.rb")
      domain_name ||= Hecks::Utils.sanitize_constant(File.basename(File.expand_path(path)))

      if File.exist?(schema_path)
        from_rails(path, domain_name: domain_name)
      else
        models_dir = detect_models_dir(path)
        from_models(models_dir, domain_name: domain_name)
      end
    end

    def self.from_models(models_dir, domain_name: "MyDomain")
      model_data = ModelParser.new(models_dir).parse
      ModelOnlyAssembler.new(model_data, domain_name: domain_name).assemble
    end

    def self.detect_models_dir(path)
      candidates = [
        File.join(path, "app", "models"),
        File.join(path, "models"),
        path
      ]
      candidates.find { |d| File.directory?(d) } || path
    end
    private_class_method :detect_models_dir
  end
end
