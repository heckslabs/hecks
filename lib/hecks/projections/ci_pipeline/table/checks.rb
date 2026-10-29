# frozen_string_literal: true

require_relative "tree"

module Hecks
  module Projections
    module CiPipeline
      class Table
        # What no single row can show: a workflow nothing starts, secrets no caller can pass, a
        # shard count that is not one a matrix can have, jobs that wait on one another in a circle,
        # and a command that names a shard total its job does not have.
        class Checks
          # The text a step's command writes where its job's shard total belongs.
          SHARD_TOKEN = "%{shard_total}" # rubocop:disable Style/FormatStringToken -- row text, not a format string

          # One scope of a job's `permissions:` line: a scope, a colon and what is allowed.
          PERMISSION = /\A[a-z-]+: (read|write|none)\z/

          # A command that begins with whitespace, which a literal block cannot carry.
          LEADING_SPACE = /\A\s/

          # @param workflows [Array<Tree::Workflow>] the joined workflows
          # @param vocabulary [Hash{Symbol => Object}] the closed sets and patterns
          # @param problems [Array<String>] collects each problem found, one line each
          def initialize(workflows, vocabulary, problems)
            @workflows = workflows
            @vocabulary = vocabulary
            @problems = problems
          end

          # @return [void]
          def call
            @workflows.each do |workflow|
              check_workflow(workflow)
              workflow.jobs.each { |job| check_job(job) }
              check_cycles(workflow)
            end
          end

          private

          def check_workflow(workflow)
            events = @vocabulary.fetch(:trigger)
            problem(workflow, "has no Trigger row; an event is one of #{events.join(", ")}") if workflow.triggers.empty?
            if workflow.secrets.any? && !workflow.triggers.include?("workflow_call")
              problem(workflow, "has Secret rows but no workflow_call Trigger; only a called workflow takes secrets")
            end
            return unless workflow.cancel_in_progress && workflow.concurrency_group.empty?

            problem(workflow, "cancels in progress without a concurrency_group to cancel within")
          end

          def check_job(job)
            check_time_limit(job)
            check_shard_total(job)
            check_shard_axis(job)
            check_shard_token(job)
            check_permissions(job)
            job.steps.select { |step| step.run.match?(LEADING_SPACE) }.each do |step|
              problem(step, "starts its command with whitespace, which a block scalar cannot carry")
            end
          end

          def check_time_limit(job)
            return if job.timeout_minutes.to_i.positive?

            problem(job, "has timeout_minutes #{job.timeout_minutes.inspect}; a job has a positive time limit")
          end

          def check_shard_total(job)
            return unless job.shard_total < 1

            problem(job, "has shard_total #{job.shard_total}; a sharded job has at least one shard")
          end

          def check_shard_axis(job)
            if job.shard_total > 1 && job.shard_axis.empty?
              problem(job, "has shard_total #{job.shard_total} and no shard_axis; the matrix needs a name")
            elsif job.shard_total <= 1 && !job.shard_axis.empty?
              problem(job, "has shard_axis #{job.shard_axis.inspect} but shard_total #{job.shard_total}; " \
                           "a job with one shard has no matrix")
            end
          end

          def check_shard_token(job)
            return if job.shard_total > 1

            job.steps.select { |step| step.run.include?(SHARD_TOKEN) }.each do |step|
              problem(step, "writes #{SHARD_TOKEN} but its job has no shards")
            end
          end

          def check_permissions(job)
            scopes = job.permissions.split(", ")
            scopes.grep_v(PERMISSION).each do |scope|
              problem(job, "has permissions scope #{scope.inspect}; a scope is `<name>: read`, `write` or `none`, " \
                           "separated by a comma and a space")
            end
          end

          # Each cycle among a workflow's jobs, named once from the first job in it.
          def check_cycles(workflow)
            needs = needs_among(workflow)
            reported = []
            needs.each_key do |name|
              cycle = cycle_from(name, needs) or next
              next if reported.include?(cycle.sort)

              reported << cycle.sort
              problem(workflow, "has jobs that need each other in a circle: #{[*cycle, cycle.first].join(" -> ")}")
            end
          end

          # @return [Hash{String => Array<String>}] each job's name to the declared jobs it needs
          def needs_among(workflow)
            names = workflow.jobs.map(&:name)
            workflow.jobs.to_h { |job| [job.name, job.needs & names] }
          end

          # @return [Array<String>, nil] the jobs of a cycle that begins and ends at `start`
          def cycle_from(start, needs, path = [start])
            needs.fetch(path.last).each do |next_job|
              return path if next_job == start
              next if path.include?(next_job)

              found = cycle_from(start, needs, [*path, next_job])
              return found if found
            end
            nil
          end

          def problem(row, text) = @problems << "#{row.label} #{text}"
        end
      end
    end
  end
end
