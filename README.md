# Duke Business Behind Health — Website

The DBBH site: Home, About, What We Offer, Events & Calendar, Team, and a member login/portal.

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

The anon key is safe to ship in the page: row-level security blocks all direct
table access except published events; the site goes through `member_lookup` /
`member_submit` functions that only return one member's own record.

## Member login
Login is a soft gate: a duke.edu NetID email checked against the `members` table
(`in_roster = true` means registered for the current year). There is no password —
don't put anything sensitive behind it.

## Brand
Cream `#F7F3F0` · Navy `#34586E` · Gold `#C9A020` · Sky `#7BAFD4` · Ice `#CBDBEB` — Cormorant Garamond display / DM Sans body.
