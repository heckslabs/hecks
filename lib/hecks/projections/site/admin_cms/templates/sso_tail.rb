# frozen_string_literal: true

module Hecks
  module Projections
    module Site
      module AdminCms
        module Templates
          # The second part of the sign-in endpoint.
          module Sso
            # The rest, from the token check on.
            TAIL = <<~TS
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
        end
      end
    end
  end
end
