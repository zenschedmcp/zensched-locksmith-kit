# Example Workflow: What the AI Does Behind Each Request

This shows the exact tool calls the agent makes for a first week of operation, following `SKILL.md`. The owner only types the quoted lines; everything else is the agent's work. Assumes setup from `QUICKSTART.md` is complete (both MCP servers configured, `schema.sql` loaded, `SKILL.md` given as instructions).

The business is **Keyline Mobile Locksmith**, a solo shop (Dana Chen) in Portland, Oregon, Pacific time (`-07:00` in September). IDs and responses are illustrative. ZenSched IDs are integers. Watch what does **not** cross to ZenSched: the customers' names and phone numbers, the gate code, any ID number. ZenSched sees `Call - Elm St`, a street address, `Lockout C-2026-0001`, and a Job Record.

## Session start (every session)

```
sqlite_execute: PRAGMA foreign_keys = ON;
sqlite_query:   SELECT key, value FROM settings;
  → business_name = My Mobile Locksmith, timezone_offset = -05:00, state = NULL,
    default_tech_id = NULL, default_call_minutes = 45,
    default_travel_buffer_minutes = 20, invoice_due_days = 30, invoice_prefix = INV,
    job_form_id = NULL, irs_mileage_rate = 0.70
sqlite_query:   SELECT * FROM open_calls_now;   → (none)
sqlite_query:   SELECT * FROM calls_today;      → (none)
```

## "We're Keyline Mobile Locksmith in Portland, Oregon, Pacific time. It's just me, Dana Chen, dana@keyline.example, 503-555-0100. License OR-LKS-44018, expires 2028-03-31. Set me up."

```
sqlite_execute: UPDATE settings SET value = 'Keyline Mobile Locksmith' WHERE key = 'business_name';
sqlite_execute: UPDATE settings SET value = '-07:00' WHERE key = 'timezone_offset';
sqlite_execute: UPDATE settings SET value = 'OR' WHERE key = 'state';
```

Agent (first metered call this session, rule 11):

> Saved. Since you're the tech on the phone, I need to invite you to ZenSched as a worker so your calls show up in the app; that's a one-time $0.25. If your account isn't funded yet you'll get a prompt for the $5 activation deposit. Go ahead?

Owner: *"yes"*

```
worker_invite:
  email: "dana@keyline.example"
  first_name: "Dana"
  last_name: "Chen"
  idempotency_key: "worker-dana@keyline.example"
  → worker_id: 601, status: "invited", invitation_sent: true
    billing: { meter: "worker_invite", units: 1, price: 0.25 }

sqlite_execute:
  INSERT INTO techs (tech_name, email, phone, zensched_worker_id, is_owner, license_no, license_expires)
  VALUES ('Dana Chen', 'dana@keyline.example', '503-555-0100', 601, 1, 'OR-LKS-44018', '2028-03-31');
  → lastInsertRowid = 1

sqlite_execute: UPDATE settings SET value = '1' WHERE key = 'default_tech_id';
```

The license number stays in `techs.license_no`; ZenSched got a name and an email.

> You're invited; install the app from the email. Next, the Job Record: it's free to create and every call comes back with job type, whether an ID was checked (type only — never a number), lock type, amount, and up to two work photos. No signature pad on it, on purpose. Want me to set it up now?

Owner: *"yes"*

```
form_create:
  title: "Job Record"
  idempotency_key: "form-job-record"
  fields_json: (the JSON below, passed as one string)
```

```json
[
  {"type": "section", "label": "Job record", "identifier": "sec_job", "text": "Complete before you leave. Operational facts only: no customer ID numbers, dates of birth, or copies of IDs. Access codes stay on your computer, not here."},
  {"type": "select", "label": "Job type", "identifier": "job_type", "required": true,
   "options": ["Lockout", "Rekey", "Install", "Auto", "Safe", "Other"]},
  {"type": "select", "label": "ID checked", "identifier": "id_checked", "required": true,
   "options": ["Yes - driver license", "Yes - other government ID", "Personally known", "No", "Not required"]},
  {"type": "textarea", "label": "Lock type", "identifier": "lock_type"},
  {"type": "currency", "label": "Amount charged", "identifier": "amount"},
  {"type": "photo", "label": "Work photos", "identifier": "work", "max_images": 2},
  {"type": "textarea", "label": "Notes for the office", "identifier": "notes"}
]
```

