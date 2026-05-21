---
ref: i665
status: designed
category: mobile
title: PigeonCoop mobile wrap — React Native design (v1 scope, ASA)
---

# i665 — PigeonCoop mobile wrap, design

## Why

PigeonCoop v1 for ASA includes a mobile app (per Chris's 2026-05-20 scope lock). Parents are the primary audience and they live on their phones — push notifications, lock-screen previews, native-app-store discoverability. The web app alone isn't sufficient.

## The choice : React Native

**React Native** chosen over alternatives (native Swift+Kotlin, Flutter, Capacitor, PWA-only) because :

- One TypeScript codebase, two app-store builds. We already write Next.js + TSX for the web. The mental model and component idiom carry over.
- The web's existing components (Feed, Post, Profile, StoryCard) can be re-implemented as native React Native components with minimal logic duplication. The bluebook dispatch path is identical.
- Push notification stories on RN are mature (Expo's notifications, FCM, APNs).
- App-store distribution paths are well-trod ; TestFlight + Play Console internal-track are the v1 distribution surface.

**Trade-off accepted** : RN's bridge has performance overhead vs native. For PigeonCoop's UI shape (feed cards, calendars, message threads, badge QR), the overhead is invisible.

## Architecture

Three pieces :

1. **`mobile/` directory in pigeoncoop repo.** Expo-managed React Native workspace alongside `web/`. Shared types from `hecks/pigeoncoop.bluebook` via codegen.
2. **Shared dispatch client.** Both `web/` and `mobile/` call the same `/api/dispatch` proxy (or directly to the worker at `pigeoncoop-worker.belleboche.workers.dev`). Same JSON shape, same auth.
3. **Native-feel screens.** Each role portal maps to a tab : Student, Parent, Teacher, Admin, Alumni, Board. Parent + Student get the feed-first treatment (matching the social-pivot phase 2 design but rendered as RN). Other roles get the action grids.

## Push notifications

Four notification kinds (mapped to existing `Notification.NotificationSource` VO) :

- Announcement
- Shoutout (when one is approved naming the recipient or a child of the parent)
- Absence (sent to the school front office)
- Message (a direct message to the user)

Push dispatch is a new aggregate command (probably `PushNotification.Deliver`) that the existing Notification aggregate's policy fires when the user has a registered device token. New value-object : `DeviceToken { platform: "ios" | "android", token: String }`.

## Distribution

v1 ships to :
- **TestFlight** (Apple) — internal test track for ASA staff + a handful of parent beta volunteers
- **Google Play internal track** — same shape

v2 graduates to **public App Store + Play Store** with a proper review pass.

## v1 scope deliverable

- `mobile/` workspace bootstrapped (Expo)
- Tab navigator wired to the six roles
- Parent + Student tabs render the social-pivot feed (Feed + Post components ported)
- Other tabs render a simple list pointing at the web for now (graceful degradation)
- Push notification registration on app open
- Push delivery for Announcements + Shoutouts + Messages
- TestFlight + Play internal builds, both shipped

## Sibling card

[i666](./i666-mobile-wrap-implementation.md) carries the implementation arc — the iteration-by-iteration sprint plan to land all of the above.
