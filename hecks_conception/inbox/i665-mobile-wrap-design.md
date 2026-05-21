---
ref: i665
status: designed
category: mobile
title: PigeonCoop mobile wrap — Capacitor design (v1 scope, ASA)
---

# i665 — PigeonCoop mobile wrap, design

## Why

PigeonCoop v1 for ASA includes a mobile app (per Chris's 2026-05-20 scope lock). Parents are the primary audience and they live on their phones — push notifications, lock-screen previews, native-app-store discoverability. The web app alone isn't sufficient.

## The choice : Capacitor wrap of the existing Next.js site

**Capacitor** chosen over alternatives (React Native, native Swift+Kotlin, Flutter, PWA-only) because :

- **Zero codebase duplication.** The Next.js app IS the mobile app. Every feature that lands on `web/` lands on mobile the next sync.
- **Shortest path to App Store + Play Store.** Capacitor wraps the existing Next.js build into native iOS and Android shells in hours, not weeks.
- **Updates ship instantly.** Content changes (new feed posts, calendar updates, copy edits) land on the mobile app without a new app-store review.
- **Push notifications work.** Capacitor's notification plugin handles APNs (iOS) and FCM (Android) via the same JS API.
- **App stores accept Capacitor apps routinely now.** The historical Apple objection to "thin web shells" is mostly past ; Capacitor's deeper native integration (push, biometrics, files) clears the bar.

**Trade-off accepted** : UX feels web-inside-a-frame, not true native scroll / transitions. For a school app where parents check announcements, lunch, messages — acceptable. If user feedback after v1 says the wrap feels too webby, [v2 contingency](#v2-contingency-react-native) is the upgrade path.

## Architecture

Two pieces :

1. **`mobile/` directory in pigeoncoop repo** — Capacitor workspace alongside `web/`. Capacitor takes the static build at `web/out/` and wraps it for iOS + Android.
2. **Capacitor plugins** for the native bits :
   - `@capacitor/push-notifications` — device token registration + APNs/FCM delivery
   - `@capacitor/preferences` — simple local state (signed-in role, last-seen timestamp)
   - `@capacitor/share` — share to other apps (the principal sending a parent a shoutout link)
   - `@capacitor/app` — lifecycle hooks (foreground, background)

No separate UI codebase. Same Feed, Post, StoryCard components serve web + mobile.

## Push notifications

Four notification kinds (mapped to existing `Notification.NotificationSource` VO) :

- Announcement
- Shoutout (when one is approved naming the recipient or a child of the parent)
- Absence (sent to the school front office)
- Message (a direct message to the user)

Flow :

1. On app open, the Capacitor push plugin requests permission, gets a device token (APNs or FCM)
2. JS calls `dispatch('PigeonCoop::Person.RegisterDevice', { token, platform })` (new bluebook command, file in implementation)
3. The Notification aggregate's policy `DeliverPushOnNotification` fires when `Notification.Sent` event lands, looks up the recipient's tokens, dispatches `PushNotification.Deliver` per token
4. The PushNotification adapter (new, lightweight) calls APNs / FCM HTTP APIs

New bluebook bits required :
- `Person.RegisterDevice` command + `DeviceToken { platform, token }` VO
- `PushNotification` aggregate with `Deliver` command
- `:apns` and `:fcm` adapter families OR a single `:push` family with provider discriminator

## Distribution

v1 ships to :
- **TestFlight** (Apple) — internal test track for ASA staff + a handful of parent beta volunteers
- **Google Play internal track** — same shape

v2 graduates to **public App Store + Play Store** with a proper review pass.

## v1 scope deliverable

- `mobile/` Capacitor workspace bootstrapped against `web/out/`
- iOS + Android shells building cleanly
- Push notification registration on app open
- Push delivery for Announcements + Shoutouts + Messages (via the new bluebook commands above)
- TestFlight + Play internal builds, both shipped
- App icon + splash + ASA brand wired

## v2 contingency : React Native

If, after v1 ships, parents tell us the wrap feels too webby — v2 path is React Native :

- New `mobile/` workspace with Expo + React Native
- Port web components to RN components (Feed, Post, Profile, StoryCard) ; keep the dispatch client + types shared
- Add platform-specific native flows (richer push behaviors, widgets, complications)
- 6 sprints × 3 days estimated for the RN rebuild (the original i665 RN plan, retained as v2 fallback)

## Sibling card

[i666](./i666-mobile-wrap-implementation.md) carries the Capacitor implementation arc — sprint-by-sprint plan to land all of v1 above.