```
  → form_id: 401, fields: [ ...7 fields echoed with identifiers... ]

sqlite_execute: UPDATE settings SET value = '401' WHERE key = 'job_form_id';
```

> Job Record created. I'll attach it to every call automatically. Policy: 150 m radius, 30 minutes of slack so an "I'm here now" punch is accepted, and a 15-minute check-out reminder.

```
policy_update:
  policy_id: 0
  settings_json: "{\"checkin_radius_m\": 150, \"checkin_slack_min\": 30, \"checkout_reminder_min_after\": 15}"
  → policy_id: 0, updated: [ "checkin_radius_m", "checkin_slack_min", "checkout_reminder_min_after" ]
```

## "Cascade Properties wants a rekey tomorrow 10 am at 14 Oak St, Portland 97214, tenant Maya Park, PO 4412, $185. Gate 4471."

The agent parses: client Cascade Properties (property manager), PO `4412`, type rekey, customer Maya Park, address, tomorrow 10:00, fee 185, gate code. No ID number is present; none is stored.

```
sqlite_query: SELECT client_id, payment_terms_days FROM clients WHERE client_name LIKE 'Cascade%';   → (none)

sqlite_execute:
  INSERT INTO clients (client_name, client_type, billing_email, payment_terms_days, default_service_fee, default_trip_fee)
  VALUES ('Cascade Properties', 'property_manager', 'ap@cascade.example', 30, 185, 65);
  → lastInsertRowid = 1
```

> Added Cascade Properties as a property manager, net 30, $185 service / $65 trip default.

```
sqlite_query: SELECT place_id, zensched_location_id, place_label FROM places
              WHERE normalized_address = '14 oak st portland or 97214';   → (none)

sqlite_execute:
  INSERT INTO places (normalized_address, address, city, state, zip, street_name, place_label, access_notes, is_repeat_site)
  VALUES ('14 oak st portland or 97214', '14 Oak St', 'Portland', 'OR', '97214', 'Oak St',
          'Cascade Properties - Portland', 'Gate 4471.', 1);
  → lastInsertRowid = 1

sqlite_execute:
  INSERT INTO calls (client_id, client_order_ref, job_type, customer_name, place_id, scheduled_start, status, service_fee, access_notes)
  VALUES (1, '4412', 'rekey', 'Maya Park', 1, '2026-09-09T10:00', 'confirmed', 185, 'Gate 4471.');
  → lastInsertRowid = 1
  (triggers fill: call_no C-2026-0001, duration_minutes 45, tech_id 1, trip_fee 65, parts_fee 0, after_hours_fee 0, other_fee 0)

sqlite_query: SELECT * FROM calls_open WHERE call_id = 1;
  → C-2026-0001 | 2026-09-09T10:00:00-07:00 | 2026-09-09T10:45:00-07:00
    | Cascade Properties - Portland | Rekey C-2026-0001
    | 14 Oak St, Portland, OR 97214 | needs_location 1 | worker 601
    | loc-place-1 | event-call-1 | shift-call-1
```

> Putting this on ZenSched costs $0.03 to geocode the address; each call then costs about $0.35 in GPS check-in/out and reading the Job Record ($0.38 total for a new address). OK to proceed for this and future calls?

Owner: *"yes"*

```
location_create:
  name: "Cascade Properties - Portland"
  street_address: "14 Oak St, Portland, OR 97214"
  checkin_radius_m: 100
  idempotency_key: "loc-place-1"
  → location_id: 9101, lat: 45.5122, lng: -122.6587, pin_quality: "street",
    billing: { meter: "geocode", units: 1, price: 0.03 }

sqlite_execute: UPDATE places SET zensched_location_id = 9101 WHERE place_id = 1;

event_create:
  location_id: 9101
  title: "Rekey C-2026-0001"
  start_date: "2026-09-09"
  end_date:   "2026-09-09"
  idempotency_key: "event-call-1"
  → event_id: 7101

form_assign:
  form_id: 401
  event_id: 7101
  → status: "assigned", form_id: 401, event_id: 7101, policy_id: 0

shift_create:
  event_id: 7101
  worker_id: 601
  start: "2026-09-09T10:00:00-07:00"
  end:   "2026-09-09T10:45:00-07:00"
  idempotency_key: "shift-call-1"
  → shift_id: 88101, status: "scheduled", forms_installed: [401]

sqlite_execute: UPDATE calls SET zensched_event_id = 7101, zensched_shift_id = 88101 WHERE call_id = 1;
```

