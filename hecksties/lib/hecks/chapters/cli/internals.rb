# = Hecks::Chapters::Cli::CliInternals
#
# Self-describing sub-chapter for miscellaneous CLI internals: version
# log formatting, architecture tour steps, and Sinatra app generation.
#
#   Hecks::Chapters::Cli::CliInternals.define(builder)
#
module Hecks
  module Chapters
    module Cli
      # Hecks::Chapters::Cli::CliInternals
      #
      # Bluebook sub-chapter for miscellaneous CLI internals: version log, architecture tour, and app generation.
      #
      module CliInternals
        def self.define(b)
          b.aggregate "VersionLogFormatter", "Formats version history with change summaries between snapshots" do
            command("Format") { attribute :entries, String }
          end

          b.aggregate "Steps", "Step definitions for the guided architecture tour" do
            command("BuildSteps") { attribute :domain_name, String }
          end

          b.aggregate "SinatraAppGenerator", "Generates Sinatra app scaffold from domain IR" do
            command("Generate") { attribute :domain_path, String }
          end
        end
      end
    end
  end
end
