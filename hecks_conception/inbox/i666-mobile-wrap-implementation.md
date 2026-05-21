---
ref: i666
status: designed
category: mobile
title: PigeonCoop mobile wrap — implementation arc (sprints)
---

# i666 — PigeonCoop mobile wrap, implementation arc

Sibling to [i665](./i665-mobile-wrap-design.md). This card is the sprint plan to land the v1 mobile app for ASA.

## Sprint 1 (3 days) — Bootstrap + skeleton

- Expo workspace at `pigeoncoop/mobile/`
- Tab navigator with 6 tabs (Student / Parent / Teacher / Admin / Alumni / Board)
- Each tab : placeholder screen showing the role name and a single "open web" button
- App icon + splash + ASA brand colours wired (asa-red / asa-purple / asa-cyan)
- iOS simulator + Android emulator both boot the app clean

## Sprint 2 (3 days) — Dispatch client + auth shim

- Shared `dispatch(command, attrs)` client targeting the worker URL
- Auth : v1 reuses the existing web session via deep-link sign-in (no native auth UI ; tap a magic-link email opens the app authenticated)
- Error surfaces : a friendly RN equivalent of the web TryIt result cards
- Smoke test : the Student tab dispatches `Person.MyBadge` and shows the result

## Sprint 3 (3 days) — Parent + Student feeds

- Port `web/components/social/Feed.tsx` and `Post.tsx` to RN equivalents at `mobile/components/social/Feed.tsx` + `Post.tsx`
- Parent tab : feed-first, four post kinds rendered correctly
- Student tab : feed-first, sees own + class-scoped posts
- Pull-to-refresh, infinite scroll

## Sprint 4 (3 days) — Push notifications

- Add Expo Notifications dependency
- Register device token on app open, dispatch `Person.RegisterDevice token=... platform=...` (new command, file in i665 implementation)
- Server side : conceive `PushNotification.Deliver` command on Notification aggregate, wire policy `DeliverPushOnNotification` so any `Notification.Sent` event also fires push to the recipient's registered device(s)
- Test : send an Announcement, parent's phone buzzes within 10s

## Sprint 5 (3 days) — Other tabs + polish

- Teacher / Admin / Alumni / Board tabs : list view rendering of their existing action grids, with native tap targets
- Empty states everywhere (no announcements yet, no shoutouts yet, etc.)
- Accessibility pass : VoiceOver labels, large-text scaling

## Sprint 6 (3 days) — TestFlight + Play internal

- Apple Developer Account + App Store Connect setup (assume Chris has the account)
- Google Play Console setup
- Both builds uploaded to internal test tracks
- Invitations sent to ASA staff list + parent beta volunteers
- One-page "how to install" doc in pigeoncoop/docs/

## Total : 6 sprints × 3 days = 18 working days for v1 mobile

Not blocked on v1 web shipping ; can run in parallel with the calendar / lunch / newsletter sprints once the dispatch client is in place.