Nothing about Maya Park, her phone, or the gate code is in `name`, `title`, or `notes`.

> Booked **C-2026-0001**: rekey, Cascade Properties PO 4412, Wed Sep 9 10:00–10:45 at Oak St. $185, net 30. It's on your phone with the Job Record attached. Maya's name and the gate code are only on your computer.

## "Locked out at 1042 Elm St Portland 97214, Priya Nair 503-555-0142. I'm here now."

Ad hoc. The tech is at the door. Same-session geocode already approved.

```
sqlite_execute:
  INSERT INTO clients (client_name, client_type, payment_terms_days, default_service_fee, default_trip_fee)
  VALUES ('Direct - walk-up', 'homeowner', 0, 185, 65);
  → lastInsertRowid = 2

sqlite_query: SELECT place_id, zensched_location_id FROM places
              WHERE normalized_address = '1042 elm st portland or 97214';   → (none)

sqlite_execute:
  INSERT INTO places (normalized_address, address, city, state, zip, street_name, place_label, is_repeat_site)
  VALUES ('1042 elm st portland or 97214', '1042 Elm St', 'Portland', 'OR', '97214', 'Elm St', 'Call - Elm St', 0);
  → lastInsertRowid = 2

sqlite_execute:
  INSERT INTO calls (client_id, job_type, customer_name, customer_phone, place_id, scheduled_start, is_adhoc, status)
  VALUES (2, 'lockout', 'Priya Nair', '503-555-0142', 2, '2026-09-08T14:41', 1, 'confirmed');
  → lastInsertRowid = 2
  (trigger: C-2026-0002, 45 min, tech 1, fees from Direct defaults)

sqlite_query: SELECT * FROM calls_open WHERE call_id = 2;
  → needs_location 1 | start_iso 2026-09-08T14:41:00-07:00 | end_iso 2026-09-08T15:26:00-07:00
    | Call - Elm St | Lockout C-2026-0002 | loc-place-2 | event-call-2 | shift-call-2

location_create: name "Call - Elm St", street_address "1042 Elm St, Portland, OR 97214",
                 checkin_radius_m 100, idempotency_key "loc-place-2"
  → location_id 9102
sqlite_execute: UPDATE places SET zensched_location_id = 9102 WHERE place_id = 2;
event_create:   location_id 9102, title "Lockout C-2026-0002", start_date "2026-09-08", end_date "2026-09-08",
                idempotency_key "event-call-2"  → event_id 7102
form_assign:    form_id 401, event_id 7102
shift_create:   event_id 7102, worker_id 601, start "2026-09-08T14:41:00-07:00", end "2026-09-08T15:26:00-07:00",
                idempotency_key "shift-call-2"  → shift_id 88102
sqlite_execute: UPDATE calls SET zensched_event_id = 7102, zensched_shift_id = 88102 WHERE call_id = 2;
```

> Window's on your phone: **C-2026-0002**, lockout, 2:41–3:26 pm at Elm St. Check in now.

Dana checks in 14:42 (GPS: 11 m, verified, $0.10). Picks a Schlage deadbolt. Job Record: Job type = Lockout; ID checked = Yes - driver license; Lock type = Schlage residential deadbolt; Amount charged = 185; Work photos = cylinder + door. Check out 15:12 ($0.10). Priya pays $185 cash.

## "Elm is done. $185 cash, 8 miles. Close it out."

```
shift_status: shift_id 88102
  → status "checked_out", actual_in "2026-09-08T14:42:10-07:00", actual_out "2026-09-08T15:12:40-07:00",
    punches: [ { type: "in", gps_verified: true, distance_from_site_m: 11 }, { type: "out", gps_verified: true, distance_from_site_m: 9 } ]
(free)
```

> Reading the Job Record for C-2026-0002 costs $0.15 because it has work photos. It bills once. OK?

Owner: *"go"*

