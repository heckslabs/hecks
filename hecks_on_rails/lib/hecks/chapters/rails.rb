# Hecks::Chapters::Rails
#
# Self-describing Bluebook chapter for the hecks_on_rails (ActiveHecks)
# module. Models the Rails integration layer as a domain: ActiveModel
# compatibility mixins, validation wiring, persistence wrapping,
# Railtie boot hooks, and Rails generators.
#
#   domain = Hecks::Chapters::Rails.definition
#   domain.aggregates.map(&:name)
#   # => ["Activation", "AggregateCompat", "ValidationWiring",
#   #     "PersistenceWrapper", "Railtie", "InitGenerator",
#   #     "MigrationGenerator"]
#
module Hecks
  module Chapters
    module Rails
      def self.definition
        @definition ||= DSL::DomainBuilder.new("Rails").tap { |b|
          b.instance_eval do
            aggregate "Activation" do
              command "Activate" do
                attribute :domain_module, String
                attribute :domain, String
              end
            end

            aggregate "AggregateCompat" do
              attribute :persisted, String
              attribute :new_record, String
              attribute :destroyed, String

              command "DefineCallbacks" do
                attribute :target_class, String
              end
            end

            aggregate "ValidationWiring" do
              command "Bind" do
                attribute :target_class, String
                attribute :domain, String
              end

              command "DisableConstructorValidation" do
                attribute :target_class, String
              end

              command "WireValidations" do
                attribute :target_class, String
                attribute :domain, String
              end
            end

            aggregate "PersistenceWrapper" do
              command "Bind" do
                attribute :target_class, String
              end

              command "WrapSave" do
                attribute :target_class, String
              end

              command "WrapDestroy" do
                attribute :target_class, String
              end
            end

            aggregate "Railtie" do
              command "Setup"

              command "GenerateMigrations" do
                attribute :output_dir, String
              end

              command "RunMigrations" do
                attribute :migration_dir, String
              end
            end

            aggregate "InitGenerator" do
              command "DetectDomainGem"

              command "CreateInitializer" do
                attribute :gem_name, String
              end

              command "SetupTestHelper"
            end

            aggregate "MigrationGenerator" do
              command "GenerateMigration" do
                attribute :domain, String
                attribute :snapshot_path, String
              end
            end
          end
        }.build
      end
    end
  end
end
