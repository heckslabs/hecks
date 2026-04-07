# Hecks::Chapters::Workshop::HandlesParagraph
#
# Paragraph covering AggregateHandle children: presenter, behavior,
# constraints, queries, and implicit dot-syntax support.
#
#   Hecks::Chapters::Workshop::HandlesParagraph.define(builder)
#
module Hecks
  module Chapters
    module Workshop
      module HandlesParagraph
        def self.define(b)
          b.aggregate "Presenter" do
            description "Session mixin for human-readable output: describe, status, and inspect"
            command "Describe"
            command "ShowStatus"
          end

          b.aggregate "BehaviorMethods" do
            description "AggregateHandle mixin for adding commands, events, policies, and lifecycle transitions"
            command "AddCommand" do
              attribute :name, String
            end
          end

          b.aggregate "ConstraintMethods" do
            description "AggregateHandle mixin for adding validations, specifications, and scopes"
            command "AddValidation" do
              attribute :name, String
            end
          end

          b.aggregate "QueryMethods" do
            description "AggregateHandle mixin for adding queries and subscribers"
            command "AddQuery" do
              attribute :name, String
            end
          end

          b.aggregate "ImplicitSyntax" do
            description "AggregateHandle mixin for dot-syntax method_missing attribute and command inference"
            command "HandleMissing" do
              attribute :method_name, String
            end
          end
        end
      end
    end
  end
end
