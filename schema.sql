-- ZenSched Mobile-Locksmith Local Database Schema
-- SQLite database for clients (property managers, auto clubs, hotels,
-- commercial, homeowners), a cache of job addresses, the tech roster,
-- one-off service calls (planned or "I'm here now"), mileage, client
-- invoices / receivables, and subcontractor payouts.
-- DO NOT duplicate live schedule data from ZenSched (shifts, punches, timesheets).
--
-- HOW TO LOAD THIS FILE
--   Normal path: paste this whole file into your AI chat and say
--   "Create these tables in my locksmith-ops database. Run each statement one at a time."
--   The AI runs each statement through the SQLite MCP tool (sqlite_execute).
--   Most SQLite MCP tools accept ONE statement per call, so every statement
--   below ends with a semicolon and stands alone.
--
--   Alternative (if you have the sqlite3 command-line tool):
--     sqlite3 locksmith-ops.db < schema.sql
--
-- Every statement is idempotent (IF NOT EXISTS / INSERT OR IGNORE), so it is
-- safe to run this file again on an existing database.
--
-- THIS IS NOT A LICENSE, BOND, OR ID-VERIFICATION SYSTEM. Many jurisdictions
-- require a locksmith license and have rules about when you may open a lock
-- (proof of occupancy, photo ID). Nothing here stores customer ID *numbers*,
-- license-plate VIN lookups, or a copy of anyone's ID. The Job Record asks
-- whether an ID was *checked* (type / yes-no), not what the number was.
-- Access notes (gate codes, lockbox) live ONLY in this file.
--
-- PRIVACY: customer names, phones, and access notes live ONLY on your
-- computer: calls.customer_name, calls.customer_phone, calls.access_notes,
-- places.access_notes, techs.license_no. ZenSched receives, per call, a
-- place label ("Call - Elm St" or "Marriott Downtown - Portland"), the
-- street address for the GPS pin, an event title made of the job type and
-- call number ("Lockout C-2026-0001"), and the Job Record (job type, ID
-- checked, lock type, amount, work photos). SKILL.md forbids the agent from
-- putting any local-only column into a ZenSched field. There is no column
-- anywhere in this file for a customer ID number.

-- Foreign keys are OFF by default in SQLite. This must be run once per
-- connection for ON DELETE CASCADE to work. SKILL.md tells the agent to run it
-- at the start of each session.
PRAGMA foreign_keys = ON;

-- Settings: small key/value store so the agent does not have to be re-told the
-- basics every session (timezone, defaults, business name, form id).
CREATE TABLE IF NOT EXISTS settings (
  key TEXT PRIMARY KEY,
  value TEXT
);

INSERT OR IGNORE INTO settings (key, value) VALUES ('business_name', 'My Mobile Locksmith');
INSERT OR IGNORE INTO settings (key, value) VALUES ('timezone_offset', '-05:00');
INSERT OR IGNORE INTO settings (key, value) VALUES ('state', NULL);
INSERT OR IGNORE INTO settings (key, value) VALUES ('default_tech_id', NULL);
INSERT OR IGNORE INTO settings (key, value) VALUES ('default_call_minutes', '45');
INSERT OR IGNORE INTO settings (key, value) VALUES ('default_travel_buffer_minutes', '20');
INSERT OR IGNORE INTO settings (key, value) VALUES ('invoice_due_days', '30');
INSERT OR IGNORE INTO settings (key, value) VALUES ('invoice_prefix', 'INV');
INSERT OR IGNORE INTO settings (key, value) VALUES ('job_form_id', NULL);
INSERT OR IGNORE INTO settings (key, value) VALUES ('irs_mileage_rate', '0.70');

-- Clients: who hires you and who pays you. A property manager, an auto club
-- (AAA / roadside), a hotel, a commercial account, or a walk-up homeowner
-- paying at the door. payment_terms_days drives invoice due dates; the
-- default_* fees are what the agent uses when a dispatch does not state a
-- fee (a trigger copies them onto the call).
CREATE TABLE IF NOT EXISTS clients (
  client_id INTEGER PRIMARY KEY AUTOINCREMENT,
  client_name TEXT NOT NULL,
  client_type TEXT NOT NULL DEFAULT 'homeowner'
    CHECK (client_type IN ('property_manager', 'auto_club', 'hotel', 'commercial', 'homeowner', 'other')),
  contact_name TEXT,                                -- LOCAL ONLY
  contact_phone TEXT,
  billing_email TEXT,
  payment_terms_days INTEGER NOT NULL DEFAULT 30,   -- net 30; homeowner / cash = 0
  default_service_fee REAL,                         -- $ per completed call
  default_trip_fee REAL,                            -- $ when no-show / you rolled and they cancelled
  default_after_hours_fee REAL,                     -- $ nights / weekends
  notes TEXT,
  is_active INTEGER DEFAULT 1,
  created_at TEXT DEFAULT (datetime('now')),
  updated_at TEXT DEFAULT (datetime('now'))
);

