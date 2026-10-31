# frozen_string_literal: true

require_relative "held_domain"
require_relative "edge_audit"
require_relative "reconcile_report"

module Hecks
  module Adapters
    class JournalStore
      # The `reconcile` change: plans every bluebook of a project against the eras its store holds,
      # and when every plan is admitted writes the composed edges, deletes the edges they supersede,
      # and audits each written edge. Reading is the dry run; only `apply_reconcile` writes, and a
      # refused plan in any domain writes nothing.
      module Reconciliation
        # The project directory a reconciliation reads when none is named: the hecks checkout's own
        # domain directory, whose `translations/` holds the edges of every domain it loads.
        DEFAULT_PROJECT = File.expand_path("../..", __dir__)

        # One bluebook's plan; `plan` is nil when its store keeps no eras.
        Row = Struct.new(:name, :plan, keyword_init: true) do
          def refusal = plan&.refusal

          def status = plan&.status

          def edge = plan&.edge
        end

        # The dry run: one report of every domain's plan, written nowhere.
        #
        # @param domain [Hash, String, nil] the project directory; the checkout's own when absent
        # @return [Hash] `text:` the report, one block per domain
        # @raise [Runtime::NotFound] if the project cannot be loaded
        def reconcile_plan(domain: nil)
          answering { project_rows(project_path(domain)).map { |row| ReconcileReport.render_row(row) }.join("\n\n") }
        end

        private

        # Examines nothing: the plans decide what is admitted, and `apply_reconcile` refuses a store
        # that keeps no eras.
        def examine_reconcile(_held) = { capable: true }

        def apply_reconcile(held)
          path = project_path(held[:domain])
          rows = project_rows(path)
          refusals = rows.filter_map(&:refusal)
          unless refusals.empty?
            raise Runtime::WiringError, "nothing was written; the reconciliation refused:\n  #{refusals.join("\n  ")}"
          end

          write_reconciled(path, rows.select { |row| row.status == :write })
        end

        def write_reconciled(path, writes)
          return "every domain already leads to its current shape — nothing to reconcile." if writes.empty?

          originals = writes.reduce({}) { |found, row| found.merge(Translation::ReconcileFiles.write!(row.plan)) }
          begin
            writes.each { |row| audit_written!(path, row) }
          rescue StandardError
            Translation::ReconcileFiles.restore!(originals)
            raise
          end
          ReconcileReport.written(writes)
        end

        # Audits the composed edge a row wrote; a row that only deleted edges has nothing to audit.
        #
        # @raise [Runtime::WiringError] when the audit refuses the composed edge
        def audit_written!(path, row)
          return unless row.edge

          project = HeldDomain.open(path)
          domain = HeldDomain.new(project.registry, project.directory, row.name)
          finding = domain.reading { |lineage| EdgeAudit.call(domain, lineage, domain.held_eras(lineage)) }
          return if finding.nil? || finding.ok

          raise Runtime::WiringError,
                "cannot reconcile #{row.name}: the audit refused the composed edge —\n  " \
                "#{finding.refusals.join("\n  ")}"
        end

        def project_path(domain) = plain(domain) || DEFAULT_PROJECT

        # @return [Array<Row>] one row per bluebook the project loads, in the registry's order
        def project_rows(path)
          project = HeldDomain.open(path)
          project.bluebook_names.map { |name| bluebook_row(project, name) }
        end

        def bluebook_row(project, name)
          domain = HeldDomain.new(project.registry, project.directory, name)
          return Row.new(name: name) unless domain.capable?

          domain.reading { |lineage| Row.new(name: name, plan: domain_plan(domain, lineage, project)) }
        end

        def domain_plan(domain, lineage, project)
          Translation::Reconcile.plan(
            Translation::Reconcile::Scope.new(
              domain: domain.domain_name, held: held_labels(domain, lineage), current: current_label(domain),
              edges: domain.translations.select { |edge| edge.domain == domain.domain_name },
              files: Translation::EdgeFiles.scan(project.directory), directory: project.directory
            )
          )
        end

        def held_labels(domain, lineage)
          domain.held_eras(lineage).map do |era|
            named = domain.named(era)
            { ordinal: named[:ordinal], label: named[:label] }
          end
        end

        def current_label(domain)
          Runtime::StorageShape.mint_hash(domain.bluebook)[0, Runtime::StorageShape::LABEL_LENGTH]
        end
      end
    end
  end
end
