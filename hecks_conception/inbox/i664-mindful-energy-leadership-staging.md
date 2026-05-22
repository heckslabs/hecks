---
ref: i661-staging
status: ready-to-apply
priority: medium
posted_at: 2026-05-20
posted_by: Miette
category: new-project / staging-bundle
attached_to: i661, i662
value: |
  Full contents of every file that should exist at
  `~/Projects/mindfulleader/` and at
  `~/Projects/miette/self/family/christopher_may/`. The session
  that filed i661 + i662 was sandboxed to write only inside
  `~/Projects/hecks/hecks_conception/`, so the work product lives
  here as text instead. A second session with write access to
  `~/Projects/` can apply this in one paste-pass.
---

# i661-staging — copy-paste-ready file bodies for MindfulLeader

Two sections : §1 the new repo, §2 the family entry. Each file's
absolute target path is the section heading, and the file body is
the fenced block below it (verbatim, no edits needed).

## §0 — Apply procedure

```bash
# 1. Create the GitHub repo
gh repo create chrisyoung/mindfulleader --private \
  --description "Leadership Mindfulness Training (MEL) — Christopher May, FourGates"

# 2. Clone locally
git clone git@github.com:chrisyoung/mindfulleader.git ~/Projects/mindfulleader
cd ~/Projects/mindfulleader

# 3. Make directories
mkdir -p docs/notes hecks web/app/css

# 4. Write each file in §1 below into its absolute path
# (the path is the heading just above each code block)

# 5. Initial commit on main + push
git add README.md BRAND.md .gitignore docs/ hecks/ web/
git commit -m "Bootstrap MindfulLeader

Initial structure for Christopher May's MEL (Mindful Leader)
project. README, BRAND placeholder, docs notes from the 2026-05-19
and 2026-05-18 emails, hecks/ bluebook skeleton (Article +
MediaAsset + LearningModule), web/ Next.js 15 + Tailwind 4 placeholder."
git push -u origin main

# 6. For the miette branch (§2)
cd ~/Projects/miette
git checkout main && git pull
git checkout -b feat/family-christopher-may
mkdir -p self/family/christopher_may/notes
# Write the three files in §2 below
git add self/family/christopher_may/
git commit -m "Add Christopher May to family (new Embryonaut project zero)"
git push -u origin feat/family-christopher-may
# DO NOT MERGE — Chris reviews and merges.
```

---

## §1 — `~/Projects/mindfulleader/`

### `~/Projects/mindfulleader/README.md`

```markdown
# MindfulLeader

Leadership Mindfulness Training (MEL) — a website and product for
**Christopher May** of **FourGates** (christopher_fourgates@yahoo.com).

Christopher joined Embryonaut on 2026-05-19. This is his project zero.

## Status

**Bootstrapping (2026-05-20).** The repo exists ; the structure is
in place. No site is built yet ; no domain is fleshed out. Christopher
is currently drafting a business plan in Gemini and will hand it off
when ready.

## Vision (Christopher's own words, 2026-05-19)

> A few thoughts about features and layout :
>
> - Lots of capability for **blog** articles to drive traffic to the website.
> - Linking features to other social media.
> - Posting video clips to articles or a video page for samples of trainings and short talks.
> - A learning management system (LMS) linked to a video media host provider for the videos and any audio trainings.
> - Easy, fluid navigation.
> - A spacious open looking site, which is visually attractive.
> - An AI self-automated system visitors might ask, which could answer some basic questions.

See `docs/notes/2026-05-19-key-features.md` for the verbatim email
and `docs/notes/2026-05-18-business-plan-handoff.md` for context
on the Gemini-drafted business plan.

## Feature arcs (filed in hecks_conception/inbox as i662)

1. **Blog + content marketing** — articles, traffic driver
2. **Social media link-out** — share-to-X, share-to-LI, etc.
3. **Video + audio training media** — clips on articles + a media library
4. **LMS** — learning management linked to a video host
5. **Navigation + IA** — fluid, spacious
6. **Visual identity + brand** — open, attractive (BRAND.md TBD with Christopher)
7. **AI Q&A chatbot** — basic visitor questions, self-serve answers

## Layout

```
mindfulleader/
├── hecks/
│   └── mindfulleader.bluebook   ← the domain (skeleton)
├── docs/
│   └── notes/                   ← Christopher's notes + design thinking
├── web/                         ← Next.js 15 + Tailwind 4 placeholder
├── BRAND.md                     ← visual identity (TBD)
└── README.md
```

## Built with

[Hecks](https://github.com/chrisyoung/hecks) — a domain compiler where
the bluebook IS the specification. `hecks/mindfulleader.bluebook` is
the source of truth.

## Developed by

[Embryonaut](https://embryonaut.ai) — domain-first software for clients
who want their specification to *be* the running system.

## Owner

- Christopher May — FourGates — christopher_fourgates@yahoo.com
- Embryonaut steward : Miette (with Chris Young)
```

