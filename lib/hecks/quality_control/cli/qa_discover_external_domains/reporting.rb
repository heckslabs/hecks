# frozen_string_literal: true

module Hecks
  module QualityControlCli
    class QaDiscoverExternalDomains
      # What `target.discover_external_domains` prints once the scan is done.
      module Reporting
        private

        def report(options, candidates, skipped, siblings)
          print_summary(options, skipped, siblings)
          puts
          return print_no_candidates(options) if candidates.empty?

          puts "#{candidates.size} candidate(s) — report only, nothing identified. Review each, then run " \
               "the command yourself to enroll it:"
          puts
          candidates.each { |candidate| print_candidate(candidate) }
        end

        def print_summary(options, skipped, siblings)
          puts "scanned #{siblings.size} sibling(s) under #{options[:projects_dir]} " \
               "(max depth #{options[:max_depth]}), #{siblings.size - skipped.size} depend on the hecks gem"
          return if skipped.empty?

          puts "no hecks dependency, skipped: #{skipped.map { |path| File.basename(path) }.join(", ")}"
        end

        def print_no_candidates(options)
          puts "no new candidates — every hecks-dependent sibling's bluebook-shaped domain is either " \
               "already a Target or none was found in the shape <name>/bluebook/<name>.bluebook within " \
               "--max-depth #{options[:max_depth]}."
        end

        def print_candidate(candidate)
          puts "  #{candidate[:reference]}"
          puts "    path: #{candidate[:path]}"
          puts "    enroll: hecks run qa/bluebook identify reference=#{candidate[:reference]} path=#{candidate[:path]}"
          puts
        end
      end
    end
  end
end
