# frozen_string_literal: true

module Hecks
  module QualityControlCli
    class QaGeneratedDomains
      # Where the blueprints of a run come from: a saved one, bluebooks written elsewhere, or the
      # generator.
      module Blueprints
        private

        def blueprints(start)
          return saved_blueprint(start) if @options[:blueprint]
          return source_blueprints(start) if @options[:sources].any?

          generated_blueprints(start)
        end

        def saved_blueprint(start)
          saved = JSON.parse(File.read(@options[:blueprint]))
          { saved.fetch("seed", start) => saved }
        end

        def source_blueprints(start)
          @options[:sources].each_with_index.to_h { |file, index| [start + index, source_blueprint(file, start + index)] }
        end

        def generated_blueprints(start)
          (start...(start + @options[:domains])).to_h do |seed|
            [seed, Generator.generate(seed: seed, forms: @options[:forms])]
          end
        end

        def source_blueprint(file, seed)
          abort "no bluebook at #{file}" unless File.file?(file)

          hypothesis = File.join(File.dirname(file), "HYPOTHESIS.md")
          { "seed" => seed, "forms" => ["source:#{File.basename(File.dirname(file))}"],
            "origin" => File.expand_path(file), "source" => File.read(file),
            "hypothesis" => (File.read(hypothesis) if File.exist?(hypothesis)),
            "aggregates" => [], "policies" => [] }.compact
        end
      end
    end
  end
end