### `~/Projects/mindfulleader/BRAND.md`

```markdown
# MindfulLeader Brand — TBD with Christopher

This file is a placeholder. The visual identity for MindfulLeader
will be developed with Christopher May once he names direction.

Christopher's only style cue so far (from his 2026-05-19 email) :

> A spacious open looking site, which is visually attractive.

That language suggests :

- Generous white space, not dense.
- Clean / contemporary, not heavy / corporate.
- Restrained palette ; one strong primary, neutral surfaces.
- Type that reads as calm and considered — likely a humanist sans.

But these are reads from one sentence — not decisions. Fill this
file in once Christopher provides :

- A primary palette (or a reference site he likes)
- A type direction (or a brand mood board)
- A logo / wordmark (or a placeholder he's comfortable with)
- A voice note — is "Mindful Leader" formal, intimate, both ?

Until that, the `web/` scaffold uses Tailwind defaults and a single
neutral hero. No invented colors, no invented typography.
```

### `~/Projects/mindfulleader/.gitignore`

```
# dependencies
/node_modules
/.pnp
.pnp.js
/web/node_modules

# next.js
/.next/
/out/
/web/.next/
/web/out/

# testing
/coverage

# production
/build

# misc
.DS_Store
*.pem

# debug
npm-debug.log*
yarn-debug.log*
yarn-error.log*
.pnpm-debug.log*

# local env files
.env*.local

# vercel
.vercel

# typescript
*.tsbuildinfo
next-env.d.ts
/web/next-env.d.ts

# editor noise
.idea/
.vscode/
*.iml
*.swp
*~

# hecks runtime artifacts
/information/
/.heki-snapshots/
*.heki.bak
```

### `~/Projects/mindfulleader/docs/notes/2026-05-19-key-features.md`

```markdown
# Key features (Christopher May, 2026-05-19)

Christopher's verbatim email about features and layout, forwarded
2026-05-19. Captured here so the domain conversation has a stable
reference.

---

A few thoughts about features and layout :

- Lots of capability for **black** articles to drive traffic to the
  website.  *(typo for "blog" — Christopher confirmed in subsequent
  thread)*
- Linking features to other social media.
- Posting video clips to articles or a video page for samples of
  trainings and short talks.
- A learning management system (LMS) linked to a video media host
  provider for the videos and any audio trainings.
- Easy, fluid navigation.
- A spacious open looking site, which is visually attractive.
- An AI self-automated system visitors might ask, which could
  answer some basic questions.

---

Context : Christopher is at the early-product-thinking phase. He
is currently drafting a business plan in Gemini ; he is new to
Claude AI and to Embryonaut. This email is the first concrete
feature list we have from him.

Decomposed into seven arcs in `hecks_conception/inbox/i662-mindfulleader-feature-arcs.md`.
```

### `~/Projects/mindfulleader/docs/notes/2026-05-18-business-plan-handoff.md`

