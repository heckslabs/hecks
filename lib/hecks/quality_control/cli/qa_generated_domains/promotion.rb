# frozen_string_literal: true

module Hecks
  module QualityControlCli
    class QaGeneratedDomains
      # `--promote`: turns a finding's minimal domain into a stress domain under
      # `qa/stress_domains`, with notes that carry the blueprint and the finding.
      module Promotion
        private

        def camelize(name) = name.split("_").map(&:capitalize).join

        def promote
          name = promotion_name
          source = promotion_source
          target = File.join(@root, "qa/stress_domains", name)
          abort "#{target} already exists — pick another --name" if File.exist?(target)

          write_promotion(name, source, target)
          print_promotion(name)
          EXIT_OK
        end

        def promotion_name
          name = @options[:name] || abort("#{USAGE}\n--promote needs --name")
          return name if name.match?(/\A[a-z][a-z0-9_]*\z/)

          abort "--name must be a lowercase identifier (it becomes a Rust module and Cargo feature)"
        end

        def promotion_source
          source = File.join(@options[:promote], Generator::DIRECTORY, "bluebook", "#{Generator::DIRECTORY}.bluebook")
          abort "no generated domain at #{source}" unless File.exist?(source)

          source
        end

        def write_promotion(name, source, target)
          FileUtils.mkdir_p(File.join(target, "bluebook"))
          File.write(File.join(target, "bluebook", "#{name}.bluebook"),
                     File.read(source).gsub(Generator::DOMAIN_NAME, camelize(name)))
          File.write(File.join(target, "NOTES.md"), notes_for(name))
        end

        def print_promotion(name)
          puts "promoted: qa/stress_domains/#{name}"
          puts "next:"
          puts "  hecks quality_control judge_novelty qa/stress_domains/#{name}"
          puts "  hecks project_rust qa/stress_domains/#{name}  # when the finding needs the Rust comparison"
          # `hecks quality_control target.seed` derives targets from
          # `Hecks::Corpus.rotation_targets`, so a hand-typed `target.identify` line is not printed:
          # nobody ran it and the domain never
          # entered the rotation.
          puts "  hecks quality_control target.seed   # idempotent; picks this domain up from the corpus"
        end

        def notes_for(name)
          recorded = recorded_blueprint
          notes_header(name, recorded) + notes_sections(recorded)
        end

        def notes_header(name, recorded)
          hypothesis = recorded&.dig("hypothesis")
          <<~NOTES
            # #{name}

            Promoted from a `hecks quality_control check_generated_domains` finding — #{origin_phrase(recorded)}, not
            hand-written. The bluebook is the minimal form of the domain that
            surprised; `QaGenerated` was renamed to `#{camelize(name)}` and nothing
            else changed.
            #{"\n## Hypothesis\n\n#{hypothesis.strip}\n" if hypothesis}
          NOTES
        end

        def notes_sections(recorded)
          <<~NOTES
            ## Blueprint

            ```json
            #{recorded ? JSON.pretty_generate(recorded.except("source", "hypothesis")) : "(not recorded)"}
            ```

            ## Finding

            ```json
            #{recorded_finding}
            ```
          NOTES
        end

        def recorded_blueprint
          blueprint = File.join(@options[:promote], "blueprint.json")
          File.exist?(blueprint) ? JSON.parse(File.read(blueprint)) : nil
        end

        def recorded_finding
          finding = File.join(@options[:promote], "finding.json")
          File.exist?(finding) ? File.read(finding).strip : "(not recorded)"
        end

        def origin_phrase(recorded)
          recorded&.key?("source") ? "written by `hecks quality_control mine_combinations`' agent" : "generated"
        end
      end
    end
  end
end