-- Places: a cache of job addresses -> ZenSched location ids.
-- Hotels, apartment complexes, and property-manager buildings repeat;
-- residential lockouts usually do not. normalized_address is the de-dup key:
-- the agent builds it as lowercase(address + city + state + zip) with commas,
-- periods, and '#' removed and whitespace collapsed to single spaces (SQLite
-- cannot collapse whitespace, so the agent does it). The agent looks here
-- FIRST and only calls location_create (geocode, $0.03) on a miss. Hand-tuned
-- pins (location_update) therefore survive for repeat sites. place_label is
-- the ONLY name sent to ZenSched for this address. access_notes is LOCAL ONLY.
CREATE TABLE IF NOT EXISTS places (
  place_id INTEGER PRIMARY KEY AUTOINCREMENT,
  normalized_address TEXT NOT NULL UNIQUE,
  address TEXT NOT NULL,
  city TEXT,
  state TEXT,
  zip TEXT,
  street_name TEXT,                                 -- 'Elm St' (no number); used in labels
  place_label TEXT,                                 -- sent to ZenSched: 'Marriott Downtown - Portland', 'Call - Elm St'
  zensched_location_id INTEGER,                     -- from location_create (permanent)
  access_notes TEXT,                                -- LOCAL ONLY: gate code, lockbox, parking, 'unit in rear'
  is_repeat_site INTEGER DEFAULT 0,                 -- 1 = hotel / complex / facility you expect to return to
  created_at TEXT DEFAULT (datetime('now')),
  updated_at TEXT DEFAULT (datetime('now'))
);

-- Techs: in solo mode this is one row (you, is_owner = 1) whose
-- zensched_worker_id came from inviting yourself. In agency mode add a row per
-- subcontracted locksmith with payout_type/payout_value ('flat' = $ per call,
-- 'percent' = % of the billable total). license_no is LOCAL ONLY.
CREATE TABLE IF NOT EXISTS techs (
  tech_id INTEGER PRIMARY KEY AUTOINCREMENT,
  tech_name TEXT NOT NULL,
  email TEXT,
  phone TEXT,
  zensched_worker_id INTEGER UNIQUE,                -- from worker_invite
  is_owner INTEGER DEFAULT 0,                       -- 1 = the business owner (no payouts)
  license_no TEXT,                                  -- LOCAL ONLY
  license_expires TEXT,                             -- ISO date
  payout_type TEXT
    CHECK (payout_type IS NULL OR payout_type IN ('flat', 'percent')),
  payout_value REAL,                                -- $ (flat) or % (percent)
  is_active INTEGER DEFAULT 1,
  notes TEXT,
  created_at TEXT DEFAULT (datetime('now')),
  updated_at TEXT DEFAULT (datetime('now'))
);

-- Calls: THE driving table. One row per service call. Each row maps to
-- exactly one ZenSched event (start_date = end_date = the call date) and one
-- shift (the call window). There is no recurrence. Planned rekeys/installs
-- have a future scheduled_start; "I'm here now" lockouts set scheduled_start
-- = now and is_adhoc = 1, then get a shift immediately.
--
-- scheduled_start is LOCAL wall-clock time as 'YYYY-MM-DDTHH:MM' or
-- 'YYYY-MM-DDTHH:MM:SS' with NO offset and no 'Z'; the views append
-- settings.timezone_offset to produce start_iso / end_iso for shift_create.
--
-- Fees are per-call snapshots. Leave them NULL on insert and the
-- fill_call_defaults trigger copies the client's default_* fees (else 0).
-- Which fees are billable depends on status; see the billable_calls view.
--
-- customer_name, customer_phone, access_notes are LOCAL ONLY and never
-- reach ZenSched. There is no column for a customer ID number.
-- job_type / id_checked / lock_type / amount_collected / photo_count /
-- job_record_dc_id come from the Job Record. checked_in_at / checked_out_at /
-- gps_verified / checkin_distance_m are copied from shift_status once.
CREATE TABLE IF NOT EXISTS calls (
  call_id INTEGER PRIMARY KEY AUTOINCREMENT,
  call_no TEXT UNIQUE,                              -- 'C-2026-0001', filled by trigger if NULL
  client_id INTEGER NOT NULL,
  client_order_ref TEXT,                            -- PO / dispatch ticket / auto-club claim
  job_type TEXT NOT NULL DEFAULT 'lockout'
    CHECK (job_type IN ('lockout', 'rekey', 'install', 'auto', 'safe', 'other')),
  customer_name TEXT,                               -- LOCAL ONLY
  customer_phone TEXT,                              -- LOCAL ONLY
  place_id INTEGER NOT NULL,
  scheduled_start TEXT NOT NULL                     -- local 'YYYY-MM-DDTHH:MM[:SS]', no offset
    CHECK (scheduled_start GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-2][0-9]:[0-5][0-9]*'
           AND scheduled_start NOT GLOB '*T*[+-]*'
           AND scheduled_start NOT GLOB '*Z'),
  duration_minutes INTEGER                          -- NULL -> settings.default_call_minutes
    CHECK (duration_minutes IS NULL OR duration_minutes BETWEEN 15 AND 480),
  tech_id INTEGER,                                  -- NULL -> settings.default_tech_id (trigger)
  is_adhoc INTEGER NOT NULL DEFAULT 0,              -- 1 = "I'm here now"
  status TEXT NOT NULL DEFAULT 'confirmed'
    CHECK (status IN ('requested', 'confirmed', 'completed', 'no_show', 'cancelled', 'rescheduled')),
  service_fee REAL,                                 -- NULL -> client default (trigger)
  trip_fee REAL,
  parts_fee REAL,                                   -- cylinders, keys, hardware; 0 if NULL
  after_hours_fee REAL,
  other_fee REAL,                                   -- late-cancel, extra work
  access_notes TEXT,                                -- LOCAL ONLY: gate code for this visit
  zensched_event_id INTEGER,
  zensched_shift_id INTEGER UNIQUE,
  job_record_dc_id INTEGER,                         -- Job Record submission_id
  checked_in_at TEXT,                               -- from shift_status (ISO with offset)
  checked_out_at TEXT,
  gps_verified INTEGER,                             -- 1 if the check-in punch was on site
  checkin_distance_m INTEGER,
  form_job_type TEXT,                               -- form option key
  id_checked TEXT,                                  -- form option key; NEVER an ID number
  lock_type TEXT,                                   -- from the form
  amount_collected REAL,                            -- from the form currency field
  photo_count INTEGER,
  notes TEXT,
  invoiced INTEGER DEFAULT 0,
  paid_out INTEGER DEFAULT 0,                       -- 1 = sub payout done (agency mode)
  rescheduled_from INTEGER,                         -- previous call_id when this row is the reschedule
  created_at TEXT DEFAULT (datetime('now')),
  updated_at TEXT DEFAULT (datetime('now')),
  FOREIGN KEY (client_id) REFERENCES clients(client_id) ON DELETE CASCADE,
  FOREIGN KEY (place_id) REFERENCES places(place_id) ON DELETE RESTRICT,
  FOREIGN KEY (tech_id) REFERENCES techs(tech_id) ON DELETE SET NULL,
  FOREIGN KEY (rescheduled_from) REFERENCES calls(call_id) ON DELETE SET NULL
);

