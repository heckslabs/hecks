# frozen_string_literal: true

module Hecks
  module Projections
    module Site
      module SiteHost
        # The image's build file, as a `format` template.
        module Dockerfile
          # The file, with `%<name>s` placeholders for the banner, the Node version, the port and
          # the heap.
          TEXT = <<~'DOCKER'
            # %<banner>s
            #
            # The content system (Payload on Next's standalone server) as a container. Build from this
            # directory. deploy-aws/boot.mjs resolves the secrets named by the *_ARN variables into
            # DATABASE_URL and PAYLOAD_SECRET before it starts the server, so nothing here is a secret.
            #
            # Runtime environment, supplied by the task definition:
            #   NODE_ENV=production, USE_POSTGRES=true, USE_S3_STORAGE=true, S3_MEDIA_BUCKET
            #   DB_HOST, DB_NAME, DB_SECRET_ARN, PAYLOAD_SECRET_ARN, CORS_ORIGINS, AWS_REGION

            # ---- build stage ----
            FROM node:%<node>s-slim AS build
            WORKDIR /app

            # A lockfile written on macOS omits the Linux entries of optional native packages
            # (sharp), and `next build` then fails deep inside page-data collection. Write it on the
            # image's own platform: remove node_modules and package-lock.json and run npm install.
            COPY package.json package-lock.json ./
            RUN npm ci

            COPY . .
            # payload-types.ts is generated and untracked, so a clean checkout has none and the type check
            # inside `next build` would see untyped results. Generating it only loads the config
            # (no database); the values are placeholders and the flags are the ones production boots with.
            RUN USE_POSTGRES=true USE_S3_STORAGE=true PAYLOAD_SECRET=build-only \
                S3_MEDIA_BUCKET=build-only AWS_REGION=us-east-1 DATABASE_URL=postgres://build-only/build-only \
                npm run generate:types
            RUN npm run build

            # ---- runtime stage ----
            FROM node:%<node>s-slim
            WORKDIR /app
            ENV NODE_ENV=production
            # The task is shared with sibling containers; without a cap Node sizes its heap from the whole task.
            ENV NODE_OPTIONS=--max-old-space-size=%<heap>d

            # Next's standalone output holds a minimal server.js and its traced node_modules; the static
            # files are not part of it and are copied separately.
            COPY --from=build /app/.next/standalone/ ./
            COPY --from=build /app/.next/static ./.next/static

            COPY deploy-aws/boot.mjs ./
            # RDS enforces TLS; boot.mjs verifies against Amazon's CA bundle.
            ADD https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem ./rds-global-bundle.pem

            # boot.mjs sits outside the Next app, so `next build` does not trace its import of the AWS SDK.
            COPY --from=build /app/node_modules/@aws-sdk ./node_modules/@aws-sdk
            COPY --from=build /app/node_modules/@smithy ./node_modules/@smithy
            COPY --from=build /app/node_modules/tslib ./node_modules/tslib

            # Next's standalone server reads HOSTNAME for its bind address.
            ENV HOSTNAME=0.0.0.0
            ENV PORT=%<port>d
            EXPOSE %<port>d

            # Nothing writes to /app at runtime (media goes to S3), so no root.
            USER node
            CMD ["node", "boot.mjs"]
          DOCKER
        end
      end
    end
  end
end
