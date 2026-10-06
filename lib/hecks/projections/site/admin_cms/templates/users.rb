# frozen_string_literal: true

module Hecks
  module Projections
    module Site
      module AdminCms
        module Templates
          # The TypeScript text of `users`.
          module Users
            # The file, with `__NAME__` placeholders.
            TEXT = <<~TS
              __BANNER__

              import type { CollectionConfig } from "payload";

              import { revokeSessionOnLogout, sessionStrategy } from "../auth/sessionStrategy";

              // Managed from the domain, not hand-edited: the membership list is the source of truth for who can
              // log in. Docs here are provisioned lazily by endpoints/sso.ts on a first sign-in by an admitted
              // person, reached only through that sign-in and never this collection's own login screen. Hidden from
              // the admin nav (not deleted: `admin.hidden` only affects the admin UI) so nobody mistakes it for a
              // place to hand-manage admins.
              export const Users: CollectionConfig = {
                slug: "users",
                // No passwords: there is no local login, register, forgot-password or reset-password, and no
                // hash, salt, reset or lock columns. The only way in is the session cookie endpoints/sso.ts mints,
                // verified by sessionStrategy (Payload's own JWT strategy turns off with the local strategy).
                auth: {
                  disableLocalStrategy: true,
                  // Payload's default is a non-Secure cookie; in production it must never ride a plain-HTTP hop.
                  cookies: { secure: process.env.NODE_ENV === "production", sameSite: "Lax" },
                  strategies: [sessionStrategy],
                },
                admin: {
                  hidden: true,
                  useAsTitle: "email",
                },
                hooks: {
                  afterLogout: [revokeSessionOnLogout],
                },
                // Closed: creating a user over the REST API (and Payload's first-register) would let anyone who
                // can reach the content system mint a user and log in directly, bypassing the site's sign-in.
                // Create is denied for REST; the sign-in endpoint's Local API create uses overrideAccess after the
                // token has already proven the email belongs to an admitted person.
                access: {
                  create: () => false,
                },
                // With the local strategy disabled Payload stops adding its own auth fields, so the two that
                // remain are declared here, shaped exactly like Payload's so the existing columns and the
                // users_sessions table are kept as they are.
                fields: [
                  {
                    name: "email",
                    type: "email",
                    required: true,
                    unique: true,
                    hooks: {
                      beforeChange: [({ value }) => (value ? String(value).toLowerCase().trim() : value)],
                    },
                  },
                  {
                    name: "sessions",
                    type: "array",
                    access: {
                      read: ({ doc, req: { user } }) => user?.id === doc?.id,
                      update: () => false,
                    },
                    admin: { disabled: true },
                    fields: [
                      { name: "id", type: "text", required: true },
                      { name: "createdAt", type: "date", defaultValue: () => new Date() },
                      { name: "expiresAt", type: "date", required: true },
                    ],
                  },
                ],
              };
            TS
          end
        end
      end
    end
  end
end