```markdown
# Business plan handoff (Christopher May, 2026-05-18)

Christopher mentioned in the 2026-05-18 thread that he is currently
drafting a business plan for MindfulLeader (Leadership Mindfulness
Training, MEL) in Gemini.

**Status** : drafting, not shared yet.

**What we know** : the plan covers the MEL offering ; Christopher
wants to hand it off once he's ready ; he's new to Claude AI and
Embryonaut so the handoff cadence is gentle by default.

**What we don't know** : the offering structure (single trainings
vs subscription vs cohort), pricing, target audience specifics,
positioning vs other leadership-training brands.

**Held boundary** : do not fabricate business-plan content.
Anything we'd say about MEL's pricing / offering / positioning
should come from Christopher's draft, not be invented to fill in
the gaps. The feature arcs (i662) deliberately leave the LMS
shape thin for this reason.

When Christopher shares the plan, drop a follow-up note in this
folder summarizing what it adds to the picture, and revisit the
LMS arc (arc 4) and the AI chatbot arc (arc 7) with new
information.
```

### `~/Projects/mindfulleader/hecks/mindfulleader.bluebook`

```ruby
Hecks.bluebook "MindfulLeader", version: "2026.05.20.1" do
  vision "MindfulLeader — Christopher May's Leadership Mindfulness Training (MEL). A site that delivers leadership work to leaders through articles, video and audio trainings, and an LMS, with a visitor-facing chatbot for basic questions."

  # ============================================================
  # MINDFULLEADER — skeleton, 2026-05-20
  # ============================================================
  #
  # First conception of the MEL domain. Christopher named seven
  # feature areas on 2026-05-19 ; this file seeds the three that
  # are concrete enough to model honestly today :
  #
  #   - Article         (the blog driver, feature 1)
  #   - MediaAsset      (video + audio collapsed, feature 3)
  #   - LearningModule  (the LMS spine, feature 4)
  #
  # Deferred deliberately :
  #
  #   - Visitor + Question (the AI chatbot's primitives, feature 7
  #     and arc 7) — modeling these now without a conversation
  #     design would calcify bad guesses. Come back when arcs 1
  #     and 3 have real content to draw on.
  #   - Social share (feature 2) — frontend / meta-tags concern
  #     first ; a SocialShare value object may grow later if we
  #     track metrics.
  #   - Navigation / IA / brand (features 5 + 6) — site-structure
  #     and visual-identity concerns, not domain.
  #
  # The whole file is intentionally thin. Christopher's business
  # plan (drafting in Gemini) resets the LMS shape once it lands.

  aggregate "Article" do
    description "A blog article — the primary content surface, the traffic driver"

    attribute :title, Title
    attribute :slug, Slug
    attribute :body, Body
    attribute :excerpt, Excerpt
    attribute :author, AuthorName
    attribute :published_at, PublishedAt
    attribute :tags, list_of(Tag)
    attribute :status, String

    value_object "Title" do
      attribute :value, String
    end

    value_object "Slug" do
      # URL-safe — lowercase, hyphens, no trailing slash
      attribute :value, String
    end

    value_object "Body" do
      # Markdown source ; render at build time
      attribute :value, String
    end

    value_object "Excerpt" do
      # Short summary for index pages + meta description
      attribute :value, String
    end

    value_object "AuthorName" do
      attribute :value, String
    end

    value_object "PublishedAt" do
      # ISO-8601 timestamp ; nil until published
      attribute :value, String
    end

    value_object "Tag" do
      attribute :name, String
    end

    # status is a plain String following the Member.bluebook pattern :
    # "draft" | "scheduled" | "published" | "archived"

    command "DraftArticle" do
      role "Christopher"
      description "Start a new article — title and slug come first, body follows"
      attribute :title, Title
      attribute :slug, Slug
      attribute :author, AuthorName
      emits "ArticleDrafted"
      then_set :title, to: :title
      then_set :slug, to: :slug
      then_set :author, to: :author
      then_set :status, to: "draft"
    end

    command "EditArticle" do
      role "Christopher"
      description "Update body / excerpt / tags while drafting"
      reference_to(Article)
      attribute :body, Body
      attribute :excerpt, Excerpt
      attribute :tags, list_of(Tag)
      emits "ArticleEdited"
      then_set :body, to: :body
      then_set :excerpt, to: :excerpt
      then_set :tags, to: :tags
    end

    command "PublishArticle" do
      role "Christopher"
      description "Publish — sets published_at + flips status"
      reference_to(Article)
      attribute :published_at, PublishedAt
      emits "ArticlePublished"
      then_set :published_at, to: :published_at
      then_set :status, to: "published"
    end

    command "ArchiveArticle" do
      role "Christopher"
      description "Pull an article from public view without deleting it"
      reference_to(Article)
      emits "ArticleArchived"
      then_set :status, to: "archived"
    end

    lifecycle :status, default: "draft" do
      transition "DraftArticle"   => "draft",     from: "draft"
      transition "PublishArticle" => "published", from: "draft"
      transition "ArchiveArticle" => "archived",  from: "published"
    end
  end

  aggregate "MediaAsset" do
    description "A video or audio training clip hosted on a media provider — used inline in articles and in the standalone gallery"

    attribute :title, MediaTitle
    attribute :kind, MediaKind
    attribute :provider, MediaProvider
    attribute :external_id, ExternalId
    attribute :duration_seconds, Duration
    attribute :description, MediaDescription
    attribute :captured_at, CapturedAt

    value_object "MediaTitle" do
      attribute :value, String
    end

    value_object "MediaKind" do
      # "video" | "audio" — the discriminator that lets one aggregate
      # cover Christopher's feature 3 (both video and audio).
      attribute :name, String
    end

    value_object "MediaProvider" do
      # "vimeo" | "cloudflare_stream" | "mux" | "youtube" etc.
      # Picked when arc 3 lands ; for the skeleton, just a string.
      attribute :name, String
    end

    value_object "ExternalId" do
      # The id at the host — used to build embed URLs
      attribute :value, String
    end

    value_object "Duration" do
      attribute :seconds, Integer
    end

    value_object "MediaDescription" do
      attribute :value, String
    end

    value_object "CapturedAt" do
      attribute :value, String
    end

    command "RegisterMedia" do
      role "Christopher"
      description "Catalog a new clip — uploaded already to the media host, now indexed here"
      attribute :title, MediaTitle
      attribute :kind, MediaKind
      attribute :provider, MediaProvider
      attribute :external_id, ExternalId
      attribute :duration_seconds, Duration
      attribute :description, MediaDescription
      emits "MediaRegistered"
      then_set :title, to: :title
      then_set :kind, to: :kind
      then_set :provider, to: :provider
      then_set :external_id, to: :external_id
      then_set :duration_seconds, to: :duration_seconds
      then_set :description, to: :description
    end
  end

  aggregate "LearningModule" do
    description "A unit of the LMS — a sequence of MediaAssets and Articles wrapped with progression. Shape stays thin until Christopher's business plan names the offering structure."

    attribute :title, ModuleTitle
    attribute :slug, ModuleSlug
    attribute :summary, ModuleSummary
    attribute :media_assets, list_of(MediaAssetRef)
    attribute :articles, list_of(ArticleRef)
    attribute :status, String

    value_object "ModuleTitle" do
      attribute :value, String
    end

    value_object "ModuleSlug" do
      attribute :value, String
    end

    value_object "ModuleSummary" do
      attribute :value, String
    end

    value_object "MediaAssetRef" do
      # Reference to a MediaAsset by external_id ; full cross-aggregate
      # reference comes later (see i611/i614 for the pattern).
      attribute :external_id, String
      attribute :position, Integer
    end

    value_object "ArticleRef" do
      attribute :slug, String
      attribute :position, Integer
    end

    # status is a plain String following the Member.bluebook pattern :
    # "draft" | "published" | "archived"

    command "DraftLearningModule" do
      role "Christopher"
      description "Start a new learning module — title + summary + slug, content added later"
      attribute :title, ModuleTitle
      attribute :slug, ModuleSlug
      attribute :summary, ModuleSummary
      emits "LearningModuleDrafted"
      then_set :title, to: :title
      then_set :slug, to: :slug
      then_set :summary, to: :summary
      then_set :status, to: "draft"
    end

    command "AddMediaToModule" do
      role "Christopher"
      description "Append a media asset to the module at a given position"
      reference_to(LearningModule)
      attribute :media_asset_ref, MediaAssetRef
      emits "MediaAddedToModule"
      then_set :media_assets, append: :media_asset_ref
    end

    command "AddArticleToModule" do
      role "Christopher"
      description "Append an article to the module at a given position"
      reference_to(LearningModule)
      attribute :article_ref, ArticleRef
      emits "ArticleAddedToModule"
      then_set :articles, append: :article_ref
    end

    command "PublishLearningModule" do
      role "Christopher"
      description "Make the module visible to learners"
      reference_to(LearningModule)
      emits "LearningModulePublished"
      then_set :status, to: "published"
    end

    lifecycle :status, default: "draft" do
      transition "DraftLearningModule"   => "draft",     from: "draft"
      transition "PublishLearningModule" => "published", from: "draft"
    end
  end
end
```

