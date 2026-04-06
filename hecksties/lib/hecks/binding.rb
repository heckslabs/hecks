# Hecks::Binding
#
# The Binding is the spine of a Bluebook. It holds chapters together:
# module wiring, shared utilities, error hierarchy, registries,
# cross-chapter event routing, and the compositor that loads and
# connects all chapters.
#
# In a physical book the binding is not a chapter — without it the
# pages fall apart. Same here. Hierarchy: bluebook > binding > chapters.
#
#   domain = Hecks::Binding.definition
#   domain.aggregates.map(&:name)
#   # => ["Module", "Registry", "Error", "Utils",
#   #     "EventRouter", "ChapterWiring", "CrossChapterQuery"]
#
module Hecks
  module Binding
    def self.definition
      @definition ||= DSL::DomainBuilder.new("Binding").tap { |b|
        b.instance_eval do
          aggregate "Module" do
            attribute :name, String

            command "ExtendModule" do
              attribute :module_name, String
              attribute :mixin, String
            end

            command "RequireGem" do
              attribute :gem_name, String
            end

            command "RegisterGrammar" do
              attribute :name, String
            end
          end

          aggregate "Registry" do
            attribute :name, String
            attribute :type, String

            command "CreateRegistry" do
              attribute :name, String
            end

            command "Register" do
              attribute :registry_id, String
              attribute :key, String
            end

            command "Lookup" do
              attribute :registry_id, String
              attribute :key, String
            end
          end

          aggregate "Error" do
            attribute :name, String
            attribute :message, String

            command "DefineError" do
              attribute :name, String
              attribute :parent, String
            end

            command "RaiseError" do
              attribute :error_id, String
              attribute :message, String
            end
          end

          aggregate "Utils" do
            attribute :name, String

            command "SanitizeConstant" do
              attribute :input, String
            end

            command "Underscore" do
              attribute :input, String
            end

            command "TypeLabel" do
              attribute :attribute_id, String
            end
          end

          aggregate "EventRouter" do
            attribute :source_chapter, String
            attribute :allowed_targets, String

            command "BuildDirectionality" do
              attribute :chapter_names, String
            end

            command "FilterEvents" do
              attribute :source_chapter, String
              attribute :target_chapter, String
            end

            command "RouteEvent" do
              attribute :event_name, String
              attribute :source_chapter, String
            end
          end

          aggregate "ChapterWiring" do
            attribute :chapter_name, String

            command "WireChapter" do
              attribute :chapter_name, String
            end

            command "WireQueue" do
              attribute :chapter_name, String
            end

            command "ValidateChapters" do
              attribute :chapter_names, String
            end
          end

          aggregate "CrossChapterQuery" do
            attribute :source_chapter, String
            attribute :target_chapter, String

            command "QueryAcrossChapters" do
              attribute :source_chapter, String
              attribute :target_aggregate, String
            end

            command "ProjectView" do
              attribute :view_name, String
              attribute :event_name, String
            end
          end

          policy "WireOnBoot" do
            on "RequiredGem"
            trigger "ExtendModule"
          end

          policy "RouteOnWire" do
            on "WiredChapter"
            trigger "BuildDirectionality"
          end
        end
      }.build
    end
  end
end
