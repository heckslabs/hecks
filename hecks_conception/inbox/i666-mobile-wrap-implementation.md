---
ref: i666
status: designed
category: mobile
title: PigeonCoop mobile wrap — Capacitor implementation arc (sprints)
---

# i666 — PigeonCoop mobile wrap, Capacitor implementation arc

Sibling to [i665](./i665-mobile-wrap-design.md). This card is the sprint plan to land the v1 mobile app (Capacitor wrap of Next.js) for ASA.

Capacitor is dramatically cheaper than the React Native alternative because the UI work is already done. Most sprints are configuration + native plumbing, not component porting.

## Sprint 1 (3 days) — Capacitor bootstrap + iOS shell

- Add `@capacitor/core` + `@capacitor/cli` + `@capacitor/ios` to `mobile/`
- Point Capacitor at `web/out/` (Next.js static export)
- `npx cap add ios` + `npx cap sync`
- Open in Xcode, configure bundle id (com.embryonaut.pigeoncoop), team, capabilities
- App icon + splash screen (ASA brand colours)
- Build runs in iOS simulator end to end, all six role tabs reachable

## Sprint 2 (3 days) — Android shell + tab navigation polish

- `@capacitor/android` + `npx cap add android`
- Configure Gradle, app id, brand assets
- Android Studio build runs in emulator
- Mobile-specific CSS tweaks : tap targets at 44pt minimum, safe-area insets, no hover states
- Both platforms : the Phase-1 grid renders as native scroll-friendly cards

## Sprint 3 (3 days) — Push notifications (the real native work)

- `@capacitor/push-notifications` plugin
- Bluebook : conceive `Person.RegisterDevice` command + `DeviceToken` VO + `PushNotification` aggregate with `Deliver`
- Capacitor side : permission prompt, token registration, dispatch `RegisterDevice`
- Runtime side : Notification aggregate gets policy `DeliverPushOnNotification` that fires on `Notification.Sent`
- APNs + FCM HTTP adapters (new `:push` adapter family with provider discriminator)
- Test : send an Announcement from web admin, parent's phone buzzes within 10s on both iOS and Android

## Sprint 4 (3 days) — TestFlight + Play internal

- Apple Developer account setup (assume Chris has the team) + App Store Connect entry
- Google Play Console entry
- Upload iOS .ipa to TestFlight, Android .aab to Play internal track
- Invite ASA staff + parent beta volunteers via TestFlight email + Play Console allowlist
- One-page install guide in `pigeoncoop/docs/install-mobile.md`

## Sprint 5 (3 days) — Polish + V1 ship gate

- Empty states everywhere on mobile
- Pull-to-refresh on parent / student feeds
- Offline detection + friendly fallback
- Accessibility pass : VoiceOver + TalkBack labels, large-text scaling
- Cut the v1.0 release builds

## Total : 5 sprints × 3 days = 15 working days for v1 mobile

Not blocked on v1 web shipping ; can run in parallel with the calendar / lunch / newsletter sprints. Capacitor sync is incremental — every web sprint that lands also lands on mobile the next `npx cap sync`.

## Compared to the React Native alternative (v2 contingency in i665)

| | Capacitor (v1) | React Native (v2 if needed) |
|---|---|---|
| Sprints | 5 | 6 |
| New components | 0 (reuses web) | All six tab screens |
| UI feel | Web-inside-frame | Native scroll/transitions |
| Update cadence | Instant (web sync) | App store review per release |
| Codebase | Same as web | Separate from web |
| Right when | School-app glance use | Deep native integration needed |