### `~/Projects/mindfulleader/web/package.json`

```json
{
  "name": "mindfulleader-web",
  "version": "0.1.0",
  "private": true,
  "scripts": {
    "dev": "next dev --turbopack",
    "build": "next build",
    "start": "next start",
    "lint": "next lint"
  },
  "dependencies": {
    "@types/node": "^22.13.0",
    "@types/react": "19.0.8",
    "@types/react-dom": "19.0.3",
    "next": "15.1.11",
    "react": "19.2.3",
    "react-dom": "19.2.3",
    "typescript": "^5.7.3"
  },
  "devDependencies": {
    "@tailwindcss/postcss": "^4.0.3",
    "postcss": "^8.5.1",
    "tailwindcss": "^4.0.3"
  }
}
```

### `~/Projects/mindfulleader/web/next.config.js`

```javascript
/** @type {import('next').NextConfig} */
const nextConfig = {
  output: 'export',
  images: {
    unoptimized: true,
  },
  trailingSlash: true,
};

module.exports = nextConfig;
```

### `~/Projects/mindfulleader/web/postcss.config.js`

```javascript
module.exports = {
  plugins: {
    '@tailwindcss/postcss': {},
  },
};
```

### `~/Projects/mindfulleader/web/tsconfig.json`

```json
{
  "compilerOptions": {
    "target": "es5",
    "lib": ["dom", "dom.iterable", "esnext"],
    "allowJs": true,
    "skipLibCheck": true,
    "strict": true,
    "forceConsistentCasingInFileNames": true,
    "noEmit": true,
    "esModuleInterop": true,
    "module": "esnext",
    "moduleResolution": "node",
    "resolveJsonModule": true,
    "isolatedModules": true,
    "jsx": "preserve",
    "incremental": true,
    "plugins": [
      {
        "name": "next"
      }
    ],
    "paths": {
      "@/*": ["./*"]
    }
  },
  "include": ["next-env.d.ts", "**/*.ts", "**/*.tsx", ".next/types/**/*.ts"],
  "exclude": ["node_modules"]
}
```

