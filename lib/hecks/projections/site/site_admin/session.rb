# frozen_string_literal: true

module Hecks
  module Projections
    module Site
      module SiteAdmin
        # The session half of the admin module: the memo that remembers verdicts, the settings, the
        # membership test and the fetches that read the host.
        module Session
          # The TypeScript of `memo`.
          MEMO = <<~TS.chomp
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

          # The TypeScript of `configuration`.
          CONFIGURATION = <<~'TS'.chomp
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

          # The TypeScript of `membership`.
          MEMBERSHIP = <<~TS.chomp
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

          # The TypeScript of `sessions`.
          SESSIONS = <<~TS.chomp
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
      end
    end
  end
end
