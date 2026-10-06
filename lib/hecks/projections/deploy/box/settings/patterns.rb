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
            ORIGIN_PAIR = "origin_header and origin_secret go together: the header a CDN sends, " \
                          "and the secret that holds its value".freeze
          end
        end
      end
    end
  end
end
