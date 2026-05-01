# Hecks::Chapters::Workshop::RunnerSupportParagraph
#
# Paragraph covering WorkshopRunner children: constant hoister.
#
#   Hecks::Chapters::Workshop::RunnerSupportParagraph.define(builder)
#
module Hecks
  module Chapters
    module Workshop
      module RunnerSupportParagraph
        def self.define(b)
          b.aggregate "ConstantHoister" do
            description "Manages hoisting and cleanup of constants on WorkshopRunner"
            command "HoistAggregate" do
              attribute :const_name, String
            end
          end
        end
      end
    end
  end
end