-- Mileage: one row per trip. call_id is NULL for non-call trips (supply run,
-- locksmith association meeting). rate and deduction are filled by trigger
-- when left NULL (rate from settings.irs_mileage_rate at the time of the trip).
CREATE TABLE IF NOT EXISTS mileage (
  trip_id INTEGER PRIMARY KEY AUTOINCREMENT,
  call_id INTEGER,
  trip_date TEXT NOT NULL,                          -- ISO date
  miles REAL NOT NULL CHECK (miles >= 0),
  from_label TEXT,                                  -- 'Shop', 'Call - Elm St'
  to_label TEXT,
  purpose TEXT,                                     -- 'Call C-2026-0003 round trip'
  rate REAL,                                        -- $/mile snapshot (trigger)
  deduction REAL,                                   -- miles * rate (trigger)
  created_at TEXT DEFAULT (datetime('now')),
  FOREIGN KEY (call_id) REFERENCES calls(call_id) ON DELETE SET NULL
);

-- Invoices: one per client per billing run. invoice_number is filled by trigger
-- if left NULL. due_date is invoice_date + the client's payment_terms_days.
-- line_items is a JSON array with one object per call (call_no, date, type,
-- fee breakdown, shift id) so the invoice can be regenerated.
CREATE TABLE IF NOT EXISTS invoices (
  invoice_id INTEGER PRIMARY KEY AUTOINCREMENT,
  client_id INTEGER NOT NULL,
  invoice_number TEXT UNIQUE,                       -- 'INV-2026-0001'
  invoice_date TEXT NOT NULL,
  due_date TEXT,
  total_amount REAL NOT NULL,
  paid INTEGER DEFAULT 0,
  paid_date TEXT,
  sent_date TEXT,
  line_items TEXT,                                  -- JSON array
  notes TEXT,
  created_at TEXT DEFAULT (datetime('now')),
  FOREIGN KEY (client_id) REFERENCES clients(client_id) ON DELETE CASCADE
);

-- Payouts: what you owe a subcontracted tech for one call (agency mode).
-- One row per call. amount is filled by trigger when left NULL:
-- flat -> techs.payout_value; percent -> billable_total * payout_value / 100.
-- Never insert a payout for the owner row.
CREATE TABLE IF NOT EXISTS payouts (
  payout_id INTEGER PRIMARY KEY AUTOINCREMENT,
  tech_id INTEGER NOT NULL,
  call_id INTEGER NOT NULL UNIQUE,
  amount REAL,                                      -- trigger fills if NULL
  paid INTEGER DEFAULT 0,
  paid_date TEXT,
  notes TEXT,
  created_at TEXT DEFAULT (datetime('now')),
  FOREIGN KEY (tech_id) REFERENCES techs(tech_id) ON DELETE CASCADE,
  FOREIGN KEY (call_id) REFERENCES calls(call_id) ON DELETE CASCADE
);

