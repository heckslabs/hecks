# frozen_string_literal: true

module Hecks
  module Projections
    module Site
      module SiteAdmin
        # The access half of the admin module: remembered verdicts, the hand-off to the content
        # system, route matching and the gate.
        module Access
          # The TypeScript of `verdicts`.
          VERDICTS = <<~TS.chomp
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

          # The TypeScript of `handoff`.
          HANDOFF = <<~TS.chomp
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

          # The TypeScript of `routing`.
          ROUTING = <<~'TS'.chomp
            /**
             * How specific a route pattern is: the characters that are not a wildcard or a `:name` parameter,
             * so `/admin-login` outranks `/admin*` and `/admin.html` outranks `/:slug.html`.
             */
            function specificity(pattern: string): number {
              return pattern.replace(/:[A-Za-z_]\w*/g, "").replace(/\*/g, "").length;
            }

            /**
             * The route that describes a path: the most specific match. Between routes equally specific the
             * `admin` one wins, so a tie never lets a visitor through; after that, the first listed.
             */
            function routeFor(pathname: string): (typeof ROUTES)[number] | undefined {
              let best: (typeof ROUTES)[number] | undefined;
              for (const candidate of ROUTES) {
                if (!matchesPath(candidate.path, pathname)) continue;
                if (best === undefined) {
                  best = candidate;
                  continue;
                }
                const more = specificity(candidate.path) - specificity(best.path);
                if (more > 0 || (more === 0 && candidate.auth === "admin" && best.auth !== "admin")) best = candidate;
              }
              return best;
            }
          TS

          # The TypeScript of `gate`.
          GATE = <<~TS.chomp
            export type AdminGate = { allow: true } | { allow: false; status: 401 } | { allow: false; redirect: string };

            /**
             * Whether a request may go on. The most specific route that matches the path decides (see `routeFor`): an `admin`
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
