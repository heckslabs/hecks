# Hecks::Chapters::Hecksagon::MongoAdapterParagraph
#
# Paragraph listing the MongoAdapterGenerator child aggregate:
# SerializationLines. Used by load_aggregates to derive
# the require path from the aggregate name.
#
#   Hecks::Chapters.load_aggregates(
#     Hecks::Chapters::Hecksagon::MongoAdapterParagraph,
#     base_dir: File.expand_path("mongo_adapter_generator", __dir__)
#   )
#
module Hecks
  module Chapters
    module Hecksagon
      module MongoAdapterParagraph
        def self.define(b)
          b.aggregate "SerializationLines" do
            description "Mixin for MongoAdapterGenerator that builds serialize/deserialize method source"
            command "SerializeLines"
            command "DeserializeLines"
          end
        end
      end
    end
  end
end