-- Indexes for common queries
CREATE INDEX IF NOT EXISTS idx_places_location ON places(zensched_location_id);
CREATE INDEX IF NOT EXISTS idx_calls_start ON calls(scheduled_start);
CREATE INDEX IF NOT EXISTS idx_calls_status_start ON calls(status, scheduled_start);
CREATE INDEX IF NOT EXISTS idx_calls_client ON calls(client_id, invoiced);
CREATE INDEX IF NOT EXISTS idx_calls_place ON calls(place_id);
CREATE INDEX IF NOT EXISTS idx_calls_tech ON calls(tech_id, paid_out);
CREATE INDEX IF NOT EXISTS idx_calls_event ON calls(zensched_event_id);
CREATE INDEX IF NOT EXISTS idx_calls_adhoc ON calls(is_adhoc, status);
CREATE INDEX IF NOT EXISTS idx_mileage_date ON mileage(trip_date);
CREATE INDEX IF NOT EXISTS idx_mileage_call ON mileage(call_id);
CREATE INDEX IF NOT EXISTS idx_invoices_client ON invoices(client_id);
CREATE INDEX IF NOT EXISTS idx_invoices_paid ON invoices(paid, due_date);
CREATE INDEX IF NOT EXISTS idx_payouts_tech ON payouts(tech_id, paid);

-- Which fees are billable depends on what happened. This is the single place
-- that rule lives; receivables, invoicing, payouts, and no-show evidence all
-- read billable_total from here rather than re-deriving it.
--   completed  -> service + trip + parts + after_hours + other
--   no_show    -> trip + after_hours                   (you rolled; nothing opened)
--   cancelled  -> other_fee only                       (a late-cancel the agent puts in other_fee)
--   requested / confirmed / rescheduled -> 0
CREATE VIEW IF NOT EXISTS billable_calls AS
SELECT
  c.call_id,
  c.call_no,
  c.client_id,
  c.client_order_ref,
  c.job_type,
  c.status,
  c.is_adhoc,
  date(c.scheduled_start)                          AS call_date,
  c.scheduled_start,
  c.tech_id,
  c.service_fee,
  c.trip_fee,
  c.parts_fee,
  c.after_hours_fee,
  c.other_fee,
  c.amount_collected,
  CASE c.status
    WHEN 'completed' THEN round(COALESCE(c.service_fee, 0) + COALESCE(c.trip_fee, 0) + COALESCE(c.parts_fee, 0) + COALESCE(c.after_hours_fee, 0) + COALESCE(c.other_fee, 0), 2)
    WHEN 'no_show'   THEN round(COALESCE(c.trip_fee, 0) + COALESCE(c.after_hours_fee, 0), 2)
    WHEN 'cancelled' THEN round(COALESCE(c.other_fee, 0), 2)
    ELSE 0
  END                                              AS billable_total,
  c.invoiced,
  c.paid_out,
  c.zensched_shift_id,
  c.job_record_dc_id
FROM calls c;

-- Keep updated_at current
CREATE TRIGGER IF NOT EXISTS update_client_timestamp
AFTER UPDATE ON clients
BEGIN
  UPDATE clients SET updated_at = datetime('now') WHERE client_id = NEW.client_id;
END;

CREATE TRIGGER IF NOT EXISTS update_place_timestamp
AFTER UPDATE ON places
BEGIN
  UPDATE places SET updated_at = datetime('now') WHERE place_id = NEW.place_id;
END;

CREATE TRIGGER IF NOT EXISTS update_tech_timestamp
AFTER UPDATE ON techs
BEGIN
  UPDATE techs SET updated_at = datetime('now') WHERE tech_id = NEW.tech_id;
END;

CREATE TRIGGER IF NOT EXISTS update_call_timestamp
AFTER UPDATE OF client_id, client_order_ref, job_type, customer_name, customer_phone,
                place_id, scheduled_start, duration_minutes, tech_id, is_adhoc, status,
                service_fee, trip_fee, parts_fee, after_hours_fee, other_fee, access_notes,
                zensched_event_id, zensched_shift_id, job_record_dc_id, checked_in_at,
                checked_out_at, gps_verified, checkin_distance_m, form_job_type, id_checked,
                lock_type, amount_collected, photo_count, notes, invoiced, paid_out, rescheduled_from
ON calls
BEGIN
  UPDATE calls SET updated_at = datetime('now') WHERE call_id = NEW.call_id;
END;

-- Auto-number calls: C-2026-0001, C-2026-0002, ... (year of the
-- call, sequence = call_id, so numbers never collide or reset).
CREATE TRIGGER IF NOT EXISTS number_call
AFTER INSERT ON calls
WHEN NEW.call_no IS NULL
BEGIN
  UPDATE calls
  SET call_no = 'C-' || strftime('%Y', NEW.scheduled_start) || '-' || printf('%04d', NEW.call_id)
  WHERE call_id = NEW.call_id;
END;

