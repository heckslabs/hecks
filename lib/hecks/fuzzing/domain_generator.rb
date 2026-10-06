require "fileutils"
require "json"
require_relative "form_census"
require_relative "domain_generator/rendering"
require_relative "domain_generator/pruning"
require_relative "domain_generator/builder"

module Hecks
  module Fuzzing
    # Builds a small, valid bluebook from a random seed, so the QA loop can
    # exercise construct combinations nobody has hand-authored yet.
    module DomainGenerator
      DOMAIN_NAME = "QaGenerated".freeze
      DIRECTORY   = "qa_generated".freeze

      # A name whose snake_case form collides with a Rust keyword (`Crate`
      # -> `crate`) fails to compile under `--rust`; `hecks project_rust`
      # guards only the domain name, not these.
      AGGREGATE_NAMES = %w[Ticket Desk Parcel Venue Kiosk Hangar].freeze
      ENTITY_NAMES    = %w[Line Stamp].freeze
      CLOSED_SETS     = [%w[low high], %w[red amber green], %w[draft final]].freeze
      ROLES           = %w[Clerk Manager].freeze

      REFERENCE_FORMS = %w[reference_attr revalued_reference].freeze
      CHAIN_FORMS     = %w[two_hop_given multi_hop_where].freeze

      extend Rendering
      extend Pruning

      module_function

      def generate(seed:, forms: nil)
        random = Random.new(seed)
        forms  = Array(forms || FORMS.sample(2, random: random)).map(&:to_s)
        unknown = forms - FORMS
        raise ArgumentError, "unknown form(s) #{unknown.join(", ")} — FormCensus::FORMS names #{FORMS.join(", ")}" if unknown.any?

        blueprint = Builder.new(random, forms).build
        prune(blueprint.merge("seed" => seed, "forms" => forms))
      end

      # `blueprint.json` is written beside the domain directory, never
      # inside it — a stray file under `bluebook/` would load as a chapter.
      def write(blueprint, root)
        domain = File.join(root, DIRECTORY)
        FileUtils.rm_rf(domain)
        FileUtils.mkdir_p(File.join(domain, "bluebook"))
        text = blueprint["source"] ? adopt(blueprint["source"]) : render(blueprint)
        File.write(File.join(domain, "bluebook", "#{DIRECTORY}.bluebook"), text)
        File.write(File.join(root, "blueprint.json"), JSON.pretty_generate(blueprint))
        domain
      end

      # Renamed to `QaGenerated` — the fixed name child processes expect.
      def adopt(source)
        source.sub(/Hecks\.bluebook\s*\(?\s*(["'])[^"']+\1/) { "Hecks.bluebook #{DOMAIN_NAME.inspect}" }
      end

      def snake(name) = name.gsub(/([a-z])([A-Z])/, '\1_\2').downcase

      # What this generator can build, not everything FormCensus knows about.
      # A form with no `Builder::FORM_STEPS` recipe is simply never
      # generated; kept in sync by spec/fuzzing/domain_generator_spec.rb.
      FORMS = Builder::FORM_STEPS.keys.freeze
    end
  end
end
