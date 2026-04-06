# Hecks::Chapters::Cli
#
# Self-describing Bluebook chapter for the CLI module. Defines the
# CLI's own domain: command registration, grouped help, conflict
# resolution, domain resolution, build pipeline, and scaffolding.
#
#   domain = Hecks::Chapters::Cli.definition
#   domain.aggregates.map(&:name)
#   # => ["CommandRegistry", "ConflictHandler", "DomainResolver",
#   #     "BuildPipeline", "DomainQuery", "Scaffold", "Versioning"]
#
module Hecks
  module Chapters
    module Cli
      def self.definition
        @definition ||= DSL::DomainBuilder.new("Cli").tap { |b|
          b.instance_eval do
            aggregate "CommandRegistry" do
              attribute :name, String
              attribute :description, String
              attribute :group, String

              command "RegisterCommand" do
                attribute :name, String
                attribute :description, String
                attribute :group, String
              end

              command "InstallCommands"

              command "InferGroup" do
                attribute :path, String
              end
            end

            aggregate "ConflictHandler" do
              attribute :path, String
              attribute :force, :Boolean

              command "WriteOrDiff" do
                attribute :path, String
                attribute :new_content, String
              end

              command "ShowDiff" do
                attribute :old_content, String
                attribute :new_content, String
              end

              command "ResolveInteractively" do
                attribute :path, String
              end
            end

            aggregate "DomainResolver" do
              attribute :path, String

              command "ResolveDomainOption" do
                attribute :domain, String
              end

              command "FindDomainFile"

              command "LoadDomainFile" do
                attribute :file, String
              end

              command "FindInstalledDomains"
            end

            aggregate "BuildPipeline" do
              attribute :domain, String
              attribute :target, String
              attribute :version, String

              command "Build" do
                attribute :domain, String
                attribute :target, String
              end

              command "Validate" do
                attribute :domain, String
                attribute :format, String
              end

              command "Inspect" do
                attribute :domain, String
                attribute :format, String
              end

              command "Visualize" do
                attribute :domain, String
                attribute :diagram_type, String
              end
            end

            aggregate "DomainQuery" do
              attribute :domain, String

              command "List"
              command "Tree"

              command "Glossary" do
                attribute :domain, String
              end

              command "Info"

              command "ContextMap" do
                attribute :domain, String
              end

              command "Dump" do
                attribute :domain, String
              end
            end

            aggregate "Scaffold" do
              attribute :name, String

              command "NewProject" do
                attribute :name, String
              end

              command "Init" do
                attribute :name, String
              end

              command "Interview"

              command "Import" do
                attribute :source, String
              end

              command "Extract"
            end

            aggregate "Versioning" do
              attribute :domain, String
              attribute :version, String

              command "ShowVersion" do
                attribute :domain, String
              end

              command "VersionTag" do
                attribute :version, String
              end

              command "VersionLog" do
                attribute :domain, String
              end

              command "Diff" do
                attribute :v1, String
                attribute :v2, String
              end
            end
          end
        }.build
      end
    end
  end
end