-- Fill defaults the agent left NULL:
--   duration_minutes <- settings.default_call_minutes (else 45)
--   tech_id          <- settings.default_tech_id (solo mode: you)
--   service/trip/after_hours_fee <- clients.default_*, else 0
--   parts_fee / other_fee <- 0
-- Fees are snapshots: changing a client's defaults later never rewrites history.
CREATE TRIGGER IF NOT EXISTS fill_call_defaults
AFTER INSERT ON calls
BEGIN
  UPDATE calls
  SET duration_minutes = COALESCE(NEW.duration_minutes,
                                  (SELECT CAST(value AS INTEGER) FROM settings WHERE key = 'default_call_minutes'),
                                  45),
      tech_id = COALESCE(NEW.tech_id,
                         (SELECT CAST(value AS INTEGER) FROM settings WHERE key = 'default_tech_id' AND value IS NOT NULL)),
      service_fee = COALESCE(NEW.service_fee, (SELECT default_service_fee FROM clients WHERE client_id = NEW.client_id), 0),
      trip_fee    = COALESCE(NEW.trip_fee,    (SELECT default_trip_fee    FROM clients WHERE client_id = NEW.client_id), 0),
      parts_fee   = COALESCE(NEW.parts_fee, 0),
      after_hours_fee = COALESCE(NEW.after_hours_fee, (SELECT default_after_hours_fee FROM clients WHERE client_id = NEW.client_id), 0),
      other_fee   = COALESCE(NEW.other_fee, 0)
  WHERE call_id = NEW.call_id;
END;

-- Mileage: snapshot the IRS rate and compute the deduction.
CREATE TRIGGER IF NOT EXISTS fill_mileage_deduction
AFTER INSERT ON mileage
BEGIN
  UPDATE mileage
  SET rate = COALESCE(NEW.rate, (SELECT CAST(value AS REAL) FROM settings WHERE key = 'irs_mileage_rate'), 0),
      deduction = round(NEW.miles * COALESCE(NEW.rate, (SELECT CAST(value AS REAL) FROM settings WHERE key = 'irs_mileage_rate'), 0), 2)
  WHERE trip_id = NEW.trip_id;
END;

CREATE TRIGGER IF NOT EXISTS recompute_mileage_deduction
AFTER UPDATE OF miles, rate ON mileage
BEGIN
  UPDATE mileage SET deduction = round(NEW.miles * COALESCE(NEW.rate, 0), 2) WHERE trip_id = NEW.trip_id;
END;

-- Auto-number invoices: INV-2026-0001, INV-2026-0002, ...
CREATE TRIGGER IF NOT EXISTS number_invoice
AFTER INSERT ON invoices
WHEN NEW.invoice_number IS NULL
BEGIN
  UPDATE invoices
  SET invoice_number = (SELECT COALESCE(value, 'INV') FROM settings WHERE key = 'invoice_prefix')
                       || '-' || strftime('%Y', NEW.invoice_date)
                       || '-' || printf('%04d', NEW.invoice_id)
  WHERE invoice_id = NEW.invoice_id;
END;

-- Payout amount from the tech's split when the agent leaves it NULL.
-- flat    -> payout_value
-- percent -> billable_total * payout_value / 100, rounded to cents
-- If the tech has no payout_type the amount stays NULL and payouts_due flags it.
CREATE TRIGGER IF NOT EXISTS fill_payout_amount
AFTER INSERT ON payouts
WHEN NEW.amount IS NULL
BEGIN
  UPDATE payouts
  SET amount = (SELECT CASE t.payout_type
                         WHEN 'flat'    THEN t.payout_value
                         WHEN 'percent' THEN round(b.billable_total * t.payout_value / 100.0, 2)
                       END
                FROM techs t
                JOIN billable_calls b ON b.call_id = NEW.call_id
                WHERE t.tech_id = NEW.tech_id)
  WHERE payout_id = NEW.payout_id;
END;

-- Today's calls (local date of the computer running the database),
-- open statuses only. One row = one call to work. start_iso / end_iso carry
-- settings.timezone_offset and are ready for shift_create. The three
-- idempotency keys and the ZenSched names are ready too.
--   needs_location = 1 -> the place has no ZenSched location yet (location_create)
--   needs_shift    = 1 -> the call has no ZenSched shift yet (event_create + form_assign + shift_create)
CREATE VIEW IF NOT EXISTS calls_today AS
SELECT
  c.call_id,
  c.call_no,
  c.status,
  c.job_type,
  c.is_adhoc,
  c.scheduled_start,
  c.duration_minutes,
  strftime('%Y-%m-%dT%H:%M:%S', c.scheduled_start)
    || (SELECT value FROM settings WHERE key = 'timezone_offset')                 AS start_iso,
  strftime('%Y-%m-%dT%H:%M:%S', datetime(c.scheduled_start, '+' || c.duration_minutes || ' minutes'))
    || (SELECT value FROM settings WHERE key = 'timezone_offset')                 AS end_iso,
  cl.client_id,
  cl.client_name,
  cl.client_type,
  c.client_order_ref,
  c.customer_name,
  c.customer_phone,
  p.place_id,
  p.address,
  p.city,
  p.state,
  p.zip,
  p.street_name,
  p.address || COALESCE(', ' || p.city, '') || COALESCE(', ' || p.state, '') || COALESCE(' ' || p.zip, '') AS street_address,
  COALESCE(p.place_label, 'Call ' || c.call_no)                                    AS zensched_location_name,
  CASE c.job_type
    WHEN 'lockout' THEN 'Lockout'
    WHEN 'rekey'   THEN 'Rekey'
    WHEN 'install' THEN 'Install'
    WHEN 'auto'    THEN 'Auto'
    WHEN 'safe'    THEN 'Safe'
    ELSE 'Locksmith call'
  END || ' ' || c.call_no                                                          AS zensched_event_title,
  p.access_notes                                                                  AS place_access_notes,
  c.access_notes,
  p.is_repeat_site,
  p.zensched_location_id,
  CASE WHEN p.zensched_location_id IS NULL THEN 1 ELSE 0 END                      AS needs_location,
  c.zensched_event_id,
  c.zensched_shift_id,
  CASE WHEN c.zensched_shift_id IS NULL THEN 1 ELSE 0 END                         AS needs_shift,
  c.tech_id,
  t.tech_name,
  t.zensched_worker_id,
  t.phone                                                                         AS tech_phone,
  c.service_fee,
  c.trip_fee,
  c.after_hours_fee,
  c.notes,
  'loc-place-' || p.place_id                                                      AS loc_idempotency_key,
  'event-call-' || c.call_id                                                      AS event_idempotency_key,
  'shift-call-' || c.call_id                                                      AS shift_idempotency_key