```
form_submissions:
  form_id: 401
  event_id: 7102
  limit: 5
  → submissions: [
      { submission_id: 3402, worker_id: 601, event_id: 7102, submitted_at: "2026-09-08 15:13:00",
        data: { job_type: "lockout", id_checked: "yes___driver_license",
                lock_type: "Schlage residential deadbolt", amount: 185 },
        media: [ { field: "work", cdn_url: "https://cdn.zensched.com/m/.../cyl.jpg" } ] }
    ], count: 1, billing: { meter: "form_media", units: 1, price: 0.15 }

sqlite_execute:
  UPDATE calls
  SET status = 'completed', form_job_type = 'lockout', id_checked = 'yes___driver_license',
      lock_type = 'Schlage residential deadbolt', amount_collected = 185, photo_count = 1,
      job_record_dc_id = 3402,
      checked_in_at = '2026-09-08T14:42:10-07:00', checked_out_at = '2026-09-08T15:12:40-07:00',
      gps_verified = 1, checkin_distance_m = 11
  WHERE call_id = 2;

sqlite_execute:
  INSERT INTO mileage (call_id, trip_date, miles, from_label, to_label, purpose)
  VALUES (2, '2026-09-08', 8, 'Shop', 'Call - Elm St', 'Call C-2026-0002 round trip');
  (trigger: rate 0.70, deduction 5.60)

sqlite_execute:
  INSERT INTO invoices (client_id, invoice_date, due_date, total_amount, line_items)
  SELECT b.client_id, date('now', 'localtime'), date('now', 'localtime', '+0 days'), SUM(b.billable_total),
         json_group_array(json_object('call_no', b.call_no, 'date', b.call_date, 'type', b.job_type,
                                      'status', b.status, 'billable', b.billable_total))
  FROM billable_calls b WHERE b.invoiced = 0 AND b.client_id = 2 AND b.billable_total > 0 GROUP BY b.client_id;
sqlite_execute: UPDATE calls SET invoiced = 1 WHERE invoiced = 0 AND client_id = 2 AND status IN ('completed', 'no_show', 'cancelled');
sqlite_execute: UPDATE invoices SET paid = 1, paid_date = '2026-09-08', sent_date = '2026-09-08' WHERE invoice_id = last_insert_rowid();
  → INV-2026-0001, paid at the door
```

`id_checked` is the option key, not a license number. The work photo stays on ZenSched.

> C-2026-0002 closed: lockout, Schlage deadbolt, ID checked (driver license type only — no number stored), GPS-verified 2:42–3:12 (11 m). $185 cash recorded as INV-2026-0001 paid. 8 miles, $5.60.

## "Marriott Downtown lockout, room they gave me 412, guest Linda Park, now. 520 SW Broadway Portland 97205. Hotel account."

Repeat-site pattern. First visit to this hotel geocodes; the next one will not.

```
sqlite_execute: INSERT INTO clients (client_name, client_type, billing_email, payment_terms_days, default_service_fee)
                VALUES ('Marriott Downtown', 'hotel', 'ap@marriott-pdx.example', 30, 150);   → 3
sqlite_execute: INSERT INTO places (normalized_address, address, city, state, zip, street_name, place_label, access_notes, is_repeat_site)
                VALUES ('520 sw broadway portland or 97205', '520 SW Broadway', 'Portland', 'OR', '97205',
                        'SW Broadway', 'Marriott Downtown - Portland', 'Valet will validate. Ask front desk.', 1);   → 3
sqlite_execute: INSERT INTO calls (client_id, job_type, customer_name, place_id, scheduled_start, is_adhoc, status, access_notes)
                VALUES (3, 'lockout', 'Linda Park', 3, '2026-09-10T19:05', 1, 'confirmed', 'Room 412');   → 3
                (C-2026-0003)

location_create: name "Marriott Downtown - Portland", street_address "520 SW Broadway, Portland, OR 97205",
                 idempotency_key "loc-place-3"  → 9103
event_create / form_assign / shift_create  → event 7103, shift 88103
```

Room 412 is in `calls.access_notes` only. ZenSched sees `Marriott Downtown - Portland` and `Lockout C-2026-0003`.

A second Marriott lockout later the same week:

