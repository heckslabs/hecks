require_relative "../vocabulary"

module Hecks
  module Runtime
    # Every DomainRefusal wording that is not already data — `given`/
    # `ensures`/a declared `invariant` already carry their own description,
    # read at dispatch time off the command or value object that declared
    # them. These are different in kind: LANGUAGE-LEVEL refusals, the same
    # wording for every domain, not authored per-bluebook.
    #
    # READ OFF THE GENERATED TABLE, not typed a second time. The rows are
    # Vocabulary::RefusalTemplate (language/bluebook/vocabulary.bluebook),
    # projected into lib/hecks/vocabulary.rb by bin/project_vocabulary and
    # into rust/src/kernel/vocab/refusal_template.rs by
    # bin/project_rust_vocabulary; both regenerations are diffed in CI, so
    # there is no hand copy left here to drift. Declared order is kept.
    module RefusalWording
      TEMPLATES = Hecks::Vocabulary.rows("RefusalTemplate")
                                   .to_h { |row| [[row["refusal"], row["site"]].freeze, row["template"]] }
                                   .freeze

      module_function

      # Plain text substitution, never expression syntax — a template is
      # read, not evaluated. `render` computes the placeholder VALUES via
      # whatever the call site already had (a joined list, a rendered
      # identity reading, …) and this only replaces the markers.
      def render(refusal, site, **values)
        template = TEMPLATES.fetch([refusal, site]) do
          raise KeyError, "no refusal template for #{refusal}/#{site} — declare it in " \
                          "Vocabulary::RefusalTemplate first"
        end
        values.reduce(template) { |text, (key, value)| text.gsub("{#{key}}", value.to_s) }
      end
    end
  end
end
