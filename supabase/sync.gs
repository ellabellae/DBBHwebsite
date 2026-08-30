/**
 * dBBH Sheet → Supabase sync
 * ──────────────────────────
 * Lives inside the DBBH attendance/roster spreadsheet
 * (Extensions → Apps Script → paste this file).
 *
 * The spreadsheet stays the source of truth. Every form submission,
 * every edit, and a 5-minute timer push the current state of the
 * sheet to Supabase, which the website reads instantly. Website
 * sign-ups flow back into a "Website Sign-Ups" tab here.
 *
 * SETUP (once):
 *  1. Fill in SUPABASE_URL below.
 *  2. Project Settings (gear icon) → Script Properties → add:
 *       SUPABASE_SERVICE_KEY = <service_role key from Supabase
 *       Dashboard → Settings → API>  (NOT the anon key — and never
 *       put this key anywhere public)
 *  3. Run setupTriggers() once from the toolbar (authorize when asked).
 *  4. Run syncAll() once and check the log says ok:true.
 *
 * TAB DETECTION — tabs are recognized by their headers, so you can
 * rename/reorder them freely:
 *   roster      : has "Membership Status" column
 *   sign-ups    : has "Agreement" column
 *   events      : has "Event Name" column
 *   attendance  : has an "Event you attended" column
 *   RSVP tabs   : exactly Timestamp + a NetID column. The event name
 *                 is taken from the TAB NAME — name each RSVP tab
 *                 "RSVP - <exact event name>", e.g. "RSVP - Info Session 1".
 */

var SUPABASE_URL = 'https://texrckvhyiswwiyrbini.supabase.co';

// ── entry points ────────────────────────────────────────────────

function setupTriggers() {
  ScriptApp.getProjectTriggers().forEach(function (t) { ScriptApp.deleteTrigger(t); });
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  ScriptApp.newTrigger('syncAll').forSpreadsheet(ss).onFormSubmit().create();
  ScriptApp.newTrigger('syncAll').forSpreadsheet(ss).onChange().create();
  ScriptApp.newTrigger('syncAll').timeBased().everyMinutes(5).create();
}

function syncAll() {
  var lock = LockService.getScriptLock();
  if (!lock.tryLock(0)) return;                 // a sync is already running
  try {
    var ss = SpreadsheetApp.getActiveSpreadsheet();
    var payload = { roster: [], signups: [], events: [], attendance: [], rsvps: [] };
    var found = { events: false, attendance: false, rsvps: false };

    ss.getSheets().forEach(function (sh) {
      if (sh.getLastRow() < 1 || sh.getName() === 'Website Sign-Ups') return;
      var values = sh.getDataRange().getValues();
      var head = values[0].map(function (h) { return String(h).trim().toLowerCase(); });
      var rows = values.slice(1);
      var col = function (name) { return head.indexOf(name.toLowerCase()); };

      if (col('membership status') !== -1) {
        rows.forEach(function (r) {
          var netid = String(r[col('net id')] || '').trim();
          if (!netid) return;
          payload.roster.push({
            netid: netid,
            name: String(r[col('name')] || ''),
            year: String(r[col('year')] || ''),
            status: String(r[col('membership status')] || ''),
            role: String(col('role') !== -1 ? (r[col('role')] || '') : '')
          });
        });
      } else if (col('agreement') !== -1) {
        rows.forEach(function (r) {
          var email = String(r[col('email')] || '').trim().toLowerCase();
          if (!email) return;
          payload.signups.push({
            netid: email.split('@')[0],
            email: email,
            first: String(r[col('first')] || ''),
            last: String(r[col('last')] || ''),
            year: String(r[col('year')] || ''),
            major: String(r[col('major')] || ''),
            interests: String(r[col('interests')] || ''),
            looking: String(r[col('looking for')] || ''),
            linkedin: String(r[col('linkedin')] || ''),
            notes: String(r[col('notes')] || ''),
            joined: isoDate_(r[col('timestamp')])
          });
        });
      } else if (col('event name') !== -1) {
        found.events = true;
        rows.forEach(function (r) {
          var name = String(r[col('event name')] || '').trim();
          if (!name) return;
          payload.events.push({
            name: name,
            date_iso: isoDate_(r[col('date')]),
            time: String(r[col('time')] || ''),
            venue: String(r[col('venue')] || ''),
            tag: String(col('category') !== -1 ? (r[col('category')] || '') : ''),
            details: String(col('description') !== -1 ? (r[col('description')] || '') : ''),
            rsvp_link: String(col('rsvp form url') !== -1 ? (r[col('rsvp form url')] || '') : '')
          });
        });
      } else if (head.some(function (h) { return h.indexOf('event you attended') !== -1; })) {
        found.attendance = true;
        var evCol = head.findIndex(function (h) { return h.indexOf('event you attended') !== -1; });
        var idCol = head.findIndex(function (h) { return h.indexOf('net id') !== -1 || h.indexOf('netid') !== -1; });
        rows.forEach(function (r) {
          var netid = String(r[idCol] || '').trim();
          if (!netid || !String(r[evCol] || '').trim()) return;
          payload.attendance.push({
            netid: netid,
            event_name: String(r[evCol]).trim(),
            event_date: isoDate_(r[col('timestamp')])
          });
        });
      } else if (head.length >= 2 && col('timestamp') === 0 &&
                 head.some(function (h) { return h.indexOf('netid') !== -1 || h.indexOf('net id') !== -1; })) {
        found.rsvps = true;
        var eventName = sh.getName().replace(/^\s*rsvps?\s*[-–:]\s*/i, '').trim();
        var nCol = head.findIndex(function (h) { return h.indexOf('netid') !== -1 || h.indexOf('net id') !== -1; });
        rows.forEach(function (r) {
          var netid = String(r[nCol] || '').trim();
          if (netid) payload.rsvps.push({ netid: netid, event_name: eventName });
        });
      }
    });

    // A tab that doesn't exist means "leave that table alone" — only a
    // present-but-emptied tab clears its table. Protects against running
    // this script on a copy of the sheet that lacks some tabs.
    ['events', 'attendance', 'rsvps'].forEach(function (k) {
      if (!found[k]) delete payload[k];
    });

    var res = rpc_('sync_from_sheet', { p_data: payload });
    Logger.log(res);
    pullWebsiteSignups_(ss);
  } finally {
    lock.releaseLock();
  }
}

