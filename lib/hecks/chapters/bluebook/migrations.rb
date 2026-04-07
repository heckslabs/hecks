# Hecks::Chapters::Bluebook::MigrationsParagraph
#
# Paragraph covering migration classes: domain IR diffing,
# snapshot persistence, and migration runners that apply
# schema changes across domain versions.
#
#   Hecks::Chapters::Bluebook::MigrationsParagraph.define(builder)
#
module Hecks
  module Chapters
    module Bluebook
      module MigrationsParagraph
        def self.define(b)
          b.aggregate "DomainDiff", "Diffs two domain IRs to produce a list of structural changes" do
            command("DiffDomains") { attribute :old_domain_id, String; attribute :new_domain_id, String }
          end

          b.aggregate "BehaviorDiff", "Diffs behavior-level changes between domain versions" do
            command("DiffBehaviors") { attribute :old_domain_id, String; attribute :new_domain_id, String }
          end

          b.aggregate "DomainSnapshot", "Saves and loads domain IR snapshots for migration diffing" do
            command("SaveSnapshot") { attribute :domain_id, String; attribute :path, String }
            command("LoadSnapshot") { attribute :path, String }
          end

          b.aggregate "MigrationRunner", "Applies migration files to update domain persistence" do
            command("RunMigrations") { attribute :domain_id, String; attribute :path, String }
          end

          b.aggregate "MigrationStrategy", "Base class for migration strategies (SQL, NoSQL, etc.)" do
            command("ApplyStrategy") { attribute :migration_id, String; attribute :target, String }
          end
        end
      end
    end
  end
end