FROM calls c
JOIN clients cl ON cl.client_id = c.client_id
JOIN places p ON p.place_id = c.place_id
LEFT JOIN techs t ON t.tech_id = c.tech_id
WHERE c.status IN ('requested', 'confirmed')
  AND date(c.scheduled_start) = date('now', 'localtime')
ORDER BY c.scheduled_start;

-- Same columns, next 7 days (today through today + 6).
CREATE VIEW IF NOT EXISTS calls_upcoming AS
SELECT
  c.call_id,
  c.call_no,
  c.status,
  c.job_type,
  c.is_adhoc,
  c.scheduled_start,
  c.duration_minutes,
  strftime('%Y-%m-%dT%H:%M:%S', c.scheduled_start)
    || (SELECT value FROM settings WHERE key = 'timezone_offset')                 AS start_iso,
  strftime('%Y-%m-%dT%H:%M:%S', datetime(c.scheduled_start, '+' || c.duration_minutes || ' minutes'))
    || (SELECT value FROM settings WHERE key = 'timezone_offset')                 AS end_iso,
  cl.client_id,
  cl.client_name,
  cl.client_type,
  c.client_order_ref,
  c.customer_name,
  c.customer_phone,
  p.place_id,
  p.address,
  p.city,
  p.state,
  p.zip,
  p.street_name,
  p.address || COALESCE(', ' || p.city, '') || COALESCE(', ' || p.state, '') || COALESCE(' ' || p.zip, '') AS street_address,
  COALESCE(p.place_label, 'Call ' || c.call_no)                                    AS zensched_location_name,
  CASE c.job_type
    WHEN 'lockout' THEN 'Lockout'
    WHEN 'rekey'   THEN 'Rekey'
    WHEN 'install' THEN 'Install'
    WHEN 'auto'    THEN 'Auto'
    WHEN 'safe'    THEN 'Safe'
    ELSE 'Locksmith call'
  END || ' ' || c.call_no                                                          AS zensched_event_title,
  p.access_notes                                                                  AS place_access_notes,
  c.access_notes,
  p.is_repeat_site,
  p.zensched_location_id,
  CASE WHEN p.zensched_location_id IS NULL THEN 1 ELSE 0 END                      AS needs_location,
  c.zensched_event_id,
  c.zensched_shift_id,
  CASE WHEN c.zensched_shift_id IS NULL THEN 1 ELSE 0 END                         AS needs_shift,
  c.tech_id,
  t.tech_name,
  t.zensched_worker_id,
  t.phone                                                                         AS tech_phone,
  c.service_fee,
  c.trip_fee,
  c.after_hours_fee,
  c.notes,
  'loc-place-' || p.place_id                                                      AS loc_idempotency_key,
  'event-call-' || c.call_id                                                      AS event_idempotency_key,
  'shift-call-' || c.call_id                                                      AS shift_idempotency_key
FROM calls c
JOIN clients cl ON cl.client_id = c.client_id
JOIN places p ON p.place_id = c.place_id
LEFT JOIN techs t ON t.tech_id = c.tech_id
WHERE c.status IN ('requested', 'confirmed')
  AND date(c.scheduled_start) BETWEEN date('now', 'localtime') AND date('now', 'localtime', '+6 days')
ORDER BY c.scheduled_start;

