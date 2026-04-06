# Hecks::Chapters::Workshop
#
# Self-describing domain definition for the Workshop chapter. The
# interactive REPL layer models itself as a domain: Workshop manages
# sessions and modes, Playground handles compilation and runtime.
#
#   domain = Hecks::Chapters::Workshop.definition
#   domain.aggregates.map(&:name)  # => ["Workshop", "Playground"]
#
module Hecks
  module Chapters
    module Workshop
      def self.definition
        @definition ||= DSL::DomainBuilder.new("Workshop").tap { |b|
          b.instance_eval do
            aggregate "Workshop" do
              attribute :name, String
              attribute :mode, String

              command "CreateWorkshop" do
                attribute :name, String
              end

              command "Play" do
                attribute :workshop_id, String
              end

              command "Sketch" do
                attribute :workshop_id, String
              end

              command "Execute" do
                attribute :workshop_id, String
                attribute :command_name, String
              end

              command "Reset" do
                attribute :workshop_id, String
              end
            end

            aggregate "Playground" do
              attribute :domain_name, String

              command "Compile" do
                attribute :domain_id, String
              end

              command "BootPlayground" do
                attribute :playground_id, String
              end
            end

            policy "CompileOnPlay" do
              on "Played"
              trigger "Compile"
            end

            policy "BootOnCompile" do
              on "Compiled"
              trigger "BootPlayground"
            end
          end
        }.build
      end
    end
  end
end
