# frozen_string_literal: true

module Hecks
  module Projections
    module Site
      module AdminCms
        # The TypeScript text of the four files, with `__NAME__` placeholders that `AdminCms.fill`
        # replaces from the admin row. Each reads as the file a project would write by hand.
        module Templates
          module_function

          def membership
            <<~'TS'
              __BANNER__

              // Is this editor still admitted? The domain's membership list decides, not the content system.
              // Signing in (endpoints/sso.ts) proved the person was admitted then; this asks again, so that
              // disabling or removing someone locks them out on their next request, not when their session runs out.
              //
              // The question is the host's own account route, which answers only for a person who holds a role
              // and is not disabled, asked with a short account token signed by the secret the host checks (the
              // content system's AUTH_SECRET is the host's SESSION_SECRET). The answer is remembered for a minute
              // per email so every admin request does not cost a round trip.
              import { accountToken, resolveAccountCookieName } from "@hecks/client";

              const DEFAULT_URL = __HOST_DEFAULT__;
              const DEFAULT_COOKIE = __COOKIE__;
              const TOKEN_TTL_SECONDS = 60;
              export const REMEMBER_MS = 60_000;

              // The shared secret. With none set outside production the host's development default is used, as
              // endpoints/sso.ts does; in production an unset secret refuses every question.
              const AUTH_SECRET =
                process.env.AUTH_SECRET || (process.env.NODE_ENV === "production" ? "" : "dev_only_change_me_in_production");

              export interface MembershipCheck {
                /** True while `email` is admitted; false when membership says not, or cannot be asked. */
                isAdmitted(email: string): Promise<boolean>;
              }

              export interface MembershipOptions {
                url?: string;
                /** The host route asked: the account route (any admitted person) by default, the members list for admin roles only. */
                path?: string;
                /** Decides from the host's answer; the default is any 2xx. */
                accept?: (res: Response, email: string) => Promise<boolean>;
                secret?: string;
                cookieName?: string;
                fetch?: typeof fetch;
                now?: () => number;
              }

              /** A membership check with its own one-minute memory. */
              export function membershipCheck(opts: MembershipOptions = {}): MembershipCheck {
                const remembered = new Map<string, { admitted: boolean; until: number }>();
                const now = opts.now ?? Date.now;
                const doFetch = opts.fetch ?? fetch;

                return {
                  async isAdmitted(email: string): Promise<boolean> {
                    const key = email.trim().toLowerCase();
                    const hit = remembered.get(key);
                    if (hit && hit.until > now()) return hit.admitted;

                    const secret = opts.secret ?? AUTH_SECRET;
                    const url = (opts.url ?? (process.env[__HOST_ENV__] || DEFAULT_URL)).replace(/\/+$/, "");
                    const cookieName = resolveAccountCookieName(opts.cookieName ?? (process.env.HECKS_SESSION_COOKIE || DEFAULT_COOKIE));
                    let admitted = false;
                    if (secret) {
                      try {
                        const res = await doFetch(`${url}${opts.path ?? __ACCOUNT_PATH__}`, {
                          headers: { Cookie: `${cookieName}=${accountToken(secret, key, TOKEN_TTL_SECONDS)}` },
                          signal: AbortSignal.timeout(5_000),
                        });
                        admitted = opts.accept ? res.ok && (await opts.accept(res, key)) : res.ok;
                      } catch {
                        // Membership cannot be asked: refuse, as the content system already refuses to
                        // show domain-held fields it cannot read.
                        admitted = false;
                      }
                    }
                    remembered.set(key, { admitted, until: now() + REMEMBER_MS });
                    return admitted;
                  },
                };
              }

              export const membership = membershipCheck();

              /** The roles the host's own admin gate passes. */
              export const ADMIN_ROLES = __ROLES__;

              /** True when `rows` (the host's members list) hold `email` with an admin role and not disabled. */
              export function holdsAdminRole(rows: unknown, email: string): boolean {
                return (
                  Array.isArray(rows) &&
                  rows.some((row: any) => typeof row?.email === "string" && row.email.trim().toLowerCase() === email && ADMIN_ROLES.includes(row.role) && row.disabled !== true)
                );
              }

              /**
               * Admin roles only. The host's members list answers any signed-in member, so it is the list's own
               * row for the caller that decides, as the site's admin gate does.
               */
              export const adminCheck = (opts: MembershipOptions = {}): MembershipCheck =>
                membershipCheck({
                  ...opts,
                  path: __MEMBERS_PATH__,
                  accept: async (res, email) => holdsAdminRole(await res.json().catch(() => null), email),
                });
            TS
          end

          def session_strategy
            <<~TS
              __BANNER__

              import { jwtVerify } from "jose";
              import type { AuthStrategy, CollectionAfterLogoutHook } from "payload";

              import { membership } from "./membership";

              // Payload's own `local-jwt` strategy refuses any collection with `disableLocalStrategy` set
              // ("JWT authentication requires an auth-enabled local collection") and is not even registered when
              // every auth collection disables it. Users has no password login, so endpoints/sso.ts mints the
              // session cookie and this verifies that same cookie itself: the token Payload's `jwtSign` produces
              // ({ id, collection, sid }, HS256 over `payload.secret`, authVersion 1 in the protected header),
              // then loads the user and requires its `sessions` entry to still exist so a logout or an expired
              // session revokes the cookie.
              const JWT_AUTH_VERSION = 1;

              // Same cookie and CSRF rules as Payload's own extractJWT, cookie only: a request carrying an Origin
              // must be on the csrf allowlist, and one without an Origin must be same-origin, same-site or a
              // direct navigation. No Bearer or JWT header: nothing here mints tokens for API clients.
              function sessionCookie(headers: Headers, cookiePrefix: string, csrf: string[]): string | null {
                const name = `${cookiePrefix}-token`;
                const raw = (headers.get("cookie") ?? "")
                  .split(";")
                  .map((part) => part.trim())
                  .find((part) => part.startsWith(`${name}=`));
                if (!raw) return null;
                const token = decodeURIComponent(raw.slice(name.length + 1));

                const origin = headers.get("Origin");
                if (origin) return csrf.length === 0 || csrf.includes(origin) ? token : null;
                if (csrf.length === 0) return token;
                return ["same-origin", "same-site", "none"].includes(headers.get("Sec-Fetch-Site") ?? "") ? token : null;
              }

              // Payload's logout only deletes the session row when the local strategy is on, so without this the
              // cookie it clears would still verify until it expires.
              export const revokeSessionOnLogout: CollectionAfterLogoutHook = async ({ req }) => {
                const { user, payload } = req;
                const sid = (user as { _sid?: string } | null)?._sid;
                if (!user || !sid) return;

                const current = await payload.findByID({ collection: "users", id: user.id, depth: 0, overrideAccess: true, req });
                const sessions = (current.sessions ?? []).filter((session) => session.id !== sid);
                await payload.update({ collection: "users", id: user.id, data: { sessions }, overrideAccess: true, req });
              };

              export const sessionStrategy: AuthStrategy = {
                name: "sso-session",
                authenticate: async ({ headers, payload }) => {
                  const token = sessionCookie(headers, payload.config.cookiePrefix, payload.config.csrf);
                  if (!token) return { user: null };

                  try {
                    const { payload: claims, protectedHeader } = await jwtVerify(token, new TextEncoder().encode(payload.secret));
                    if (protectedHeader.authVersion !== JWT_AUTH_VERSION) return { user: null };

                    const { id, collection, sid } = claims as { id?: unknown; collection?: unknown; sid?: unknown };
                    if (collection !== "users" || typeof sid !== "string") return { user: null };
                    if (typeof id !== "number" && typeof id !== "string") return { user: null };

                    const user = await payload.findByID({ collection: "users", id, depth: 0, overrideAccess: true });
                    if (!user?.sessions?.some((session) => session.id === sid)) return { user: null };
                    // Payload's session alone is not enough: the domain's membership list must still admit this
                    // person (membership.ts), so disabling someone there locks them out here on their next request.
                    if (typeof user.email !== "string" || !(await membership.isAdmitted(user.email))) return { user: null };

                    return { user: { ...user, collection: "users", _strategy: "sso-session", _sid: sid } };
                  } catch {
                    return { user: null };
                  }
                },
              };
            TS
          end

          def sso
            <<~TS
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

                  const collectionConfig = req.payload.collections.users.config;
                  // `req.payload.find()`'s return type has no `collection` field on each doc (it is implied by
                  // the query, not carried on the result), while `addSessionToUser` and `getFieldsToSign` type
                  // their `user` parameter as Payload's `UntypedUser`, which requires one. This doc is a "users"
                  // document (the only collection the query above searches), so the annotation is correct.
                  const authUser = { ...user, collection: "users" as const };
                  // useSessions defaults to true: a JWT without a matching entry in the user's own `sessions`
                  // array fails Payload's own auth check silently (the strategy just returns no user, bouncing to
                  // the login screen as if never signed in). This is the exact call the login operation makes
                  // before signing.
                  const { sid } = await addSessionToUser({ collectionConfig, payload: req.payload, req, user: authUser });
                  const fieldsToSign = getFieldsToSign({ collectionConfig, email: user.email, sid, user: authUser });
                  const { token: payloadToken } = await jwtSign({
                    fieldsToSign,
                    secret: req.payload.secret,
                    tokenExpiration: collectionConfig.auth.tokenExpiration,
                  });
                  const cookie = generatePayloadCookie({
                    collectionAuthConfig: collectionConfig.auth,
                    cookiePrefix: req.payload.config.cookiePrefix,
                    token: payloadToken,
                  });

                  // Optional deep link (`to`): restricted to a path inside the content system, never a
                  // visitor-supplied absolute URL, so this cannot be turned into an open redirect.
                  const to = req.searchParams.get("to");
                  const destination = to && to.startsWith(__CMS_PREFIX__) ? to : __CMS_ADMIN__;

                  return new Response(null, {
                    status: 302,
                    // The base path does not auto-prefix a manually built Response's Location the way a framework
                    // link or redirect helper would, so it is set explicitly.
                    headers: { Location: destination, "Set-Cookie": cookie },
                  });
                },
              };
            TS
          end

          def users
            <<~TS
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