-- All open calls, any date. Use this after an "I'm here now" insert and for
-- the board beyond the 7-day window. Same columns as calls_upcoming.
CREATE VIEW IF NOT EXISTS calls_open AS
SELECT
  c.call_id,
  c.call_no,
  c.status,
  c.job_type,
  c.is_adhoc,
  c.scheduled_start,
  c.duration_minutes,
  strftime('%Y-%m-%dT%H:%M:%S', c.scheduled_start)
    || (SELECT value FROM settings WHERE key = 'timezone_offset')                 AS start_iso,
  strftime('%Y-%m-%dT%H:%M:%S', datetime(c.scheduled_start, '+' || c.duration_minutes || ' minutes'))
    || (SELECT value FROM settings WHERE key = 'timezone_offset')                 AS end_iso,
  cl.client_id,
  cl.client_name,
  cl.client_type,
  c.client_order_ref,
  c.customer_name,
  c.customer_phone,
  p.place_id,
  p.address,
  p.city,
  p.state,
  p.zip,
  p.street_name,
  p.address || COALESCE(', ' || p.city, '') || COALESCE(', ' || p.state, '') || COALESCE(' ' || p.zip, '') AS street_address,
  COALESCE(p.place_label, 'Call ' || c.call_no)                                    AS zensched_location_name,
  CASE c.job_type
    WHEN 'lockout' THEN 'Lockout'
    WHEN 'rekey'   THEN 'Rekey'
    WHEN 'install' THEN 'Install'
    WHEN 'auto'    THEN 'Auto'
    WHEN 'safe'    THEN 'Safe'
    ELSE 'Locksmith call'
  END || ' ' || c.call_no                                                          AS zensched_event_title,
  p.access_notes                                                                  AS place_access_notes,
  c.access_notes,
  p.is_repeat_site,
  p.zensched_location_id,
  CASE WHEN p.zensched_location_id IS NULL THEN 1 ELSE 0 END                      AS needs_location,
  c.zensched_event_id,
  c.zensched_shift_id,
  CASE WHEN c.zensched_shift_id IS NULL THEN 1 ELSE 0 END                         AS needs_shift,
  c.tech_id,
  t.tech_name,
  t.zensched_worker_id,
  t.phone                                                                         AS tech_phone,
  c.service_fee,
  c.trip_fee,
  c.after_hours_fee,
  c.notes,
  'loc-place-' || p.place_id                                                      AS loc_idempotency_key,
  'event-call-' || c.call_id                                                      AS event_idempotency_key,
  'shift-call-' || c.call_id                                                      AS shift_idempotency_key
FROM calls c
JOIN clients cl ON cl.client_id = c.client_id
JOIN places p ON p.place_id = c.place_id
LEFT JOIN techs t ON t.tech_id = c.tech_id
WHERE c.status IN ('requested', 'confirmed')
ORDER BY c.scheduled_start;

-- Techs checked in with no check-out whose window ended more than 30 minutes
-- ago. A record, not a panic button; pair with a live shift_list(status="checked_in").
CREATE VIEW IF NOT EXISTS open_calls_now AS
SELECT
  c.call_id,
  c.call_no,
  c.job_type,
  c.scheduled_start,
  c.duration_minutes,
  c.checked_in_at,
  c.checked_out_at,
  t.tech_id,
  t.tech_name,
  t.phone                                                                         AS tech_phone,
  p.address || COALESCE(', ' || p.city, '') || COALESCE(', ' || p.state, '') || COALESCE(' ' || p.zip, '') AS street_address,
  c.zensched_shift_id,
  c.customer_name
FROM calls c
JOIN places p ON p.place_id = c.place_id
LEFT JOIN techs t ON t.tech_id = c.tech_id
WHERE c.checked_in_at IS NOT NULL
  AND c.checked_out_at IS NULL
  AND datetime(c.scheduled_start, '+' || COALESCE(c.duration_minutes, 45) || ' minutes')
      <= datetime('now', 'localtime', '-30 minutes')
ORDER BY c.checked_in_at;

-- Uninvoiced billable work grouped by client.
CREATE VIEW IF NOT EXISTS receivables_by_client AS
SELECT
  cl.client_id,
  cl.client_name,
  cl.client_type,
  cl.contact_name,
  cl.billing_email,
  cl.payment_terms_days,
  COUNT(b.call_id)                                 AS call_count,
  SUM(CASE WHEN b.status = 'completed' THEN 1 ELSE 0 END) AS completed_count,
  SUM(CASE WHEN b.status = 'no_show' THEN 1 ELSE 0 END)   AS no_show_count,
  SUM(b.billable_total)                            AS total_billable,
  MIN(b.call_date)                                 AS first_date,
  MAX(b.call_date)                                 AS last_date
FROM billable_calls b
JOIN clients cl ON cl.client_id = b.client_id
WHERE b.invoiced = 0
  AND b.status IN ('completed', 'no_show', 'cancelled')
  AND b.billable_total > 0
GROUP BY cl.client_id
ORDER BY total_billable DESC;

-- Unpaid invoices with aging.
CREATE VIEW IF NOT EXISTS invoices_outstanding AS
SELECT
  i.invoice_id,
  i.invoice_number,
  cl.client_id,
  cl.client_name,
  cl.client_type,
  cl.contact_name,
  cl.billing_email,
  cl.payment_terms_days,
  i.invoice_date,
  i.due_date,
  i.sent_date,
  i.total_amount,
  CAST(julianday(date('now', 'localtime')) - julianday(i.due_date) AS INTEGER) AS days_past_due,
  CASE
    WHEN julianday(date('now', 'localtime')) - julianday(i.due_date) <= 0  THEN 'current'
    WHEN julianday(date('now', 'localtime')) - julianday(i.due_date) <= 30 THEN '30'
    WHEN julianday(date('now', 'localtime')) - julianday(i.due_date) <= 60 THEN '60'
    ELSE '90+'
  END                                              AS aging_bucket,
  CASE WHEN i.due_date < date('now', 'localtime') THEN 1 ELSE 0 END AS overdue
FROM invoices i
JOIN clients cl ON cl.client_id = i.client_id
WHERE i.paid = 0
ORDER BY i.due_date;

