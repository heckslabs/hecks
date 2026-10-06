# frozen_string_literal: true

module Hecks
  module Adapters
    class DeployToolchain
      # The generated scripts an ask runs, by name, and what each status they end with means, for
      # the reason a refusal gives.
      module Statuses
        # The `Hecks::Tools` tool an ask runs, by ask.
        SCRIPTS = { generate: "project_deploy", lint: "lint_deploy_recipes", manifest: "project_oidc" }.freeze

        # `hecks deploy recipe.project`'s flag for each `Recipe` field it takes.
        GENERATE_FLAGS = { "--tenant" => :tenant, "--schema" => :schema, "--out" => :out,
                           "--environment" => :environment }.freeze

        # The file name the AwsBox projection gives the post-deploy smoke.
        SMOKE_SCRIPT = "smoke-after-deploy.sh"

        # What each status of `smoke-after-deploy.sh` means, for the reason a refusal gives.
        SMOKE_STATUS = { 20 => "the roll did not settle", 21 => "gh missing or no repository, smoke not run",
                         22 => "the smoke failed", 23 => "the smoke's result is unknown" }.freeze

        # The file names the AwsBox projection gives the two rolls.
        SERVICE_SCRIPT = "deploy-service.sh"
        BOX_SCRIPT = "deploy-box.sh"

        # What each status of `deploy-box.sh` means, for the reason a refusal gives.
        BOX_STATUS = { 40 => "the box stack has no instance", 41 => "the roll did not succeed on the box",
                       42 => "the box is not healthy after the roll" }.freeze

        # What each status of `deploy-service.sh` means; it ends with the box roll's own statuses.
        SERVICE_STATUS = { 2 => "unknown service", 30 => "the existing tag is not in ECR",
                           31 => "the fresh tag is already in ECR", 32 => "the box's Compose file is unreadable",
                           33 => "the box stack has no instance", 34 => "the stack has no parameter for the container",
                           35 => "the stack update failed or did not settle",
                           36 => "a parameter other than the container's changed",
                           37 => "the task definition lacks the pushed image",
                           38 => "the task definition has no such container" }.merge(BOX_STATUS).freeze

        # The file names the AwsBox projection gives the data copy and its comparison.
        RESTORE_SCRIPT = "restore-to-rds.sh"
        VERIFY_SCRIPT = "verify-copy.sh"

        # The status `verify-copy.sh` ends with when the databases differ: an answer, not a refusal.
        DRIFT_STATUS = 50

        # What each status of `restore-to-rds.sh` means, for the reason a refusal gives.
        RESTORE_STATUS = { 60           => "a Postgres client older than 16",
                           61           => "the target already has a schema; force=true replaces it",
                           62           => "unexpected errors restoring a schema",
                           DRIFT_STATUS => "the copy does not match the source" }.freeze

        # The file name of the bluebook report script and of the preview script; a companion roll
        # runs `deploy-<companion>.sh`.
        DIFF_SCRIPT = "bluebooks-diff.sh"
        PREVIEW_SCRIPT = "preview.sh"

        # What `preview.sh` ends with: every refusal and failure is 1, a bad verb 2.
        PREVIEW_STATUS = { 1 => "the preview script refused or failed", 2 => "usage" }.freeze

        # What a roll script ends with: every refusal and failed check is 1.
        COMPANION_STATUS = { 1 => "the roll was refused, did not succeed, or the companion is not healthy" }.freeze

        # The outcome each `preview.sh` verb records; the writes among them need `confirm`.
        PREVIEW_OUTCOMES = { "name" => "named", "url" => "located", "list" => "listed", "deploy" => "deployed",
                             "destroy" => "destroyed", "login" => "signed_in" }.freeze
        PREVIEW_WRITES = %w[deploy destroy login].freeze

        # What `bluebooks-diff.sh` prints when it has nothing to compare.
        DIFF_UNAVAILABLE = /^==> bluebooks: (could not read|the local domain image has no|the running domain image .* predates)/
      end
    end
  end
end
