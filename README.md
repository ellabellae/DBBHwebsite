# Duke Business Behind Health — Website

The DBBH site: Home, About, What We Offer, Events & Calendar, Team, and a member login/portal.

## Structure
Everything lives in one file — `index.html`. All styles, scripts, and images (base64-embedded) are self-contained, so it runs anywhere with zero build steps. Open it locally in a browser or deploy it as a static site.

## Deploying
- **GitHub Pages:** repo Settings → Pages → Source: `main` branch, `/ (root)` → save. Site goes live at `https://ellabellae.github.io/DBBHwebsite/`.
- **Netlify:** drag `index.html` into a Netlify site, or connect this repo.

## Configuration
- **Sign-up spreadsheet:** in `index.html`, find `SHEET_WEBHOOK_URL = ""` and paste your deployed Google Apps Script Web App URL to send join-form submissions to a Google Sheet. Until then, sign-ups work locally (browser storage) but don't reach the sheet.
- **Member login** is a soft gate (duke.edu email check, stored in the browser) — the portal, alumni database, and career guides sit behind it.

## Brand
Cream `#F7F3F0` · Navy `#34586E` · Gold `#C9A020` · Sky `#7BAFD4` · Ice `#CBDBEB` — Cormorant Garamond display / DM Sans body.
