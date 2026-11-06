import { readFileSync } from "node:fs";
import { HostClient } from "../editor/node_modules/@hecks/client/dist/index.js";
import { v, P, H, Q, HR, UL, OL, IMG, body } from "./lib.mjs";

const HOST = process.env.HOST_URL ?? "http://127.0.0.1:48410";
const pics = JSON.parse(readFileSync(new URL("./pictures.json", import.meta.url))); // name -> {key, alt}
const host = new HostClient({ domain: "Publishing", url: HOST, role: "Editor" });
const now = Math.floor(Date.now() / 1000), day = 86400;

async function run(verb, args, to) {
  const answer = await host.dispatch(verb, args, to);
  const bad = (answer.refusals ?? []).slice(-1)[0];
  if (answer.error || (bad && !(answer.events ?? []).length)) console.log("REFUSED", verb, to ?? "", JSON.stringify(bad ?? answer.error));
  return answer;
}

const img = (name, caption) => IMG(pics[name].key, pics[name].alt, caption);

const POSTS = [
  { slug: "a-year-at-marlow-and-finch", title: "A year at Marlow & Finch", status: "published",
    summary: "What twelve months of a two-person studio taught us.",
    body: body(
      P("A year ago we put two desks together in a former chandler's shop by the harbour and painted the door a colour Isla still calls *\"definitely not green\"*. This is the short version of what happened next."),
      img("harbour-light", "Morning light through the studio window, early spring."),
      H("What we made"),
      P("Eleven identities, four websites, one very long wayfinding project for a ferry terminal, and a **great many** cups of tea."),
      UL("Identities", ["Two for restaurants, both of which opened on time", 1], ["One for a seed library that still has no logo on the van", 1], "Websites", ["A bookshop, a physio clinic, a choir and a bakery", 1], "Signage"),
      H("What we learned"),
      P("Small clients are the best clients, because they answer email. If you are thinking of working with us, [say hello](/contact) and tell us what you are making.\nWe reply the same day, usually with a question.")
    ) },
  { slug: "choosing-a-typeface-for-a-ferry-terminal", title: "Choosing a typeface for a ferry terminal", status: "published",
    summary: "Legibility at thirty metres, in rain, at night.",
    body: body(
      P("Signage is the one place where type design is a safety feature. We spent three weeks looking at letters on a pier in bad weather so that you do not have to."),
      img("type-specimen", "Our shortlist, set at the size the destination boards will use."),
      H("The brief"),
      OL("Readable from thirty metres", "Distinct *l*, *I* and *1* in sodium light", ["No ligatures that fill in when the paint thickens", 1], "Free to license for the council's other buildings"),
      Q("If a tired person with a suitcase can't read it, it isn't finished."),
      P("We settled on a humanist sans with generous counters and a slightly squared **8**. The full write-up, with photographs of the test boards, is on the [Harbour Line case study](/work/harbour-line).")
    ) },
  { slug: "how-we-run-a-two-week-brand-sprint", title: "How we run a two-week brand sprint", status: "published",
    summary: "A fixed fortnight, a fixed price, a finished identity.",
    body: body(
      P("Most identity projects drift. Ours do not, because they are short and the calendar is printed on the wall."),
      H("Week one"),
      UL("Monday: a three-hour conversation and a walk around the client's premises", "Tuesday to Thursday: words first, then marks", ["Ten rough ideas, no colour", 1], ["Three developed, still in black", 1], "Friday: you choose one"),
      H("Week two"),
      P("Colour, type, a few applications, a one-page guide. On the last day we hand over the files and a small printed booklet.\nNothing is hidden in a drawer afterwards."),
      img("workshop-wall", "The wall at the end of a sprint."),
      P("Prices and dates are on the [services page](/services). We take two sprints a month.")
    ) },
  { slug: "notes-on-a-sketchbook-habit", title: "Notes on a sketchbook habit", status: "published",
    summary: "Ten minutes a day, no screens, nothing to show.",
    body: body(
      P("Finch keeps a sketchbook for the thing most people use a notes app for: *half-ideas*. It lives by the kettle."),
      img("sketchbook", "Page 41: a bakery sign, abandoned, then rescued."),
      P("The rules are deliberately dull:"),
      OL("One book at a time", "Date every page", "Never tear a page out", ["Not even the bad ones", 1]),
      P("After a year the bad pages are the ones we learn from. The good ones, as it turns out, were usually good because of a bad one two pages earlier.")
    ) },
  { slug: "a-new-site-for-the-granary-bookshop", title: "A new site for the Granary Bookshop", status: "published",
    summary: "Small shop, large catalogue, one tired spreadsheet.",
    body: body(
      P("The Granary Bookshop had a spreadsheet of nine thousand titles and a website that had not been touched since the owner's daughter built it at sixteen. We kept the charm and replaced almost everything else."),
      H("What changed"),
      UL("Search that forgives bad spelling", "A staff-picks shelf the shop can rearrange in a minute", ["Each pick has a two-line note in the bookseller's own voice", 1], "Click and collect, with a pickup time"),
      P("It went live on a Tuesday. By Thursday the **staff picks** were the most visited page, which pleased everyone except the person who had to write more notes."),
      img("studio-desk", "Final layouts on the studio desk, the day before launch.")
    ) },
  { slug: "why-we-say-no-to-rush-jobs", title: "Why we say no to rush jobs", status: "published",
    summary: "A short, polite explanation.",
    body: body(
      P("We turn down work that has to be finished by Friday and was only mentioned on Wednesday. This is not pride."),
      P("Good identity work needs a night's sleep between the idea and the decision. Take that away and you get *fast*, which is not the same thing as *good*, and often not even cheaper."),
      P("If you do have a hard date, tell us early. We would much rather plan backwards from it.")
    ) },
  { slug: "retiring-our-old-newsletter", title: "Retiring our old newsletter", status: "withdrawn",
    summary: "We took this one down after the move.",
    body: body(
      P("This post announced a quarterly newsletter we have since stopped sending. It has been withdrawn so that nobody signs up to something that no longer exists."),
      P("If you would still like to hear from us, the occasional note on the [journal](/journal) is the best place.")
    ) },
  { slug: "what-goes-in-a-brand-guide", title: "What goes in a brand guide (and what doesn't)", status: "draft",
    summary: "Seven pages is plenty.",
    body: body(
      P("A brand guide is a promise to your future self, written while you still remember why."),
      UL("The mark and its clear space", "Two colours, three at a push", "One typeface family", "Photography: a paragraph, not a policy"),
      P("Everything else is a decoration.")
    ) },
  { slug: "small-studio-pricing-in-the-open", title: "Small-studio pricing, in the open", status: "draft",
    summary: "Our rates, our reasoning and our mistakes.",
    body: body(
      P("Draft: numbers still to be checked with Isla."),
      H("Day rates"),
      P("We charge by the project but think in days. A **day** at the studio is eight hours, a lunch and a proper break.")
    ) },
  { slug: "signage-field-notes-from-the-harbour", title: "Signage field notes from the harbour", status: "published", workingCopy: true,
    summary: "Photographs and half a page of opinions.",
    body: body(
      P("The old signs on the harbour front are wonderful for the wrong reasons: they are hand-painted, slightly crooked and cannot be read in the dark."),
      img("harbour-light", "The harbour front at low tide."),
      P("Our job on the new set is to keep the warmth and lose the crookedness.")
    ),
    draftBody: body(
      P("The old signs on the harbour front are wonderful for the wrong reasons: they are hand-painted, slightly crooked and cannot be read in the dark. That is the problem we were hired to solve."),
      H("Three things we kept"),
      UL("The painted-wood texture, now printed on aluminium", "The deep harbour blue", "Lowercase for the village names"),
      img("harbour-light", "The harbour front at low tide."),
      P("Our job on the new set is to keep the warmth and lose the crookedness.\nWe will show the final boards here once the council has signed off.")
    ) },
  { slug: "summer-opening-hours-and-an-open-studio-day", title: "Summer opening hours and an open studio day", status: "draft", schedule: ["publish", 2.4],
    summary: "Come and see the wall of sketches.",
    body: body(
      P("From June the studio is open on Thursday afternoons, and on the first Saturday of the month we leave the door propped open all day."),
      img("studio-desk", "The studio desk, before we tidy it."),
      P("There will be tea, a table of old proofs to rummage through, and Finch's sketchbooks, supervised.")
    ) },
  { slug: "autumn-case-study-the-choir-site", title: "Autumn case study: the choir site", status: "draft", schedule: ["publish", 5.1],
    summary: "Sixty singers, one calendar, no more group emails.",
    body: body(
      P("The Harbour Voices choir had rehearsals in three halls, a membership list in four places and a rota kept by one very patient treasurer."),
      UL("A single calendar members can subscribe to", "A members' page with the next three pieces and their sheet music", "A treasurer's view that does the sums"),
      P("We will publish the full case study in the autumn.")
    ) },
];

