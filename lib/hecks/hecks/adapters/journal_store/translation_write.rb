# frozen_string_literal: true

require "fileutils"
require_relative "held_domain"
require_relative "edge_audit"
require_relative "translation_write/shape_edge"

module Hecks
  module Adapters
    class JournalStore
      # The `write_translation` change: composes the chain of edges from the latest held era to the
      # current shape into one edge, writes it, deletes the intermediate edges only the chain used,
      # and audits what was written. A refused audit puts the translations directory back as it was.
      #
      # Planning is a read; only `apply_write_translation` writes, and only to the domain's own
      # `translations/` directory.
      module TranslationWrite
        # What a write would do: the file it writes and its text, the stale files it deletes, and
        # the shape labels the chain passes through. `message` alone answers when nothing is to be
        # done.
        Plan = Struct.new(:message, :path, :text, :removals, :labels, keyword_init: true)

        include ShapeEdge

        private

        def examine_write_translation(held)
          domain = HeldDomain.open(plain(held[:domain]))
          return {} unless domain.capable?

          domain.reading do |lineage|
            translation_plan(domain, lineage)
            { capable: true, held: domain.held_eras(lineage).size }
          end
        end

        def apply_write_translation(held)
          path = plain(held[:domain])
          domain = HeldDomain.open(path)
          plan = domain.reading { |lineage| translation_plan(domain, lineage) }
          return plan.message if plan.message

          write_and_audit(path, plan)
          written_report(plan)
        end

        # Writes the plan, then audits what it wrote; a refusal or a failure restores the files.
        def write_and_audit(path, plan)
          originals = write_translation!(plan)
          begin
            audit_written_translation!(path)
          rescue StandardError
            restore_translations!(originals)
            raise
          end
        end

        # The plan a write would carry out, or the sentence that says none is needed.
        #
        # @return [Plan] see `Plan`
        # @raise [Runtime::WiringError] when the chain cannot be composed into one edge
        def translation_plan(domain, lineage)
          eras = domain.held_eras(lineage)
          return Plan.new(message: "#{domain.domain_name} holds no era yet — nothing to write.") if eras.empty?

          latest = domain.named(eras.last)
          return Plan.new(message: "#{domain.domain_name} matches era #{latest[:ordinal]} — nothing to write.") if
            held_shape(latest) == domain.shape

          composed_plan(domain, latest)
        end

        def held_shape(era) = PostgresEra::LineageManager.held_shape(era)

        def composed_plan(domain, latest)
          current = Runtime::StorageShape.mint_hash(domain.bluebook)[0, Runtime::StorageShape::LABEL_LENGTH]
          chain = Translation::Compose.chain(domain.translations, domain: domain.domain_name,
                                                                  from: latest[:label], to: current)
          return already_leads(latest[:label], current) if chain.size == 1
          return shape_edge_plan(domain, latest, current) if chain.empty?

          edge_plan(domain, latest[:label], current, chain)
        end

        # Writes the composed edge and deletes the stale ones; returns what each file held before.
        #
        # @return [Hash{String => String, nil}] each touched path with its earlier text, nil if
        #   absent
        def write_translation!(plan)
          originals = [plan.path, *plan.removals].to_h { |path| [path, read_if_present(path)] }
          File.write(plan.path, plan.text)
          plan.removals.each { |path| FileUtils.rm_f(path) }
          originals
        end

        def read_if_present(path) = File.exist?(path) ? File.read(path) : nil

        # Puts each touched file back as `write_translation!` found it.
        def restore_translations!(originals)
          originals.each do |path, text|
            text ? File.write(path, text) : FileUtils.rm_f(path)
          end
        end

        # Audits the edge that was just written, as the boot does.
        #
        # @raise [Runtime::WiringError] when the audit refuses the composed edge
        def audit_written_translation!(path)
          domain = HeldDomain.open(path)
          finding = domain.reading { |lineage| EdgeAudit.call(domain, lineage, domain.held_eras(lineage)) }
          return if finding.nil? || finding.ok

          raise Runtime::WiringError,
                "cannot write the translation of #{domain.domain_name}: the audit refused the composed " \
                "edge —\n  #{finding.refusals.join("\n  ")}"
        end

        def written_report(plan)
          removed = plan.removals.map { |path| "  removed #{File.basename(path)}" }
          ["wrote #{plan.path}", *removed, "the audit passed: #{plan.labels.join(" -> ")}"].join("\n")
        end
      end
    end
  end
end
