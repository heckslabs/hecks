# frozen_string_literal: true

module Hecks
  module Projections
    module Site
      module AdminCms
        module Templates
          # The TypeScript text of the sign-in endpoint, in two parts.
          module Sso
            # The first part, up to the token check.
            HEAD = <<~TS
              __BANNER__

              import { verifyAccountToken } from "@hecks/client";

              import { membership } from "../auth/membership";
              import type { Endpoint } from "payload";
              import { getFieldsToSign, jwtSign } from "payload";
              import { addSessionToUser, generatePayloadCookie } from "payload/shared";

              // The secret that signs and verifies the short-lived hand-off token only. It MUST be the same value
              // as the domain host's SESSION_SECRET, or every token fails verification. Payload's own session
              // cookie (minted below) is signed with Payload's own `secret`, unrelated. With none set outside
              // production the host's development default is used; in production an unset secret refuses every token.
              const AUTH_SECRET =
                process.env.AUTH_SECRET || (process.env.NODE_ENV === "production" ? "" : "dev_only_change_me_in_production");

              // The hand-off token is the host's account token; @hecks/client's verifyAccountToken checks its
              // signature and expiry. What is kept here is the email's form: Payload lowercases and trims
              // `users.email` on write (the users collection's own beforeChange), so the lookup, the lazy create
              // and the retry below must use that same form: a mixed-case address in the token would otherwise
              // miss the stored row, hit the unique index on create, miss again on the re-find, and fail every
              // sign-in after the first. `normalizeEmail` does that, and refuses an address that is blank afterwards.
              export function verifyHandoffToken(token: string): { email: string } | null {
                if (!AUTH_SECRET) return null;
                const claims = verifyAccountToken(token, AUTH_SECRET, { normalizeEmail: true });
                return claims ? { email: claims.email } : null;
              }

              // Real single sign-on, not a redirect trick: mints an actual Payload session cookie for the `users`
              // doc matching the token's email, using the same getFieldsToSign, jwtSign and cookie pipeline
              // Payload's own login endpoint uses, so the resulting session is indistinguishable from a real login.
              // Nobody sees Payload's own login screen: the site's hand-off route sends a signed-in admin here
              // with a fresh token, always through the site's own path to the content system, never its internal
              // address, so this endpoint is reachable at __SSO_TARGET__ and the Set-Cookie below lands on the
              // site's origin, not a cross-origin (third-party) one.
              export const ssoEndpoint: Endpoint = {
                path: __ENDPOINT__,
                method: "get",
                handler: async (req) => {
                  const token = req.searchParams.get("token");
                  const claims = token ? verifyHandoffToken(token) : null;
                  if (!claims) {
                    return new Response("Invalid or expired SSO token.", { status: 401 });
                  }

                  // A valid account token proves an account, not an admin: nobody gets a Payload user row or
                  // cookie unless the membership list currently admits them.
                  if (!(await membership.isAdmitted(claims.email))) {
                    return new Response("This account is not admitted to the CMS.", { status: 403 });
                  }

                  const matches = await req.payload.find({
                    collection: "users",
                    where: { email: { equals: claims.email } },
                    limit: 1,
                  });
                  let user = matches.docs[0];
                  // Lazy provision: the users collection's create access is false (REST POST on it is the gap
                  // this closes), so the Payload doc is minted here, after the token has already proven the email
                  // belongs to an admitted person. Users has no password at all (disableLocalStrategy), so nobody
                  // logs into Payload directly. overrideAccess: the Local API would otherwise inherit this
                  // unauthenticated req and refuse the create we just denied on REST.
                  // Unique-email race (two first sign-ins): re-find rather than fail.
                  if (!user) {
                    try {
                      user = await req.payload.create({
                        collection: "users",
                        data: { email: claims.email },
                        overrideAccess: true,
                      });
                    } catch {
                      const retry = await req.payload.find({
                        collection: "users",
                        where: { email: { equals: claims.email } },
                        limit: 1,
                      });
                      user = retry.docs[0];
                      if (!user) {
                        return new Response("Could not provision a Payload user for this account.", { status: 500 });
                      }
                    }
                  }

            TS
          end
        end
      end
    end
  end
end