// Offsets that make one published post schedule a withdrawal, too.
const SCHEDULED_WITHDRAW = { slug: "why-we-say-no-to-rush-jobs", inDays: 9.2 };

const PAGES = [
  { slug: "home", title: "Home", body: body(
      H("Identity and websites for people who make things.", 1),
      P("Marlow & Finch is a two-person design studio by the harbour. We make names, marks, signs and small, well-built websites for shops, clinics, choirs and bakeries."),
      img("finch-mark", "The Marlow & Finch mark on a studio door."),
      H("Recent work"),
      UL("Harbour Line ferry terminal: wayfinding and type", "The Granary Bookshop: a new website", "Harbour Voices: a choir that knows where its next rehearsal is"),
      P("Have something in mind? [Tell us about it](/contact).")) },
  { slug: "about", title: "About", body: body(
      H("Two people, one kettle"),
      P("**Isla Marlow** designs. **Tom Finch** builds and keeps the books. We started the studio in a former chandler's shop in the spring of last year, and we still answer the phone."),
      P("We like work that has a reason behind it, and clients who would rather talk about the reason than the font."),
      img("studio-desk", "The studio desk."),
      H("How we work"),
      OL("A conversation, a walk around, and notes", "Words before marks", ["Rough ideas in black and white", 1], "Fixed prices, fixed weeks")) },
  { slug: "contact", title: "Contact", body: body(
      H("Say hello"),
      P("Email [hello@marlowfinch.example](mailto:hello@marlowfinch.example) or call 01234 567 890, Monday to Thursday, nine until five."),
      P("**Studio**\n14 Chandler's Row\nHarborough Quay\nEX1 2AB"),
      P("We reply the same day, usually with a question.")) },
  { slug: "terms", title: "Terms", body: body(
      H("Terms of work"),
      P("These are the short terms we use for every project. If anything is unclear, ask before you sign."),
      OL("A fixed price and a fixed timetable are agreed in writing before work starts.", "Fifty percent is invoiced on starting, the rest on delivery.", ["Invoices are due within fourteen days.", 1], "You own the final files once the last invoice is paid.", "We may show the finished work in our portfolio unless you tell us otherwise."),
      HR(),
      P("*Last updated this spring.*")) },
];