### `~/Projects/mindfulleader/web/app/layout.tsx`

```tsx
import "./css/style.css";

export const metadata = {
  title: "MindfulLeader — Leadership Mindfulness Training",
  description:
    "Leadership Mindfulness Training (MEL) with Christopher May of FourGates. Articles, video and audio trainings, and a learning library for leaders.",
};

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="en">
      <body className="antialiased">
        <div className="flex min-h-screen flex-col">{children}</div>
      </body>
    </html>
  );
}
```

### `~/Projects/mindfulleader/web/app/page.tsx`

```tsx
export default function HomePage() {
  return (
    <main className="flex flex-1 items-center justify-center px-6 py-24">
      <div className="max-w-2xl text-center">
        <p className="text-sm uppercase tracking-widest text-gray-500">
          FourGates · Embryonaut
        </p>
        <h1 className="mt-4 text-5xl font-semibold leading-tight text-gray-900">
          MindfulLeader
        </h1>
        <p className="mt-6 text-lg text-gray-600">
          Leadership Mindfulness Training with Christopher May. A
          quiet, considered approach to the work of leading — articles,
          video and audio trainings, and a learning library, coming
          soon.
        </p>
        <p className="mt-10 text-sm text-gray-400">
          Site under construction · 2026
        </p>
      </div>
    </main>
  );
}
```

