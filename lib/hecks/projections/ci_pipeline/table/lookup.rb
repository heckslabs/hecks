# frozen_string_literal: true

module Hecks
  module Projections
    module CiPipeline
      class Table
        # How a row finds what it belongs to: the workflow, job and step its fields name, and the
        # refusal, naming what is declared, when there is none. Mixed into `Rows`, which holds the
        # joined workflows in `@workflows` and the problems in `@problems`.
        module Lookup
          private

          def workflow_of(row)
            found = @workflows.find { |workflow| workflow.name == row[:workflow] }
            return found if found

            problem(row, "names workflow #{row[:workflow].inspect}, which no Workflow row declares; " \
                         "its workflows are #{@workflows.map(&:name).join(", ")}")
            nil
          end

          def job_of(row)
            workflow = workflow_of(row) or return
            found = workflow.jobs.find { |job| job.name == row[:job] }
            return found if found

            problem(row, "names job #{row[:job].inspect}, which workflow #{row[:workflow]} does not declare; " \
                         "its jobs are #{workflow.jobs.map(&:name).join(", ")}")
            nil
          end

          def step_of(job, row)
            found = job.steps.find { |candidate| candidate.name == row[:step] }
            return found if found

            problem(row, "names step #{row[:step].inspect}, which job #{row[:job]} does not declare; " \
                         "its steps are #{job.steps.map(&:name).join(", ")}")
            nil
          end

          def check_pattern(row, pattern, field, reason)
            regexp = @vocabulary.fetch(:patterns).fetch(pattern)
            return if row[field].is_a?(String) && regexp.match?(row[field])

            problem(row, "has #{field} #{row[field].inspect}; #{reason}, matching #{regexp.source}")
          end

          def twice(row, declared)
            return unless declared

            problem(row, "is declared twice")
          end

          def problem(row, text) = @problems << "#{row.fetch(:label)} #{text}"
        end
      end
    end
  end
end