const key = (kind, slug) => `${kind}:${slug}`;
const out = (s) => console.log(s);

for (const p of POSTS) {
  await run("Publishing::Post.Compose", { slug: v(p.slug), title: v(p.title) });
  await run("Documents::Document.Begin", { key: v(key("post", p.slug)), body: p.body });
  await run("Discovery::SearchWording.Describe", { key: v(key("post", p.slug)), title: v(`${p.title} | Marlow & Finch`), description: v(p.summary) });
  if (p.status === "published" || p.status === "withdrawn") await run("Publishing::Post.Publish", {}, p.slug);
  if (p.status === "withdrawn") await run("Publishing::Post.Withdraw", {}, p.slug);
  if (p.workingCopy) await run("Documents::Document.SaveDraft", { draft_body: p.draftBody }, key("post", p.slug));
  if (p.schedule) await run("Schedule::ScheduledAction.Schedule", { id: v(`act-${p.slug}`), subject: v(key("post", p.slug)), action: v(p.schedule[0]), due_at: v(Math.round(now + p.schedule[1] * day)) });
  out(`post ${p.slug} (${p.status}${p.workingCopy ? ", working copy" : ""}${p.schedule ? ", scheduled" : ""})`);
}
await run("Schedule::ScheduledAction.Schedule", { id: v("act-withdraw-rush"), subject: v(key("post", SCHEDULED_WITHDRAW.slug)), action: v("withdraw"), due_at: v(Math.round(now + SCHEDULED_WITHDRAW.inDays * day)) });

for (const pg of PAGES) {
  await run("Publishing::Page.Start", { slug: v(pg.slug), title: v(pg.title) });
  await run("Documents::Document.Begin", { key: v(key("page", pg.slug)), body: pg.body });
  await run("Discovery::SearchWording.Describe", { key: v(key("page", pg.slug)), title: v(`${pg.title} | Marlow & Finch`), description: v(pg.title === "Home" ? "Identity, signage and websites for people who make things." : `${pg.title} at Marlow & Finch.`) });
  out(`page ${pg.slug}`);
}
