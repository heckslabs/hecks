# Hecks::Chapters::Targets::Ruby
#
# Paragraph for the Ruby static code generation target. Covers
# generators that produce a standalone Ruby gem with zero runtime
# dependency on hecks.
#
#   Hecks::Chapters::Targets::Ruby.define(builder)
#
module Hecks
  module Chapters
    module Targets
      module Ruby
        def self.define(b)
          b.aggregate "GemGenerator", "Orchestrates full standalone Ruby gem: runtime, domain, server, UI" do
            command("Generate") { attribute :domain_name, String; attribute :output_dir, String }
          end

          b.aggregate "EntryPointGenerator", "Generates lib/<gem>.rb autoloads and boot.rb wiring" do
            command("Generate") { attribute :domain_name, String }
          end

          b.aggregate "RuntimeWriter", "Copies runtime templates into generated gem, replacing module placeholder" do
            command("Generate") { attribute :domain_module, String }
          end

          b.aggregate "RubyServerGenerator", "Generates domain-specific HTTP server with aggregate routes" do
            command("Generate") { attribute :domain_name, String }
          end

          b.aggregate "RubyUIGenerator", "Generates route handlers that prepare data and render ERB templates" do
            command("Generate") { attribute :domain_name, String }
          end
        end
      end
    end
  end
end