// ── helpers ─────────────────────────────────────────────────────

function isoDate_(v) {
  if (v instanceof Date) return Utilities.formatDate(v, 'America/New_York', 'yyyy-MM-dd');
  var s = String(v || '').trim();
  var m = s.match(/^(\d{1,2})\/(\d{1,2})\/(\d{2,4})/);
  if (!m) return s;
  var y = m[3].length === 2 ? '20' + m[3] : m[3];
  return y + '-' + ('0' + m[1]).slice(-2) + '-' + ('0' + m[2]).slice(-2);
}

function serviceKey_() {
  var k = PropertiesService.getScriptProperties().getProperty('SUPABASE_SERVICE_KEY');
  if (!k) throw new Error('Set SUPABASE_SERVICE_KEY in Script Properties first.');
  return k.replace(/\s+/g, '');   // pasted keys can pick up spaces/newlines anywhere
}

function rpc_(fn, body) {
  var resp = UrlFetchApp.fetch(SUPABASE_URL + '/rest/v1/rpc/' + fn, {
    method: 'post',
    contentType: 'application/json',
    headers: { apikey: serviceKey_(), Authorization: 'Bearer ' + serviceKey_() },
    payload: JSON.stringify(body),
    muteHttpExceptions: true
  });
  if (resp.getResponseCode() >= 300) throw new Error('Supabase ' + resp.getResponseCode() + ': ' + resp.getContentText());
  return resp.getContentText();
}

/** Pull sign-ups submitted on the website into a "Website Sign-Ups" tab. */
function pullWebsiteSignups_(ss) {
  var props = PropertiesService.getScriptProperties();
  var since = props.getProperty('LAST_SIGNUP_PULL') || '1970-01-01T00:00:00Z';
  var resp = UrlFetchApp.fetch(
    SUPABASE_URL + '/rest/v1/signups?select=payload,created_at' +
    '&created_at=gt.' + encodeURIComponent(since) + '&order=created_at.asc',
    { headers: { apikey: serviceKey_(), Authorization: 'Bearer ' + serviceKey_() }, muteHttpExceptions: true });
  if (resp.getResponseCode() >= 300) return;
  var rows = JSON.parse(resp.getContentText());
  if (!rows.length) return;

  var sh = ss.getSheetByName('Website Sign-Ups') ||
           ss.insertSheet('Website Sign-Ups');
  if (sh.getLastRow() === 0) {
    sh.appendRow(['Received', 'Type', 'First', 'Last', 'Email', 'Year', 'Major',
                  'Interests', 'Looking For', 'LinkedIn', 'Notes']);
  }
  rows.forEach(function (r) {
    var p = r.payload || {};
    sh.appendRow([r.created_at, p.update === '1' ? 'profile update' : 'sign-up',
                  p.first || '', p.last || '', p.email || '', p.year || '', p.major || '',
                  p.interests || '', p.looking || '', p.linkedin || '', p.notes || '']);
  });
  props.setProperty('LAST_SIGNUP_PULL', rows[rows.length - 1].created_at);
}
