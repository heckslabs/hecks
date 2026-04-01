# Auth Screens

When the auth extension is active, the serve extension automatically generates
login, signup, and logout HTML pages with session management.

## Routes

| Method | Path      | Description                      |
|--------|-----------|----------------------------------|
| GET    | /login    | Render login form                |
| POST   | /login    | Authenticate and set session     |
| GET    | /signup   | Render signup form               |
| POST   | /signup   | Create account and set session   |
| GET    | /logout   | Clear session, redirect to login |

## Domain setup

```ruby
Hecks.domain "Clinic" do
  aggregate "Appointment" do
    attribute :patient, String
    attribute :date, Date

    command "Book" do
      actor "Receptionist"
      attribute :patient, String
      attribute :date, Date
    end
  end
end
```

The `actor "Receptionist"` declaration tells the auth extension which roles
exist. New signups are assigned the first actor role found in the DSL (here,
"Receptionist").

## How it works

1. **Login form** -- email + password fields with inline CSS, no JS framework.
2. **Signup form** -- email + password + confirm fields. Validates:
   - All fields required
   - Passwords match
   - Minimum 8 characters
   - No duplicate emails
3. **Session cookie** -- `_hecks_session` HttpOnly cookie carries a
   Base64-encoded JSON payload with `email` and `role`. On each request the
   server restores `Hecks.actor` from the cookie.
4. **Logout** -- clears the cookie and sets `Hecks.actor = nil`.

## Serving

```bash
hecks serve clinic
# =>
#   GET    /login
#   POST   /login
#   GET    /signup
#   POST   /signup
#   GET    /logout
#   GET    /appointments
#   ...
```

Visit `http://localhost:9292/login` to see the login screen. After signing in
the session cookie ensures `Hecks.actor` is set for every subsequent request,
so actor-guarded commands work transparently.

## Development store

The in-memory credential store is for development and prototyping only.
Accounts are lost when the server restarts. Production apps should implement
a persistent adapter.
