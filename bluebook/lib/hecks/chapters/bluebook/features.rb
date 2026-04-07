# Hecks::Chapters::Bluebook::FeaturesParagraph
#
# Paragraph covering cross-cutting feature classes: leaky slice
# detection for cross-boundary dependency analysis and domain
# connection configuration.
#
#   Hecks::Chapters::Bluebook::FeaturesParagraph.define(builder)
#
module Hecks
  module Chapters
    module Bluebook
      module FeaturesParagraph
        def self.define(b)
          b.aggregate "LeakySliceDetection", "Detects cross-slice dependencies that violate bounded context boundaries" do
            command("DetectLeaks") { attribute :domain_id, String }
          end

          b.aggregate "ConnectionConfig", "Configures connections between domain contexts" do
            command("ConfigureConnection") { attribute :from_domain, String; attribute :to_domain, String }
          end
        end
      end
    end
  end
end
