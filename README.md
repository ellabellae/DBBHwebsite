# Duke Business Behind Health — Website

The DBBH site: Home, About, What We Offer, Events & Calendar, Team, and a member login/portal.

<img width="100%" alt="dbbh-website-home" src="https://github.com/user-attachments/assets/9ce83865-cf6d-4fd2-8a12-a9623c21d01a" />

## Structure
- `index.html` — all markup, styles, and scripts (one file, no build step)
- `images/` — site photos (WebP, extracted from the old base64-embedded version)
- `supabase/schema.sql` — database schema + API functions for the Supabase backend
- `supabase/seed/` — roster/events CSVs for the initial import (**gitignored — contains member PII, never commit**)

Deployed on Vercel; pushing to `main` auto-deploys.

## Backend
The member portal (login, membership status, events, sign-ups) talks to a backend
through three adapter functions in `index.html` (`apiLookup`, `apiEvents`, `apiPost`):

- **Supabase (fast, preferred):** set `SUPABASE_URL` and `SUPABASE_ANON_KEY` in the
  CONFIG block of `index.html`.
- **Google Apps Script (legacy fallback):** used automatically while the Supabase
  keys are empty. Slow (2–10s per request) — replace it.

### Supabase setup (one time)
1. Create a free project at [supabase.com](https://supabase.com).
2. SQL Editor → paste and run `supabase/schema.sql`.
3. Table Editor → import `supabase/seed/members.csv` into `members`,
   `events.csv` into `events`, `attendance.csv` into `attendance`.
4. Project Settings → API → copy the **Project URL** and **anon public** key
   into `SUPABASE_URL` / `SUPABASE_ANON_KEY` in `index.html`.
5. Push to `main` — Vercel redeploys, logins go from ~5s to instant.

### Live sync from the Google Sheet (one time)
The attendance/roster spreadsheet stays the source of truth — attendance forms,
RSVP forms, the events tab, and roster/status edits all keep living there.
`supabase/sync.gs` pushes the sheet's state to Supabase on every form
submission, every edit, and every 5 minutes, and pulls website sign-ups back
into a "Website Sign-Ups" tab:

1. Open the spreadsheet → Extensions → Apps Script → paste `supabase/sync.gs`.
2. Set `SUPABASE_URL` at the top of the script.
3. Script Properties → add `SUPABASE_SERVICE_KEY` = the **service_role** key
   (Supabase → Settings → API). This key bypasses security — it only ever
   lives inside the sheet's script, never in the website or this repo.
