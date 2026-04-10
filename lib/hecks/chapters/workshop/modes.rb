# Hecks::Chapters::Workshop::ModesParagraph
#
# Paragraph covering workshop interaction modes: play, visualize,
# browsing, inspection, and domain navigation.
#
#   Hecks::Chapters::Workshop::ModesParagraph.define(builder)
#
module Hecks
  module Chapters
    module Workshop
      module ModesParagraph
        def self.define(b)
          b.aggregate "PlayMode" do
            description "Session mixin for play mode: executing commands against a live compiled domain"
            command "EnterPlay"
            command "ExitPlay"
            command "ResetPlayground"
          end

          b.aggregate "VisualizeMode" do
            description "Mermaid diagram visualization for the Workshop"
            command "Visualize" do
              attribute :format, String
            end
          end

          b.aggregate "SystemBrowser" do
            description "Smalltalk-inspired tree view of all domain elements"
            command "Browse" do
              attribute :aggregate_name, String
            end
          end

          b.aggregate "DeepInspect" do
            description "Detailed aggregate structure display using Navigator and Renderer"
            command "Inspect" do
              attribute :aggregate_name, String
            end
          end

          b.aggregate "Navigator" do
            description "Traverses domain IR and yields each element with depth and path context"
            command "Walk" do
              attribute :aggregate_name, String
            end
            command "WalkAll"
          end

          b.aggregate "Renderer" do
            description "Formats domain IR elements into human-readable lines for deep_inspect"
            command "RenderAttribute"
            command "RenderCommand"
          end
        end
      end
    end
  end
end