```
sqlite_query: SELECT place_id, zensched_location_id FROM places
              WHERE normalized_address = '520 sw broadway portland or 97205';
  → place_id 3, zensched_location_id 9103        ← cache hit; no geocode

sqlite_execute: INSERT INTO calls (...)  → C-2026-0004, is_adhoc 1
event_create / form_assign / shift_create on location 9103
```

> Booked **C-2026-0004** at the Marriott. Reused the existing pin, no geocode fee.

## Wednesday: the Oak rekey, and a no-show

Dana does the Oak rekey (check-in 9:52, Job Record: Rekey, ID checked = Personally known, lock type = Kwikset smartkey × 3, amount 185, two photos). Close-out same pattern ($0.15). Then:

## "Auto lockout, Honda Civic, 77 Pine Ct Portland 97202, Kevin Walsh 503-555-0177, 6 pm, AAA ticket 4502-M, $120."

Booked as **C-2026-0005** (`job_type = 'auto'`, client Auto Club / AAA, place `Call - Pine Ct`). Kevin is not there. Dana checks in 17:53 (GPS 9 m), waits, Job Record optional; owner says "nobody there."

```
shift_status: 88105 → in 17:53, out 18:48, gps 9 m
sqlite_execute:
  UPDATE calls SET status = 'no_show',
      checked_in_at = '2026-09-10T17:53:05-07:00', checked_out_at = '2026-09-10T18:48:20-07:00',
      gps_verified = 1, checkin_distance_m = 9,
      notes = 'Waited 55 min. Called customer twice, voicemail. Called AAA 18:15.'
  WHERE call_id = 5;
sqlite_query: SELECT * FROM no_show_evidence WHERE call_id = 5;
  → trip_fee 65 | after_hours_fee 0 | billable_total 65 | 55 min on site
```

> C-2026-0005 recorded as a no-show. Billable: $65 trip to AAA. Note for their portal cites GPS-verified 5:53–6:48 pm, ticket 4502-M, Keyline C-2026-0005. No customer name on the note you send them if you don't want it; they have the ticket.

## Month end: "Invoice Cascade and the Marriott, and tell me who owes me what."

```
sqlite_query: SELECT * FROM receivables_by_client;
  → Cascade Properties | property_manager | net 30 | 1 call | 185.00
    Marriott Downtown  | hotel            | net 30 | 2 calls | 300.00

(invoice INSERT … SELECT per client → INV-2026-0002 Cascade $185 due +30;
 INV-2026-0003 Marriott $300 due +30)
```

> Cascade INV-2026-0002, $185, one line: C-2026-0001 Wed Sep 9 Rekey, PO 4412, $185. Marriott INV-2026-0003, $300. No customer names, phones, addresses, or ID numbers on either; the PO / room ticket identifies the job to them.

## "Mileage for September?"

```
sqlite_query: SELECT * FROM mileage_by_month;
  → 2026-09 | trips | miles | deduction | non_call_miles
```

## Summary of who stored what

| Thing | Where | Why |
|---|---|---|
| Customers' names and phone numbers, gate code, room number | SQLite **only** (`calls.customer_name`, `customer_phone`, `access_notes`, `places.access_notes`) | Customer PII never reaches ZenSched |
| Customer ID numbers, DOBs, ID scans | **Nowhere in this kit** | Job Record stores `id_checked` option key only |
| Dana's license number | SQLite (`techs`) | Local roster |
| Cascade, Marriott, walk-ups: terms, billing email, default fees | SQLite (`clients`) | Billing |
| Each address, normalized, with its ZenSched location id | SQLite (`places`) | De-dup cache; repeat hotels skip the $0.03 geocode |
| `Call - Elm St`, `Marriott Downtown - Portland` and their street addresses and GPS pins | ZenSched (ID in `places`) | Needed for geofenced check-in; labels carry no customer identity |
| One single-day event per call (`Lockout C-2026-0002`, ...) | ZenSched (ID in `calls`) | Shifts hang off events; title is type + number only |
| One shift per call (planned or ad hoc) | ZenSched (ID in `calls`) | Live schedule and push; never copied |
| GPS punches | ZenSched (originals); stamps copied once to `calls` | Proof of arrival, answered from SQLite afterwards |
| The Job Record form | ZenSched (ID in `settings`) | Installed on the phone per shift; no signature field; no ID-number field |
| Fees, invoices, aging, mileage, sub payouts | SQLite | Receivables and tax record |
