# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require_relative "../../tools"

module Hecks
  module Tools
    module DeployRecipeLint
      # Generated fixture domains for the deploy generator, so the lint has real Makefiles to read.
      module Fixtures
        # The fixture's bluebook, where `__NAME__` stands for the domain's name.
        FIXTURE_BLUEBOOK = <<~BLUEBOOK
          Hecks.bluebook "__NAME__" do
            aggregate "Thing" do
              identified_by :name
              attribute :name, ThingName
              value_object "ThingName" do
                attribute :value, String
                invariant("named") { !value.to_s.empty? }
              end
              command "Create" do
                attribute :name, ThingName
                sets :name
                emits "ThingCreated"
              end
            end
          end
        BLUEBOOK

        # The fixture's world, where `__NAME__` stands for the domain's name and `__BODY__` for its
        # deployment settings.
        FIXTURE_WORLD = <<~WORLD
          Hecks.world "__NAME__" do
            deployed_to("AwsLambda") do
              __BODY__
            end
          end
        WORLD

        # Writes a minimal bluebook/world pair under `dir` for the deploy generator to generate
        # from.
        def write_fixture(dir, basename, world_body, env_local: nil)
          domain_dir = File.join(dir, basename)
          bluebook_dir = File.join(domain_dir, "bluebook")
          FileUtils.mkdir_p(bluebook_dir)
          name = basename.split("_").map(&:capitalize).join

          File.write(File.join(bluebook_dir, "#{basename}.bluebook"), FIXTURE_BLUEBOOK.gsub("__NAME__") { name })
          File.write(File.join(bluebook_dir, "#{basename}.world"), world_text(name, world_body))
          File.write(File.join(domain_dir, ".env.local"), env_local) if env_local

          domain_dir
        end

        # Runs the deploy generator on a tmpdir fixture; output always lands in
        # <root>/deploy/<basename>.
        def generate!(root, basename, world_body, env_local: nil)
          Dir.mktmpdir do |dir|
            domain_dir = write_fixture(dir, basename, world_body, env_local: env_local)
            outcome = Hecks::Adapters::ConsoleCapture.capture { DeployRecipe.main([domain_dir], root: root) }
            outcome.ok? or raise "hecks deploy project failed generating the #{basename} fixture: #{outcome.output}"
          end
          File.join(root, "deploy", basename)
        end

        # Own-RDS, Shared-mode and OAuth domains: together they hit every branch of the recipe
        # builders.
        def fixtures
          {
            "own fixture"    => ["region \"us-east-1\"", nil],
            "shared fixture" => ["region \"us-east-1\"\n    database \"Shared\"\n    owner \"SomeOwner\"", nil],
            "oauth fixture"  => [
              "region \"us-east-1\"\n    web \"Rust\"",
              "GOOGLE_CLIENT_ID=test-client-id.apps.googleusercontent.com\nGOOGLE_CLIENT_SECRET=test-secret\n"
            ]
          }
        end

        private

        def world_text(name, world_body)
          FIXTURE_WORLD.gsub("__NAME__") { name }.gsub("__BODY__") { world_body }
        end
      end
    end
  end
end
