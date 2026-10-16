module Hecks
  module Projections
    module Deploy
      module Box
        module Settings
          # The patterns a world's value must match, and the defaults and refusal messages of the
          # box settings. Included into `Settings`, so each constant reads as `Settings::NAME`.
          module Patterns
            NAME        = /\A[a-z][a-z0-9-]{0,40}\z/
            REPOSITORY  = %r{\A[a-z0-9][a-z0-9._/-]{1,100}\z}
            URL_PATH    = %r{\A/[A-Za-z0-9._~!$&'()*+,;=:@%/-]*\z}
            SECRET_NAME = %r{\A[A-Za-z0-9/_+=.@-]{1,256}\*?\z}
            ENV_KEY     = /\A[A-Za-z_][A-Za-z0-9_]*\z/
            ENV_VALUE   = /\A[^\x00-\x1f\x7f]*\z/
            HEADER      = /\A[A-Za-z][A-Za-z0-9-]{0,63}\z/
            DB_NAME     = /\A[a-zA-Z][a-zA-Z0-9]{0,62}\z/
            ENGINE      = /\A\d{2}(\.\d{1,2})?\z/
            PREFIX      = /\A[a-z][a-z0-9-]{0,20}\z/
            IMAGE       = %r{\A[a-z0-9][a-z0-9._/:@-]{1,200}\z}
            TASKDEF     = /\A[a-zA-Z0-9_-]{1,255}\z/
            SCHEMA      = /\A[a-z][a-z0-9_]{0,62}\z/
            MIGRATION_SHAPE = "migration: a hash needs `schemas`, a list of the schema names to copy".freeze
            S3_BUCKET   = /\A[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]\z/
            S3_SHAPE    = "s3_access: a list of `{ bucket: \"name\", write: true }` hashes (write is optional)".freeze
            FROM_TASKDEF = %i[env secrets repository].freeze
            LOG_DESTINATIONS = %w[cloudwatch local].freeze
            DEFAULT_LOG_RETENTION_DAYS = 30
            # The retention periods CloudWatch Logs accepts, in days, without "never expire".
            LOG_RETENTION_DAYS = [1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557,
                                  2922, 3288, 3653].freeze
            LOGS_SHAPE = "logs: \"cloudwatch\" ships every container's log to CloudWatch Logs; " \
                         "\"local\" keeps Docker's rotating json-file logs on the box".freeze

            # The settings that size an RDS instance: with `shared_database` they are the shared
            # instance's.
            SHARED_INSTANCE_SETTINGS = %i[database_class storage_gb engine_version backup_days].freeze
            # Default images, each a version tag plus the digest of its multi-architecture index,
            # so a rebuilt box pulls the same bytes.
            TUNNEL_IMAGE = "cloudflare/cloudflared:2026.9.3" \
                           "@sha256:072c067d25ccbe61d46e18f0d0723255f2bb5304f7317caa95b27031520ff92c".freeze
            PROXY_IMAGE  = "public.ecr.aws/docker/library/caddy:2.8" \
                           "@sha256:226d1f059b75399fe19182893c7184591c07b97afc8dfcf44eeb80c9a77a530f".freeze
            TUNNEL_SHAPE = "tunnel: a hash needs `to` (the container it forwards to) and `token_secret` " \
                           "(the secret holding the tunnel token)".freeze
            ORIGIN_ENV_SHAPE = "origin_env: the container environment variable names that hold the origin secret " \
                               "need an origin_secret and a task_definition to compare against".freeze
            CDN_ALIAS = /\A[a-z0-9.-]{4,253}\z/
            CDN_SHAPE = "cdn: a hash with `aliases`, the non-empty list of host names the CloudFront edge answers on".freeze
            CDN_NEEDS_ORIGIN = "cdn: the box admits CloudFront's addresses on port 80, so it needs the origin guard " \
                               "that refuses every other caller; declare origin_header and origin_secret".freeze
            ORIGIN_PAIR = "origin_header and origin_secret go together: the header a CDN sends, " \
                          "and the secret that holds its value".freeze
          end
        end
      end
    end
  end
end