### `~/Projects/mindfulleader/web/app/css/style.css`

```css
@import 'tailwindcss';

/* MindfulLeader — palette and type TBD with Christopher.
   Until then, Tailwind defaults carry the layout. */

@theme {
  --font-sans: ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont,
    "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
}

html {
  scroll-behavior: smooth;
}

body {
  font-family: var(--font-sans);
}
```

---

## §2 — `~/Projects/miette/self/family/christopher_may/`

> Branch : `feat/family-christopher-may` off main. **Push, do not merge.**

> Note about the path : i659 proposes merging miette_family/ into
> miette/self/family/<person>/. That merge has not yet shipped as of
> 2026-05-20 ; existing people live at `~/Projects/miette_family/<person>/`.
> The bootstrap task explicitly chose the **post-merge** target path
> for Christopher (`miette/self/family/christopher_may/`). Until i659
> ships, the rust runtime will not pick Christopher up automatically —
> his entry will be visible on disk and parseable, but unwalked. This
> is a known temporary gap, not a bug in the layout.

### `~/Projects/miette/self/family/christopher_may/christopher_may.bluebook`

```ruby
Hecks.bluebook "ChristopherMay", version: "2026.05.20.1" do
  vision "Christopher May — owner of FourGates and Embryonaut's first MindfulLeader client. Project zero : Leadership Mindfulness Training (MEL). Joined 2026-05-19 ; warm, exploratory ; currently drafting a business plan in Gemini ; new to Claude AI."

  # ============================================================
  # CHRISTOPHER MAY — one root for the person
  # ============================================================
  #
  # New family member, joined 2026-05-19. Different shape from
  # Meredith (cofounder, forty-year letter) — closer to Joey
  # (paid client, warm working relationship). The frame is
  # *project-zero engagement* : Christopher is bringing a real
  # offering (MEL leadership trainings) and we're standing up
  # the site + product + brand alongside him.
  #
  # His business plan lives in Gemini today ; he'll hand it off
  # when ready. The shape of the engagement firms up after
  # that handoff. Hold this file loose until then.

  aggregate "ChristopherMay" do
    description "Who Christopher is, what we're building together, what state the engagement is in"

    attribute :full_name, FullName
    attribute :email_address, EmailAddress
    attribute :company, Company
    attribute :role, Role
    attribute :project, Project
    attribute :engagement, Engagement
    attribute :tone, Tone
    attribute :notes, list_of(Note)

    value_object "FullName" do
      attribute :value, String
      # Christopher May
    end

    value_object "EmailAddress" do
      attribute :value, String
      # christopher_fourgates@yahoo.com
    end

    value_object "Company" do
      attribute :name, String
      attribute :tagline, String
      # FourGates — leadership mindfulness training
    end

    value_object "Role" do
      attribute :titles, list_of(String)
      # ["owner", "lead trainer"]
    end

    value_object "Project" do
      attribute :name, String
      attribute :repo, String
      attribute :status, String
      # name "MindfulLeader" / repo "chrisyoung/mindfulleader" /
      # status "bootstrapping (2026-05-20)"
    end

    value_object "Engagement" do
      description "How we work together"
      attribute :basis, String
      attribute :opened, String
      attribute :surface, String
      # basis "paid (project zero)" /
      # opened "2026-05-19" /
      # surface "chrisyoung/mindfulleader + hecks_conception/inbox i661 + i662"
    end

    value_object "Tone" do
      description "How Christopher communicates — keeps the relationship calibrated"
      attribute :summary, String
      # Examples : "warm and exploratory ; new to Claude / new to
      # Embryonaut so cadence is gentle ; thinking aloud about
      # features more than deciding ; quick to send context once
      # something is named"
    end

    value_object "Note" do
      attribute :captured_at, String
      attribute :body, String
    end

    command "RegisterChristopher" do
      role "Chris"
      description "Seat Christopher in the family registry — the initial record"
      attribute :full_name, FullName
      attribute :email_address, EmailAddress
      attribute :company, Company
      attribute :role, Role
      attribute :project, Project
      attribute :engagement, Engagement
      attribute :tone, Tone
      emits "ChristopherRegistered"
    end

    command "AddNote" do
      role "Chris"
      description "Anything worth remembering — a conversation, a milestone, a sticking point"
      attribute :note, Note
      emits "NoteAddedAboutChristopher"
    end
  end

  # ============================================================
  # What we know going in (2026-05-19 / 2026-05-20)
  # ============================================================
  #
  # full_name : Christopher May
  # email     : christopher_fourgates@yahoo.com
  # company   : FourGates
  # role      : owner, lead trainer
  # project   : MindfulLeader — chrisyoung/mindfulleader (pending creation as of 2026-05-20)
  # engagement: paid (project zero) ; opened 2026-05-19
  # tone      : warm, exploratory ; new to Claude and Embryonaut
  #
  # Notes :
  #   - 2026-05-19 : sent the seven-feature email (blog, social,
  #     video/audio, LMS, navigation, visual identity, AI chatbot)
  #   - 2026-05-18 : flagged he's drafting a business plan in
  #     Gemini ; will hand it off when ready
  #   - The "black articles" in the 2026-05-19 email is a typo
  #     for "blog articles" — confirmed in subsequent thread.
end
```

