# frozen_string_literal: true

require "json"
require_relative "../../projector"
require_relative "admin"
require_relative "routes_ts"

module Hecks
  module Projections
    module Site
      # A site's admin sign-in as one dependency-free TypeScript module, `admin.ts`.
      #
      # The module is what a site's middleware and pages need to ask the domain host who is signed
      # in and whether that person may use the admin pages: the session cookie's settings, a check
      # that the host's membership list holds the person as an admin, a gate that decides a path
      # from the route table's `auth` column, and the hand-off to the content system. It imports the
      # route table module beside it and nothing else, so it loads under Node and any bundler.
      #
      # The text is a pure function of the `Admin` row and the extension: nothing in it names a
      # time or a machine, so regenerating from the same row changes nothing.
      module SiteAdmin
        extend Projector::Target

        projects_as :site_admin, emits: :files

        module_function

        # Renders `admin.ts` for a project that declares an admin row.
        #
        # @param bluebook [Bluebook::Chapter] the chapter that declares the route table
        # @param options [Hash{Symbol => Object}] `:admin` (Admin) the checked admin row, or nil;
        #   `:extension` (String) the extension the routes module is written with, `ts` by default
        # @return [Hash{String => String}] `"admin.ts"` to its text; empty with no admin row
        def call(bluebook:, options: {})
          admin = options[:admin]
          return {} if admin.nil?

          { "admin.ts" => render(admin, options.fetch(:extension, "ts")) }
        end

        # @param admin [Admin] a checked admin row
        # @param extension [String] the extension of the route table module
        # @return [String] the module's text, ending in a newline
        def render(admin, extension)
          [RoutesTs::BANNER, header, imports(extension), settings(admin), memo, helpers].join("\n\n") << "\n"
        end

        def header
          <<~TS.chomp
            // The admin sign-in of this site, projected from its bluebook's Admin row and Route rows. Change the
            // rows and run `hecks site site_projection.project_site`; with `--check` it fails when this file is out of date.
          TS
        end

        def imports(extension)
          %(import { MIDDLEWARE, ROUTES, matchesPath } from "./routes.#{extension}";)
        end

        def settings(admin)
          setting = admin.setting
          fields = {
            sessionCookie: setting.session_cookie, sessionMaxAge: setting.session_max_age,
            hostEnv: setting.host_env, hostDefault: setting.host_default, roles: admin.roles,
            accountPath: setting.account_path, membersPath: setting.members_path,
            ssoTokenPath: setting.sso_token_path, ssoTarget: setting.sso_target, login: setting.login,
            sso: setting.sso, verdictTtlMs: setting.verdict_ttl_ms, timeoutMs: setting.timeout_ms
          }
          body = fields.map { |key, value| "  #{key}: #{RoutesTs.literal(value)}," }
          "/** What the sign-in is built from: the project's Admin row, defaults filled. */\n" \
            "export const ADMIN = {\n#{body.join("\n")}\n} as const;"
        end

        def memo
          <<~TS.chomp
            const MAX_REMEMBERED = 500;

            /** Remembers each key's answer for the verdict TTL; callers that arrive while it loads share it, and a failure is never kept. */
            function remember<V>(load: (key: string) => Promise<V>) {
              const values = new Map<string, { at: number; value: V }>();
              const running = new Map<string, Promise<V>>();
              return {
                get(key: string): Promise<V> {
                  const hit = values.get(key);
                  if (hit && Date.now() - hit.at < ADMIN.verdictTtlMs) return Promise.resolve(hit.value);
                  const shared = running.get(key);
                  if (shared) return shared;
                  const started: Promise<V> = load(key)
                    .then((value) => {
                      if (running.get(key) === started) {
                        values.delete(key);
                        values.set(key, { at: Date.now(), value });
                        if (values.size > MAX_REMEMBERED) values.delete(values.keys().next().value as string);
                      }
                      return value;
                    })
                    .finally(() => {
                      if (running.get(key) === started) running.delete(key);
                    });
                  running.set(key, started);
                  return started;
                },
                forget(): void {
                  values.clear();
                  running.clear();
                },
              };
            }
          TS
        end

        def helpers
          [configuration, membership, sessions, verdicts, handoff, routing, gate].join("\n\n")
        end

        def configuration
          <<~'TS'.chomp
            export interface AdminSettings {
              /** The domain host's address, when not read from the environment variable the Admin row names. */
              host?: string;
              /** The fetch to use, for tests. */
              fetch?: typeof fetch;
            }

            let settings: AdminSettings = {};

            /** Sets the host or the fetch, and forgets every remembered verdict. */
            export function configureAdmin(next: AdminSettings): void {
              settings = next;
              forgetAdminSessions();
            }

            function hostUrl(): string {
              const named = settings.host ?? (typeof process !== "undefined" ? process.env[ADMIN.hostEnv] : undefined);
              return (named || ADMIN.hostDefault).replace(/\/+$/, "");
            }

            function askHost(path: string, cookieValue: string): Promise<Response> {
              return (settings.fetch ?? fetch)(`${hostUrl()}${path}`, {
                headers: { Cookie: `${ADMIN.sessionCookie}=${cookieValue}` },
                signal: AbortSignal.timeout(ADMIN.timeoutMs),
              });
            }
          TS
        end

        def membership
          <<~TS.chomp
            export interface MemberRow {
              email?: unknown;
              role?: unknown;
              disabled?: unknown;
            }

            /** True when `email` (any case) is a member holding one of the admin roles and not disabled. */
            export function isActiveAdmin(members: MemberRow[], email: string): boolean {
              const wanted = email.trim().toLowerCase();
              return members.some(
                (member) =>
                  typeof member.email === "string" &&
                  member.email.trim().toLowerCase() === wanted &&
                  (ADMIN.roles as readonly unknown[]).includes(member.role) &&
                  member.disabled !== true,
              );
            }
          TS
        end

        def sessions
          <<~TS.chomp
            /** A signed-in admin and the membership list that vouched for them. */
            export interface AdminSession {
              email: string;
              members: unknown[];
            }

            async function fetchAccountEmail(cookieValue: string): Promise<string | null> {
              const res = await askHost(ADMIN.accountPath, cookieValue);
              if (!res.ok) return null;
              const data = await res.json();
              return typeof data.email === "string" ? data.email : null;
            }

            async function fetchAdminSession(cookieValue: string): Promise<AdminSession | null> {
              const [email, membersRes] = await Promise.all([
                fetchAccountEmail(cookieValue),
                askHost(ADMIN.membersPath, cookieValue),
              ]);
              if (!email || !membersRes.ok) return null;
              const members = await membersRes.json();
              return Array.isArray(members) && isActiveAdmin(members, email) ? { email, members } : null;
            }
          TS
        end

        def verdicts
          <<~TS.chomp
            const accountEmails = remember(fetchAccountEmail);
            const adminSessions = remember(fetchAdminSession);

            /** Drops every remembered verdict, for after this process changes a member. */
            export function forgetAdminSessions(): void {
              accountEmails.forget();
              adminSessions.forget();
            }

            /** The signed-in person's email, or null when the cookie is absent or the host does not know it. */
            export async function currentAccountEmail(cookieValue: string | undefined): Promise<string | null> {
              return cookieValue ? accountEmails.get(cookieValue) : null;
            }

            /** The signed-in person and the membership list when they hold an admin role, else null. */
            export async function currentAdminSession(cookieValue: string | undefined): Promise<AdminSession | null> {
              return cookieValue ? adminSessions.get(cookieValue) : null;
            }

            /** The signed-in person's email when they may use the admin pages, else null. */
            export async function currentAdminEmail(cookieValue: string | undefined): Promise<string | null> {
              return (await currentAdminSession(cookieValue))?.email ?? null;
            }
          TS
        end

        def handoff
          <<~TS.chomp
            /**
             * Where the hand-off to the CMS sends a person: the CMS's own sign-in endpoint with a short-lived
             * token from the host, or the login page when there is no session or the host refuses the token.
             * `to` is a path inside the CMS to open once signed in; the CMS checks it.
             */
            export async function ssoRedirect(cookieValue: string | undefined, to?: string | null): Promise<string> {
              if (!cookieValue) return ADMIN.login;
              const res = await askHost(ADMIN.ssoTokenPath, cookieValue);
              if (!res.ok) return ADMIN.login;
              const { token } = await res.json();
              const params = new URLSearchParams({ token });
              if (to) params.set("to", to);
              return `${ADMIN.ssoTarget}?${params}`;
            }
          TS
        end

        def routing
          <<~'TS'.chomp
            /** How specific a route pattern is: the characters outside its wildcards, so `/admin-login` outranks `/admin*`. */
            function specificity(pattern: string): number {
              return pattern.replace(/\*/g, "").length;
            }

            /** The route that describes a path: the most specific match, and the first listed of equals. */
            function routeFor(pathname: string): (typeof ROUTES)[number] | undefined {
              let best: (typeof ROUTES)[number] | undefined;
              for (const candidate of ROUTES) {
                if (!matchesPath(candidate.path, pathname)) continue;
                if (best === undefined || specificity(candidate.path) > specificity(best.path)) best = candidate;
              }
              return best;
            }
          TS
        end

        def gate
          <<~TS.chomp
            export type AdminGate = { allow: true } | { allow: false; status: 401 } | { allow: false; redirect: string };

            /**
             * Whether a request may go on. The most specific route that matches the path decides: an `admin`
             * route, or any path under the draft-preview prefix, needs an admin session. A preview without
             * one is refused with 401 and nothing else; any other admin path is sent to the login page.
             */
            export async function adminGate(pathname: string, cookieValue: string | undefined): Promise<AdminGate> {
              const previewing = pathname.startsWith(MIDDLEWARE.preview.prefix + "/");
              if (routeFor(pathname)?.auth !== "admin" && !previewing) return { allow: true };
              if (await currentAdminEmail(cookieValue)) return { allow: true };
              return previewing ? { allow: false, status: 401 } : { allow: false, redirect: ADMIN.login };
            }
          TS
        end
      end
    end
  end
end