CREATE VIEW IF NOT EXISTS mileage_by_month AS
SELECT
  strftime('%Y-%m', m.trip_date)                   AS month,
  COUNT(m.trip_id)                                 AS trips,
  SUM(m.miles)                                     AS miles,
  SUM(m.deduction)                                 AS deduction,
  SUM(CASE WHEN m.call_id IS NULL THEN m.miles ELSE 0 END) AS non_call_miles
FROM mileage m
GROUP BY strftime('%Y-%m', m.trip_date)
ORDER BY month DESC;

-- Agency mode: unpaid sub payouts, one row per call, with a running
-- total per tech (tech_total_due). Owner rows never appear.
CREATE VIEW IF NOT EXISTS payouts_due AS
SELECT
  p.payout_id,
  t.tech_id,
  t.tech_name,
  t.email,
  t.payout_type,
  t.payout_value,
  c.call_id,
  c.call_no,
  date(c.scheduled_start)                          AS call_date,
  c.job_type,
  c.status,
  b.billable_total,
  p.amount,
  CASE WHEN p.amount IS NULL THEN 1 ELSE 0 END     AS needs_amount,
  SUM(p.amount) OVER (PARTITION BY t.tech_id)      AS tech_total_due,
  c.invoiced                                       AS client_invoiced
FROM payouts p
JOIN techs t ON t.tech_id = p.tech_id
JOIN calls c ON c.call_id = p.call_id
JOIN billable_calls b ON b.call_id = c.call_id
WHERE p.paid = 0
  AND t.is_owner = 0
ORDER BY t.tech_name, c.scheduled_start;

CREATE VIEW IF NOT EXISTS payouts_missing AS
SELECT
  c.call_id,
  c.call_no,
  c.status,
  date(c.scheduled_start)                          AS call_date,
  t.tech_id,
  t.tech_name,
  t.payout_type,
  t.payout_value,
  b.billable_total
FROM calls c
JOIN techs t ON t.tech_id = c.tech_id AND t.is_owner = 0
JOIN billable_calls b ON b.call_id = c.call_id
WHERE c.status IN ('completed', 'no_show')
  AND NOT EXISTS (SELECT 1 FROM payouts p WHERE p.call_id = c.call_id)
ORDER BY c.scheduled_start;

-- What the agent cites when chasing a trip fee: every no-show with the
-- ZenSched shift (GPS-verified arrival) and the fee that is owed.
CREATE VIEW IF NOT EXISTS no_show_evidence AS
SELECT
  c.call_id,
  c.call_no,
  cl.client_name,
  cl.client_type,
  cl.billing_email,
  c.client_order_ref,
  c.job_type,
  c.scheduled_start,
  strftime('%Y-%m-%dT%H:%M:%S', c.scheduled_start)
    || (SELECT value FROM settings WHERE key = 'timezone_offset')                 AS start_iso,
  p.address || COALESCE(', ' || p.city, '') || COALESCE(', ' || p.state, '') || COALESCE(' ' || p.zip, '') AS street_address,
  t.tech_name,
  c.zensched_event_id,
  c.zensched_shift_id,
  c.job_record_dc_id,
  c.checked_in_at,
  c.checked_out_at,
  c.gps_verified,
  c.checkin_distance_m,
  CASE WHEN c.checked_in_at IS NOT NULL AND c.checked_out_at IS NOT NULL
       THEN CAST(round((julianday(c.checked_out_at) - julianday(c.checked_in_at)) * 1440.0) AS INTEGER) END AS minutes_on_site,
  c.trip_fee,
  c.after_hours_fee,
  b.billable_total,
  c.invoiced,
  c.notes
FROM calls c
JOIN clients cl ON cl.client_id = c.client_id
JOIN places p ON p.place_id = c.place_id
JOIN billable_calls b ON b.call_id = c.call_id
LEFT JOIN techs t ON t.tech_id = c.tech_id
WHERE c.status = 'no_show'
ORDER BY c.scheduled_start DESC;

-- Last 30 days of completed / no-show work per tech: volume, ad-hoc share, GPS rate.
CREATE VIEW IF NOT EXISTS tech_activity AS
SELECT
  t.tech_id,
  t.tech_name,
  t.is_owner,
  COUNT(c.call_id)                                 AS calls_made,
  SUM(CASE WHEN c.status = 'completed' THEN 1 ELSE 0 END) AS completed_count,
  SUM(CASE WHEN c.status = 'no_show' THEN 1 ELSE 0 END)   AS no_show_count,
  SUM(CASE WHEN c.is_adhoc = 1 THEN 1 ELSE 0 END)         AS adhoc_count,
  CASE WHEN COUNT(c.call_id) = 0 THEN NULL
       ELSE round(100.0 * SUM(CASE WHEN c.gps_verified = 1 THEN 1 ELSE 0 END) / COUNT(c.call_id), 1)
  END                                              AS gps_verified_pct
FROM techs t
LEFT JOIN calls c ON c.tech_id = t.tech_id
  AND c.status IN ('completed', 'no_show')
  AND date(c.scheduled_start) >= date('now', 'localtime', '-30 days')
GROUP BY t.tech_id
ORDER BY t.tech_name;
