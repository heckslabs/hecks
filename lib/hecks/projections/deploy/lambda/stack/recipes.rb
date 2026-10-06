require_relative "../../bastion_lines"

module Hecks
  module Projections
    module Deploy
      module Lambda
        class Stack
          # The Makefile recipes that reach the database through the temporary bastion: `mint-era`,
          # the translation targets and `rename-schema`. Included into `Stack`; each method is also
          # the value of the template marker of the same name.
          module Recipes
            include BastionLines

            # What a translation target runs over the bastion tunnel, and how.
            #
            # @!attribute [r] verb [String] the make target's name, as the messages print it
            # @!attribute [r] script [String] the command that runs against the tunnelled database
            # @!attribute [r] extra_args [String] arguments after the domain argument
            # @!attribute [r] cwd [String] the directory the script runs in
            # @!attribute [r] run_prefix [String] what launches the script
            # @!attribute [r] db_env_blind [Boolean] whether the script ignores DATABASE_URL, so the
            #   recipe refuses unless `ALLOW_LOCAL_DB=1`
            # @!attribute [r] domain_arg [String] the domain argument, passed when run from the root
            Translation = Struct.new(:verb, :script, :extra_args, :cwd, :run_prefix, :db_env_blind, :domain_arg,
                                     keyword_init: true)

            # `hecks ask` answers the scaffold as text, and refuses (exit 1) where the script
            # aborted.
            SCAFFOLD = Translation.new(verb: "scaffold-translation", script: "exe/hecks query era.scaffold_translation",
                                       extra_args: "", cwd: "$(ROOT)", run_prefix: "HECKS_ENVIRONMENT=memory ruby",
                                       db_env_blind: true, domain_arg: "domain=$(DOMAIN) ")
            # A refused audit is a refused query: `hecks ask` exits 1, so the target fails too.
            AUDIT = Translation.new(verb: "translation-audit", script: "exe/hecks query era.audit_translation",
                                    extra_args: "", cwd: "$(ROOT)", run_prefix: "HECKS_ENVIRONMENT=memory ruby",
                                    db_env_blind: true, domain_arg: "domain=$(DOMAIN) ")
            # An app-owned one-time migration script instead of a hecks tool:
            # `bin/migrate_console_settings` belongs to the domain's own application, not to hecks.
            # Harmless when the domain has none: `bundle exec ruby` on a missing file just fails
            # loudly.
            MIGRATE = Translation.new(verb: "migrate-console-settings", script: "bin/migrate_console_settings",
                                      extra_args: "", cwd: "$(DOMAIN)", run_prefix: "bundle exec ruby",
                                      db_env_blind: false, domain_arg: "$(DOMAIN) ")

            def mint_era_recipe
              render_recipe(shared ? "mint_era_shared" : "mint_era_own")
            end

            def scaffold_translation_recipe = translation_recipe(SCAFFOLD)
            def translation_audit_recipe = translation_recipe(AUDIT)
            def migrate_console_settings_recipe = translation_recipe(MIGRATE)

            # `OLD`/`NEW` are Make command-line variables, reusable across whichever domain owns
            # this stack's RDS instance. Idempotent by inspection (checks which schema exists
            # first), not by catching a Postgres error.
            def rename_schema_recipe
              render_recipe(shared ? "rename_schema_shared" : "rename_schema_own")
            end

            def pg_native_section
              pg_version ? TextTemplate.render_from("lambda/pg_native.tmpl", self) : ""
            end

            def sync_oauth_section
              google_oauth_present ? TextTemplate.render_from("lambda/sync_oauth.tmpl", self) : ""
            end

            def oauth_note
              google_oauth_present ? TextTemplate.render_from("lambda/oauth_note.tmpl", self) : ""
            end

            def shared_note
              shared ? TextTemplate.render_from("lambda/shared_note.tmpl", self) : ""
            end

            private

            def render_recipe(name)
              TextTemplate.render_from("lambda/#{name}.tmpl", self).rstrip
            end

            # Shares mint_era_recipe's bastion/tunnel/retry/teardown chain but runs `job.script`
            # over it.
            def translation_recipe(job)
              return TextTemplate.render("lambda/translation_own.tmpl", **translation_values(job)).rstrip unless shared

              owner = owner_domain_name
              TextTemplate.render("lambda/translation_shared.tmpl", verb: job.verb, owner_domain_name: owner).rstrip
            end

            def translation_values(job)
              {
                verb: job.verb, script: job.script, extra_args: job.extra_args, cwd: job.cwd,
                run_prefix: job.run_prefix, domain_arg_part: job.cwd == "$(ROOT)" ? job.domain_arg : "",
                db_env_guard: job.db_env_blind ? env_blind_guard(job) : "", db_name: db_name,
                hecks_schema: hecks_schema, eval_lines: eval_lines, parameter_overrides: parameter_overrides
              }
            end

            # Neither script actually reads DATABASE_URL/HECKS_SCHEMA (both call
            # `registry.binding_settings`, a lookup against the literal `database "..."` in the
            # domain's `.world`): without a guard, the recipe would open a real tunnel to production
            # and silently scaffold/audit the local dev database instead, reporting success.
            def env_blind_guard(job)
              TextTemplate.render("lambda/env_blind_guard.tmpl", verb: job.verb, script: job.script, domain: domain,
                                                                 stack_name: stack_name).rstrip
            end
          end
        end
      end
    end
  end
end