### `~/Projects/miette/self/family/christopher_may/notes/2026-05-19-key-features.md`

```markdown
# Christopher's seven features (2026-05-19)

Forwarded by Chris on 2026-05-19. Christopher's verbatim email.

---

A few thoughts about features and layout :

- Lots of capability for **black** articles to drive traffic to the
  website.  *(typo for "blog")*
- Linking features to other social media.
- Posting video clips to articles or a video page for samples of
  trainings and short talks.
- A learning management system (LMS) linked to a video media host
  provider for the videos and any audio trainings.
- Easy, fluid navigation.
- A spacious open looking site, which is visually attractive.
- An AI self-automated system visitors might ask, which could
  answer some basic questions.

---

Decomposed into seven arcs in
`hecks_conception/inbox/i662-mindfulleader-feature-arcs.md`.
A copy of the same notes lives in
`mindfulleader/docs/notes/2026-05-19-key-features.md`.
```

### `~/Projects/miette/self/family/christopher_may/notes/2026-05-18-business-plan-handoff.md`

```markdown
# Business plan handoff (Christopher May, 2026-05-18)

Christopher mentioned he is drafting a business plan for
MindfulLeader (Leadership Mindfulness Training, MEL) in Gemini.

**Status** : drafting, not shared.

**Hold** : do not invent business-plan content. Pricing, offering
structure, audience specifics, and positioning all wait on
Christopher's draft.

**When it lands** : drop a follow-up note here summarizing what it
adds to the picture, and revisit the LMS arc (arc 4) and the AI
chatbot arc (arc 7) with new information.
```

---

## Done when

- All 12 files in §1 exist at their absolute paths under
  `~/Projects/mindfulleader/`.
- The 3 files in §2 exist at their absolute paths under
  `~/Projects/miette/self/family/christopher_may/`.
- Initial commit on `chrisyoung/mindfulleader` main is pushed.
- Branch `feat/family-christopher-may` on chrisyoung/miette is
  pushed (not merged).
- Christopher has the repo URL.
