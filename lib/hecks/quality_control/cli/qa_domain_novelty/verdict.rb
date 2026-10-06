# frozen_string_literal: true

module Hecks
  module QualityControlCli
    class QaDomainNovelty
      # The comparison `target.judge_novelty` ends in: the candidate's form pairs against the pairs
      # the existing targets already meet, printed, and the exit status that follows.
      module Verdict
        # Why an empty result is a question about the census, not a verdict on the domain.
        READ_AS_QUESTION = "READ THAT AS A QUESTION ABOUT THE CENSUS, NOT A VERDICT ON THE DOMAIN. This gate " \
                           "measures ONE AGGREGATE's own declared forms, so a domain whose point is a " \
                           "chapter-level construct — a policy, an `across` target, a process manager, a " \
                           "read model's own group_by/median, an outbox, a dry run — is invisible to it by " \
                           "construction, not by omission. `corrects` and `role_gated` were exactly that: " \
                           "declared all over the corpus, unnamed here, so this line told three stress " \
                           "domains built around retroactive correction that they were redundant (their own " \
                           "NOTES.md each say so). If that is your domain's case, say which construct it " \
                           "exists for in its NOTES.md and keep it."

        private

        def judge(candidate, present, existing_source)
          census = Hecks::Fuzzing::FormCensus.census(normalize(candidate))
          mine = Hecks::Fuzzing::FormCensus.covered_pairs(census)
          theirs = pairs_met_by(present)
          puts candidate_header(candidate, census, mine), against_header(present, existing_source, theirs)
          puts
          new_pairs = mine.reject { |pair, _| theirs.key?(pair) }
          return nothing_new(candidate) if new_pairs.empty?

          print_new_pairs(candidate, new_pairs)
          EXIT_NOVEL
        end

        def pairs_met_by(present)
          present.each_with_object(Hash.new { |h, k| h[k] = [] }) do |path, covered|
            Hecks::Fuzzing::FormCensus.covered_pairs(Hecks::Fuzzing::FormCensus.census(path)).each do |pair, names|
              covered[pair].concat(names.map { |name| "#{name} (#{path.delete_prefix("#{@root}/")})" })
            end
          end
        end

        def candidate_header(candidate, census, pairs)
          "candidate: #{candidate} — #{census.size} aggregate(s), #{pairs.size} form pair(s) met"
        end

        def against_header(present, existing_source, pairs)
          "against:   #{present.size} domain(s) from #{existing_source}, " \
            "#{pairs.size} form pair(s) met between them"
        end

        def print_new_pairs(candidate, new_pairs)
          width = new_pairs.keys.map(&:size).max
          puts "new pair(s) — met on one aggregate here, on none of the existing targets:"
          new_pairs.sort.each { |pair, names| puts "  #{pair.ljust(width)}  #{names.uniq.join(", ")}" }
          puts
          puts "#{new_pairs.size} new pair(s) — #{candidate} earns its place."
        end

        def nothing_new(candidate)
          puts no_new_pair_line(candidate)
          puts
          puts READ_AS_QUESTION
          EXIT_NOTHING
        end

        def no_new_pair_line(candidate)
          "no new pair — every pair of forms #{candidate} puts together on one aggregate is already met " \
            "by an existing target. Either the domain is not new, or the form it exists for is not yet " \
            "named in Hecks::Fuzzing::FormCensus::FORMS (lib/hecks/fuzzing/form_census.rb) — name it " \
            "there first, citing the gap it is one step from, and run this again."
        end
      end
    end
  end
end
