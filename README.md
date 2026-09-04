# ZenSched Mobile-Locksmith Reference Kit

A copy-pasteable setup for a solo mobile locksmith, or a 2–5 tech shop that dispatches subcontracted locksmiths, that wants an AI assistant to run call intake (planned rekeys and emergency lockouts), GPS-verified arrival at each address, a Job Record with work photos, mileage, receivables from property managers and auto clubs, and sub payouts. ZenSched handles the phone app, the GPS check-in at each job address, the one-off event and shift per call, and the Job Record. A small local database on your computer holds your clients, the addresses you have been to, your calls (with the customers' names and phone numbers), mileage, invoices, and payouts.

**You do not need to know how to program or write SQL to use this.** You paste a work order into your AI assistant ("Cascade just sent this, book it"), text it "I'm at the Civic lockout now", ask "what's today", "was I on time at the Oak rekey", "close out today", "invoice Cascade", "who owes me money", "mileage for September", and the AI does the work using two tools you set up once. Setup takes about 15 minutes and is the only technical part.

If you *are* a developer, skip to [For developers](#for-developers).

## This is not a license, bond, or ID-verification system — read this first

**What this kit is:** a way for a locksmith to get every call onto their phone (booked ahead, or opened on the spot when they are already at the door), prove GPS-verified arrival, record what happened (job type, whether an ID was checked, lock type, amount, work photos), and turn those records into invoices, receivables follow-up, mileage totals, and sub payouts, with an AI assistant doing the clerical work.

**What it is not:**

- **It does not store customer ID numbers, and it does not verify identity.** Many jurisdictions require you to check photo ID before opening a residential lock. The Job Record asks *whether* an ID was checked (driver license / other government ID / personally known / no / not required). It never asks for the number. There is no column in the local database for an ID number, a date of birth, or a scan of an ID. If your board wants those on a paper ticket, keep using the paper ticket.
- **It is not your locksmith license, bond, or insurance.** Commission and license numbers for *you* live in the local roster only and never leave your computer.
- **It is not ServiceTitan, a POS, or an inventory system.** No parts catalog, no marketing, no customer portal. Invoices are plain text you paste into email.
- **ZenSched never receives customer information.** Customer names, phone numbers, and gate / lockbox codes live only in the local database. ZenSched sees a place label (`Marriott Downtown - Portland`, or `Call - Elm St`), the street address for the GPS pin, an event title made of the job type and your call number (`Lockout C-2026-0001`), and the Job Record. You are still responsible for your own privacy obligations; this kit narrows what a third party sees, it does not make you compliant by itself.
- **No signature on the Job Record.** On ZenSched a signature field replaces the Submit button, and a signature on an ops form invites confusion with a work-authorization or contract.

If any of that is a deal-breaker, this kit is not for you. If you want a phone schedule with GPS proof of arrival, a clean close-out per call, and receivables you can actually chase, read on.

## What lives where

**ZenSched (source of truth for where you were and when):**

- Locations (one per job address, cached locally so repeat hotels and complexes are created once; the check-in radius is a policy setting)
- Workers (you, in solo mode; you plus your subs in agency mode, each with the mobile app)
- Events (one single-day event per call)
- Shifts (one per call: the job window, 45 minutes by default, planned or opened on the spot, with a push notification to the tech)
- GPS punches (check-in / check-out with distance-from-the-pin verification)
- The Job Record form (job type, ID checked, lock type, amount, work photos, notes) and every submission

**Local SQLite database (`locksmith-ops.db`, on your computer):**

- Clients: property managers, auto clubs, hotels, commercial accounts, homeowners, with payment terms and default fees
- Places: every address you have been sent to, normalized, with its ZenSched location id and access notes (gate code, lockbox, parking) — **access notes never leave your computer**
- Techs: you (and your subs), license number and expiry — **never leave your computer**; payout split per sub
- Calls: order / PO, job type, customer name and phone (**never leave your computer**), place, time, fees, outcome, the ZenSched event/shift/submission ids, GPS arrival stamps copied once
- Mileage with the IRS rate snapshot and deduction
- Invoices per client with aging; payouts per sub per call
- Your settings (timezone, state, default tech, default call length, invoice terms and prefix, mileage rate, Job Record form id)

**Never duplicated:** the live schedule, punches, and work photos stay in ZenSched. The local database stores *references* to them plus the few facts you need to answer "was I on time", "who owes me", and "what did Marcus do" without paying to re-read records.

### Privacy note

Everything that identifies a customer lives only in the local database: `calls.customer_name`, `customer_phone`, `access_notes`, and `places.access_notes`. `SKILL.md` forbids the AI from putting any of them into any ZenSched field, including location names, event titles, notes, and cancellation reasons (subs see those). Customer ID numbers, dates of birth, and ID scans are not stored anywhere in this kit. The Job Record form itself tells the tech not to write them in it. Your license number is in the local roster only.

## How it works day to day

Your AI assistant has two sets of tools:

1. **ZenSched tools** (`location_create`, `event_create`, `shift_create`, `shift_status`, `form_submissions`, ...) that talk to ZenSched over the internet.
2. **A SQLite tool** (`sqlite_query`, `sqlite_execute`) that reads and writes `locksmith-ops.db` on your computer.

When you paste a work order, the AI extracts the client, PO, job type, customer, address, time, and fees; adds the client if new; looks the address up in your `places` cache (a hotel you have been to before is reused, a new address is geocoded once); saves the call with a number like `C-2026-0001`; creates a single-day event and a shift on ZenSched with the Job Record attached; and confirms in one line. You see the call on your phone, check in at the door (GPS-verified), do the work, fill in the Job Record, check out.

When someone is locked out and you are already there, you text "I'm here now." The AI inserts an ad-hoc call with `scheduled_start` = now and `shift_create`s a window starting now. The 30-minute check-in slack is what lets the punch go through even if the window opened a minute after you parked. That is the kit's answer to a platform gap: ZenSched has no "check in now at location X" without a shift, so the agent creates the shift. It is one round-trip, not zero.

In the evening you say "close out today" and the AI pulls your verified arrival times and the records, updates each call, asks for miles, and tells you what is now receivable. "Invoice Cascade" produces a plain-text invoice under their terms; "who owes me money" ages what is open; "mileage for September" totals the month. In agency mode, "what do I owe Marcus" lists his split per call. You never run SQL yourself. `SKILL.md` in this repo is the instruction sheet that teaches the AI how to do all of this; you paste it into your AI tool once.

## Setup

### 0. What you need

- **An AI tool that supports MCP.** These instructions use Claude Desktop (Windows or Mac). Cursor works too.
- **Node.js 20 or newer.** The SQLite tool runs on it. Download the LTS installer from [nodejs.org](https://nodejs.org/) and run it with the defaults. This is the only software install.
- You do **not** need the `sqlite3` command-line program, Python, or Git.

### 1. Make a folder for your data

Create a folder where the database will live and write down its full path. Examples:

- Windows: `C:\Users\YourName\locksmith-ops`
- Mac: `/Users/yourname/locksmith-ops`

The database file will be created automatically inside this folder the first time the AI uses it. This folder will contain customer names and phone numbers; keep it on an encrypted, backed-up disk, not in a shared folder.

### 2. Add both tools to your AI's config file

Open the MCP configuration file for your AI tool:

- **Claude Desktop, Windows:** `%APPDATA%\Claude\claude_desktop_config.json` (paste that into the File Explorer address bar)
- **Claude Desktop, Mac:** `~/Library/Application Support/Claude/claude_desktop_config.json` (in Claude Desktop: Settings → Developer → Edit Config)
- **Cursor:** Settings → MCP → Add new global MCP server

Paste in the contents of `mcp.json.example` from this repo, then change one line, the `SQLITE_PATH`, to point at your folder from step 1 plus `\locksmith-ops.db` (Windows) or `/locksmith-ops.db` (Mac):

```json
{
  "mcpServers": {
    "zensched": {
      "url": "https://mcp.zensched.com/mcp",
      "headers": { "Authorization": "Bearer zsc_your_key_here" }
    },
    "locksmith-ops-db": {
      "command": "npx",
      "args": ["-y", "easy-sqlite-mcp"],
      "env": { "SQLITE_PATH": "/Users/yourname/locksmith-ops/locksmith-ops.db" }
    }
  }
}
```

**Windows path gotcha:** inside a JSON file every backslash must be doubled. Write `"C:\\Users\\YourName\\locksmith-ops\\locksmith-ops.db"`, not `"C:\Users\..."`. A single backslash will silently break the config.

**Leave `zsc_your_key_here` exactly as it is for now.** You do not have a key yet. The ZenSched tools that create your account work without one, and you will fill this in during step 3.

Save the file and **fully quit and reopen** your AI tool (on Mac, Cmd-Q; on Windows, right-click the tray icon → Quit). It only reads this file on startup.

### 3. Create your ZenSched account

In a new chat, type:

> Call `zensched_guide`, then call `account_create` with org_name "My Mobile Locksmith" (use my real business name if I told you one). Show me the `zsc_` key it returns.

Copy the `zsc_` key. Go back to the config file from step 2, replace `zsc_your_key_here` with your real key, save, and fully quit and reopen the AI tool again.

Some clients can adopt the key mid-session with `account_use_key`; you can ask the AI to try that to keep going immediately, but still update the config file so the key survives restarts. Keep the key private; it is the password to your account.

### 4. Create the database tables

Open `schema.sql` from this repo in any text editor, copy the whole thing, and paste it into the chat with this message in front of it:

> Create these tables in my locksmith-ops database. Run each statement one at a time using the SQLite tool, then list the tables to confirm.

The AI will run 54 statements and confirm the tables exist. The `locksmith-ops.db` file now exists in your folder with default settings (45-minute calls, net 30, $0.70/mile) you can change.

If you happen to have the `sqlite3` command-line tool, `sqlite3 locksmith-ops.db < schema.sql` does the same thing, but it is not required.

### 5. Teach the AI the workflow

Paste the contents of `SKILL.md` into your AI tool as standing instructions. In Claude Desktop, create a Project and put it in the project instructions; in Cursor, save it as a rule. Then tell it your basics once:

> We're Keyline Mobile Locksmith in Portland, Oregon, Pacific time. It's just me, Dana Chen, dana@example.com. Set me up.

It writes those to the `settings` table, **invites you to ZenSched as a worker** (you are the tech on the phone; $0.25, one time), creates the Job Record form on ZenSched (free), and saves the form id so every call gets it automatically. In agency mode you then say "add my sub Marcus Webb, marcus@example.com, I pay him $80 a call" for each tech you dispatch.

**Check-in radius and slack.** ZenSched enforces the radius through the account's policy, not per address, and with geofencing on it raises anything under 100 m to about 91 m (300 ft). The kit sets 150 m so a hotel lot and an apartment driveway are covered. Ask the AI to "set the check-in radius to 250 m" (`policy_update`) for office parks, or to move the pin onto the entrance for a repeat site (`location_update`, free; the `places` cache keeps it). The kit sets `checkin_slack_min` to **30**: that is the early/late tolerance around a shift, so you can punch at 9:40 for a 10:00 rekey, and an "I'm here now" window the AI opened a minute after you parked still accepts the punch. `remote_checkin` turns GPS verification off for every call and should be a last resort.

**Forgotten check-outs.** The kit sets a check-out reminder 15 minutes after the window ends (`checkout_reminder_min_after`).

### 6. Funding (only when asked)

The first 200 ZenSched tool calls per day are free. Some things are metered: creating a location (geocoding, $0.03; skipped for a cached repeat address), inviting a worker ($0.25, including yourself), each GPS-verified check-in or check-out ($0.10), and reading a Job Record ($0.05, or $0.15 when it has work photos; each record is billed once, ever). When a metered call happens without funds, the AI will get a `payment_required` response and tell you how to add the $5 activation deposit, which is credited to your balance. You will not be charged without seeing this first.

A call at a new address costs $0.03 + $0.20 + $0.15 = **$0.38**; a call at a repeat hotel costs $0.35. Ten calls a day, 22 days, is about $77 if every one is a new address (less when hotels and complexes repeat). The AI states the cost before it spends.

## Using it

Everything after setup is plain English. Examples:

- (paste a property-manager work order) "Book it."
- "I'm at the Civic lockout now." / "Marcus at the Marriott now."
- "What's today?" / "What's this week?"
- "Was I on time at the Oak rekey?"
- "Close out today. Elm: Schlage deadbolt, $185 cash, 8 miles."
- "Nobody home at Oak. Get me the trip fee."
- "The 10 o'clock moved to 1." / "Cascade moved the Oak rekey to Monday."
- "Cancel the Pine Court install; they owe a $45 trip."
- "Invoice Cascade Properties." / "Invoice everyone."
- "Who owes me money?"
- "Cascade paid INV-2026-0002."
- "Mileage for September?"
- Agency: "Add my sub Marcus Webb, marcus@example.com, $80 a call." / "Give the Thursday 6 pm to Marcus." / "What do I owe Marcus?"

See `QUICKSTART.md` for the first-week walkthrough and `example-workflow.md` for exactly which tools the AI calls behind each of these.

### Planned windows and "I'm here now"

ZenSched only records a GPS check-in against a scheduled shift, and lockouts happen when the tech is already there. The kit handles that two ways, and `SKILL.md` teaches both:

- **Planned windows.** A rekey, install, or booked lockout gets a future `scheduled_start` and a shift on a single-day event. Planned windows can be moved, cancelled, or handed to another tech.
- **"I'm here now."** You (or a sub, through you) text the AI "lockout at Elm, I'm there." The AI inserts a call with `scheduled_start` = now and `is_adhoc` = 1, creates a single-day event, and `shift_create`s from now to now + 45 minutes. The tech punches within the minute. A repeat hotel is a cache hit (no geocode); a new house is location + event + shift.

The `checkin_slack_min` policy setting (30 minutes in this kit) is what makes both work. This is the kit's answer to a platform gap: ZenSched has no "check in now at location X" without a shift, so the agent creates the shift.

### What "invoice" means here

"Invoice Cascade" records the invoice in your database and the AI writes out a plain-text invoice you can paste into an email, with a line per call (your call number, date, type, their PO, fee breakdown) and, for a no-show, the GPS-verified arrival and wait. It does **not** generate a PDF, submit it for you, or collect payment. Invoices never carry a customer's name, phone, address, or ID number; the PO identifies the job to them. When the client pays, tell the AI ("Cascade paid INV-2026-0002") and it marks it paid. "Who owes me money" ages what is open into current / 30 / 60 / 90+ days past due. A walk-up who paid cash at the door is invoiced and marked paid in the same close-out.

### What "payouts" means here (agency mode)

Subs are paid per call, not by the hour. Each sub has a split (`$80 flat` or `60%` of what the client is billed for that call). When a sub's call is closed out, a payout row is created with the amount; "what do I owe Marcus" lists his unpaid calls and the total, and "paid Marcus" marks them. Your own calls never generate payouts. The kit does not calculate taxes, issue 1099s, or pay anyone. If you also want an hours record for your own books, ZenSched's `timesheet_export(mode="hours")` is free.

## Mobile app for techs

- **Android:** [Google Play](https://play.google.com/store/apps/details?id=com.zensched.app)
- **iOS:** [TestFlight](https://testflight.apple.com/join/Wp51m5Yq)

In solo mode you invite yourself; the email arrives at your own address, you install the app, and your calls appear as they are booked. Each one shows the address and time; you check in on arrival (GPS-verified), do the work, fill in the Job Record, and check out. Subs get the same email when you add them. iOS is TestFlight for now: builds expire every 90 days and the install is unfamiliar; ask which phones your subs carry.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| AI says it has no ZenSched tools | Config file not saved, or the app was not fully restarted | Check the JSON is valid (paste it into [jsonlint.com](https://jsonlint.com)), then quit and reopen the app |
| AI says it has no SQLite / `locksmith-ops-db` tools | Node.js not installed, or bad `SQLITE_PATH` | Install Node.js LTS; on Windows check every backslash is doubled |
| `SQLITE_PATH` points nowhere / "unable to open database" | Folder from step 1 does not exist | Create the folder; the file is created automatically but the folder is not |
| ZenSched tools return an auth error | Key still says `zsc_your_key_here`, or was pasted with a space | Re-paste the key, restart |
| `payment_required` | Metered call with no balance | Follow the instructions in the response; $5 deposit |
| AI creates shifts at the wrong hour | Timezone not set, or daylight saving changed | "Set my timezone offset to -08:00 in settings" (use your own offset; Pacific is -07:00 in summer, -08:00 in winter) |
| Call not on my phone | Booked locally but the ZenSched shift was never created (`needs_shift = 1`) | "Put today's calls on my phone"; the AI finishes the intake steps |
| Check-in rejected: too early / too late | Slack window too small | "Set the check-in slack to 45 minutes" (`checkin_slack_min`, max 240), or have the AI `shift_update` the window before you punch |
| Check-in not GPS-verified at a hotel / complex | You parked outside the policy radius, or the pin is on the road | "Set the check-in radius to 250 m" (`policy_update(0, {"checkin_radius_m": 250})`; never "on that location"), or "move the pin to the lobby" (`location_update`, free; the cached place keeps it) |
| "I'm here now" took too long and the punch was refused | Window opened more than `checkin_slack_min` after the tech arrived | Have the AI `shift_update` the window to the real arrival time; raise the slack |
| Forgot to check out | Shift still `checked_in` | Tell the AI the real time; the 15-minute check-out reminder is already on |
| Job Record not on the phone | Form not assigned to that call's event before the shift was created | "Attach the Job Record to C-2026-0004" (`form_assign(form_id, event_id=…)`); it installs on the existing shift, no cancel/recreate. Recreating with the same `shift-call-{call_id}` key would only replay the cancelled shift for 24 hours |
| AI refuses to store an ID number | Working as intended | That goes on your paper ticket if your board wants it |
| Same hotel geocoded twice | Address typed differently (suite on a new line, "Ave" vs "Avenue") | Tell the AI it is the same place; it merges the `places` rows and keeps one location |
| Call moved to another day fails on `shift_update` | Events are single-day | The AI cancels the shift and creates a new call (`rescheduled_from`) with its own event; ask it to |
| Mileage deduction looks off | `irs_mileage_rate` still last year's | "Set the mileage rate to 0.72"; existing trips keep their snapshot |
| AI asks you to run SQL yourself | It does not have `SKILL.md` loaded | Re-paste `SKILL.md` as project instructions |

If something is confusing or broken in ZenSched itself, ask the AI to call `feedback_submit` with a description. It is free, needs no account, and a human reads every submission.

## For developers

**Architecture.** Two MCP servers, no application code. The agent is the integration layer; `SKILL.md` is the spec it follows. ZenSched is authoritative for operations (schedule, punches, form submissions); SQLite is authoritative for clients, places, roster, calls (including all customer PII), mileage, billing, and payouts; each side stores only the other's IDs, plus a per-call summary and the GPS stamps cached locally because submission reads are metered. The PII boundary is enforced by data placement (customer columns exist only locally, and the views compute the ZenSched-safe `zensched_location_name` / `zensched_event_title` strings) and by `SKILL.md` rules 1–2; there is no technical control stopping a misbehaving agent, so review the rules if you swap models.

**Data model decisions.**

- **One-off calls, not recurring routes.** Like the notary kit, locksmith work is a different address almost every time, so there is no recurrence table and no event roll. `calls` is the driving table; each row maps to exactly one `event_create(location_id, title, start_date=<date>, end_date=<date>, idempotency_key="event-call-{call_id}")` and one `shift_create(event_id, worker_id, start, end, idempotency_key="shift-call-{call_id}")`, with `form_assign(form_id, event_id=...)` in between so the shift installs the form on the phone. The 60-day event cap is irrelevant because every event is one day.
- **`places` is an address de-dup cache.** `places.normalized_address` is `UNIQUE`; the agent normalizes and looks it up before any `location_create`. A hit reuses `zensched_location_id`, which saves the $0.03 geocode and preserves any hand-tuned pin for a hotel or complex. `street_name` (no house number) feeds labels (`Call - Elm St`). `is_repeat_site` is a hint for labelling (`<client> - <city>` for hotels, `Call - <street>` for houses).
- **Planned vs "I'm here now."** Both are `calls` rows; `is_adhoc` distinguishes them for `tech_activity`. A planned call has a future `scheduled_start`; an ad hoc one has `scheduled_start` = now and gets a shift immediately. The kit relies on `checkin_slack_min` (30) so both accept real-world punch times. There is no punch-without-shift path on the platform; this is the workaround, and the pitch lists the gap.
- **Solo mode is the default; agency mode is additive.** The owner is invited as a ZenSched worker and stored on `techs` with `is_owner = 1`; `settings.default_tech_id` points at that row and the `fill_call_defaults` trigger assigns it when `tech_id` is left NULL. Subs are further `techs` rows with `payout_type` `CHECK IN ('flat', 'percent')` and `payout_value`. `payouts_due` and `payouts_missing` exclude `is_owner = 1`.
- **Receivables and payouts, not timesheets.** Property managers and auto clubs pay per call, often net 30, so the money model is per-call fees → `billable_calls` → `invoices` with the client's `payment_terms_days` → `invoices_outstanding` aging. Subs are paid per call (split). Walk-ups who pay cash are invoiced and marked paid at close-out.
- **`billable_total` is computed in a view, not stored.** The fee columns on `calls` (`service_fee`, `trip_fee`, `parts_fee`, `after_hours_fee`, `other_fee`) are snapshots filled by trigger from the client's defaults when left NULL. Which of them are owed depends on `status`, and that rule lives once, in `billable_calls`: `completed` → service + trip + parts + after_hours + other; `no_show` → trip + after_hours; `cancelled` → `other_fee` only; everything else → 0. `amount_collected` is the form currency field (what was charged at the door) and is not the invoice total.
- **`call_no`** is assigned by trigger as `C-{YYYY of scheduled_start}-{call_id:04d}` when left NULL; an explicit value is kept. `invoices.invoice_number` is `{prefix}-{YYYY}-{invoice_id:04d}` the same way.
- **`scheduled_start` is local wall-clock time without an offset** (`2026-09-08T14:00`, `CHECK`-constrained to reject a trailing offset or `Z`). Views emit `start_iso` and `end_iso` by appending `settings.timezone_offset`. Day-based views use `date('now', 'localtime')` because the SQLite MCP server runs on the owner's computer.
- **No customer ID number column.** `id_checked` stores the form option key only. `SKILL.md` rule 1 forbids inventing a column or accepting a number.
- **No signature field on the form.** ZenSched replaces the Submit button with the signature pad when a form has a `signature` field. `work` is a `photo` field (`max_images: 2`); a submission with a photo bills $0.15 instead of $0.05.
- **GPS stamps are copied once.** `checked_in_at`, `checked_out_at`, `gps_verified`, `checkin_distance_m` are filled from `shift_status` at close-out so "was I on time" and `no_show_evidence.minutes_on_site` are answered locally.
- **Reschedules.** Same day → `shift_update` and update `scheduled_start`. Different day → `shift_cancel`, mark the row `rescheduled`, insert a new row with `rescheduled_from`, and create a new event/shift. Only the new row bills.
- `calls.zensched_shift_id`, `techs.zensched_worker_id`, `payouts.call_id`, and `places.normalized_address` are `UNIQUE`. `PRAGMA foreign_keys = ON` is in `schema.sql` and `SKILL.md` tells the agent to run it per session. Deleting a client cascades to calls, invoices, and payouts and sets `mileage.call_id` NULL; deleting a tech sets `calls.tech_id` NULL and removes their payouts; `places` is `ON DELETE RESTRICT` while calls reference it.

**Job Record form.** Created once with `form_create(title, fields_json, idempotency_key="form-job-record")`; the exact `fields_json` is in `SKILL.md` and `example-workflow.md` (byte-identical) and was validated against ZenSched's form validator. Every field carries an explicit `identifier` so submission `data` keys are stable (`job_type`, `id_checked`, `lock_type`, `amount`, `work`, `notes`). Option keys are derived by ZenSched from the labels (lowercase, non-alphanumerics → `_`, truncated at 30 characters); every option label here is short enough that nothing truncates: `job_type` ∈ `lockout`, `rekey`, `install`, `auto`, `safe`, `other`; `id_checked` ∈ `yes___driver_license`, `yes___other_government_id`, `personally_known`, `no`, `not_required`. Attaching is `form_assign(form_id, event_id=...)` per call, which resolves event → brand → policy and installs the form on the phone for the subsequent `shift_create`.

**Idempotency keys.** Deterministic, derived from local IDs so a retried or re-run agent turn cannot duplicate:

- location: `loc-place-{place_id}`
- event: `event-call-{call_id}`
- shift: `shift-call-{call_id}` (each tech swap on the same call appends the next suffix: `-2`, then `-3`, … — never reuse a suffix, or the 24-hour replay returns the cancelled shift)
- cancel: `cancel-shift-{shift_id}`
- worker: `worker-{email}`
- form: `form-job-record`

ZenSched caches idempotent responses for 24 hours. The views emit `loc_idempotency_key`, `event_idempotency_key`, and `shift_idempotency_key` per row. `form_assign` takes `form_id` and `event_id` only (verified signature).

**Timestamps.** `shift_create` / `shift_update` take `start` and `end` in ISO 8601 with an explicit offset. Always use the business's local offset from `settings.timezone_offset` (e.g. `2026-09-08T14:00:00-07:00`), never `Z`. The views build these strings so the agent does not have to.

**Metered reads.** `form_submissions(form_id, event_id=...)` is the natural per-call read because every call has its own event; `form_export` covers a week or month in one call. Both bill $0.05 per submission ($0.15 with a photo), once per submission ever. `shift_list`, `shift_status`, `event_get`, and `timesheet_export(mode="hours"|"raw")` are free.

**Check-in policy.** The radius is enforced by `policy_update(0, '{"checkin_radius_m": N}')`, not by `location_create(checkin_radius_m=...)`, which is informational; with geofencing on, values under 100 m are raised to about 91 m. `checkin_slack_min` (0–240) is the setting that makes planned and ad hoc calls practical; the kit uses 150 m / 30 min / 15-minute check-out reminder.

**SQLite MCP server.** `mcp.json.example` uses [`easy-sqlite-mcp`](https://github.com/chenkumi/easy-sqlite-mcp) (Node, `better-sqlite3`, `SQLITE_PATH` env var). Its `sqlite_execute` calls `prepare()`, so it accepts **one statement per call**; `schema.sql` is written so every statement stands alone and is idempotent. `payouts_due` uses a window function (`SUM() OVER`), which needs SQLite ≥ 3.25 (2018); `better-sqlite3` bundles a current SQLite.

**Schema test.** The schema was verified by splitting the file into its 54 statements with `sqlite3.complete_statement` and executing each individually (as the MCP server does) twice for idempotency (seed rows not duplicated), then exercising: all 8 tables, 12 views, and 10 triggers present; every view on an empty database; `places.normalized_address`, `techs.zensched_worker_id`, `calls.zensched_shift_id`, and `payouts.call_id` `UNIQUE`; the `number_call` trigger (`C-YYYY-0001`, explicit number kept); `fill_call_defaults` (duration from settings and following a changed setting, tech from `default_tech_id`, fees from client defaults, else 0, explicit fee/duration kept); `calls_today` / `calls_upcoming` / `calls_open` (`start_iso` / `end_iso` with offset for `HH:MM` and `HH:MM:SS` inputs and 45/60/90-minute durations, `needs_location` / `needs_shift`, the three idempotency keys, `zensched_event_title` containing type + number and no customer name, `zensched_location_name` from `place_label`, 7-day window bounds, cancelled excluded, `is_adhoc`); `updated_at` on calls; `billable_calls` for completed (210 = service + parts), completed lockout (service + trip), no-show (trip only), cancelled (`other_fee` only), and confirmed (0); `receivables_by_client` totals and the drop-off after invoicing; invoice numbering, total, due date = +30 days, `line_items` JSON; `invoices_outstanding` aging buckets `current` / `30` / `60` / `90+` with paid excluded; the mileage trigger (8 × 0.70 = 5.60, explicit rate kept, nullable call, recompute on update) and `mileage_by_month`; payouts for flat (80) and percent (60% of 210 = 126), no split (NULL), owner exclusion, `needs_amount`, `payouts_missing`; `no_show_evidence` (`minutes_on_site` 55); `open_calls_now` (listed after a forgotten check-out, dropped after check-out); `tech_activity` ad-hoc count; `rescheduled_from`; every `CHECK` (client type, job type, status, payout type, `scheduled_start` format with offset / `Z` / space rejected, duration range, miles); foreign keys rejecting an unknown client or place, `RESTRICT` on places, `SET NULL` on tech delete, and the full cascade on client delete. 151 checks, all passing. The Job Record was validated against `_validate_fields` (7 fields, no signature, no ID-number identifiers, option keys ≤ 30, JSON byte-identical in `SKILL.md` and `example-workflow.md`).

## Support

- ZenSched docs: <https://www.zensched.com/docs/>
- Tool reference: <https://www.zensched.com/docs/tools/>
- Feedback: ask your AI to call `feedback_submit` (categories: `bug`, `friction`, `missing_capability`, `docs`, `billing`, `feature`, `other`)

## License

MIT. See `LICENSE`.
