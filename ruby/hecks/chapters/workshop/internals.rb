# Hecks::Chapters::Workshop::InternalsParagraph
#
# Paragraph covering workshop internals: message-not-understood error
# and bluebook mode.
#
#   Hecks::Chapters::Workshop::InternalsParagraph.define(builder)
#
module Hecks
  module Chapters
    module Workshop
      module InternalsParagraph
        def self.define(b)
          b.aggregate "MessageNotUnderstood" do
            description "Smalltalk-inspired error for unknown aggregate handle methods with command suggestions"
            command "HandleMissing" do
              attribute :method_name, String
            end
          end

          b.aggregate "BluebookMode" do
            description "Workshop mixin for composing multiple domains as chapters with shared event bus"
            command "AddChapter" do
              attribute :name, String
            end
            command "ListChapters"
            command "ToBluebook"
          end
        end
      end
    end
  end
end
