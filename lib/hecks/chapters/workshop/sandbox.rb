# Hecks::Chapters::Workshop::SandboxParagraph
#
# Paragraph covering Playground children: gem bootstrap and
# runtime resolver.
#
#   Hecks::Chapters::Workshop::SandboxParagraph.define(builder)
#
module Hecks
  module Chapters
    module Workshop
      module SandboxParagraph
        def self.define(b)
          b.aggregate "GemBootstrap" do
            description "Loads domain into a Runtime via InMemoryLoader eval"
            command "Compile"
          end

          b.aggregate "RuntimeResolver" do
            description "Resolves generated command and event classes at runtime"
            command "ResolveCommand" do
              attribute :name, String
            end
          end
        end
      end
    end
  end
end
