# Quickstart

Setup is about 15 minutes, once. After that everything is plain English to your AI. Each step below tells you what to do and, where relevant, exactly what to type to the AI.

You need: Claude Desktop (or Cursor) and [Node.js LTS](https://nodejs.org/) installed. Nothing else.

Before you start, read the "This is not a license or ID system" section of `README.md`. Short version: this kit puts every call on your phone and GPS-stamps arrival; it does not store customer ID numbers, does not verify identity for you, and is not your locksmith license. Customer names, phones, and gate codes stay on your computer; ZenSched only ever sees a place label, an address, and a Job Record.

## 1. Make a data folder

Create a folder such as `C:\Users\YourName\locksmith-ops` (Windows) or `/Users/yourname/locksmith-ops` (Mac). Note the full path. It will hold customer names and phone numbers, so keep it on an encrypted, backed-up disk.

## 2. Add the two tools to your AI's config

Open the config file:

- **Claude Desktop, Windows:** `%APPDATA%\Claude\claude_desktop_config.json`
- **Claude Desktop, Mac:** `~/Library/Application Support/Claude/claude_desktop_config.json`
- **Cursor:** Settings → MCP → Add new global MCP server

Paste this in and fix only the `SQLITE_PATH` line to match your folder from step 1:

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

- On Windows, double every backslash: `"C:\\Users\\YourName\\locksmith-ops\\locksmith-ops.db"`.
- Leave `zsc_your_key_here` as it is. You get the real key in the next step.

Save, then **fully quit and reopen** the AI app.

## 3. Create your ZenSched account

Type to the AI:

> Call zensched_guide, then account_create with org_name "My Mobile Locksmith". Show me the zsc_ key.

Copy the key into the config file in place of `zsc_your_key_here`. Save. Quit and reopen the app once more. (You can also ask the AI to call `account_use_key` with the key to continue right away, but update the file anyway so it sticks.)

## 4. Create the database tables

Copy the full contents of `schema.sql` and paste it into the chat with this line above it:

> Create these tables in my locksmith-ops database. Run each statement one at a time with the SQLite tool, then list the tables to confirm.

## 5. Give the AI its instructions

Paste `SKILL.md` into the AI as standing instructions (Claude Desktop: a Project's instructions; Cursor: a rule). Then:

> We're Keyline Mobile Locksmith in Portland, Oregon, Pacific time. It's just me, Dana Chen, dana@example.com, 503-555-0100. Set me up.

The AI saves your settings, invites **you** to ZenSched as a worker ($0.25, once; you are the tech on the phone), and calls `form_create` once (free) to build the Job Record you fill in after each call: job type (Lockout / Rekey / Install / Auto / Safe / Other), whether an ID was checked (type only — never a number), lock type, amount charged, up to two work photos, and notes. No signature pad, no customer ID numbers. It stores the form id so every call gets it, and sets the check-in policy: 150 m radius, **30 minutes of slack** so an early, late, or on-the-spot punch is accepted, and a check-out reminder 15 minutes after the window. Install the app from the invitation email ([Android](https://play.google.com/store/apps/details?id=com.zensched.app) / [iOS TestFlight](https://testflight.apple.com/join/Wp51m5Yq)).

Agency mode: "Add my sub Marcus Webb, marcus@example.com, I pay him $80 a call" for each tech you dispatch.

## 6. Book a planned job, or punch in on the spot

Planned (rekey / install / booked lockout):

> Cascade Properties wants a rekey tomorrow 10 am at 14 Oak St, Portland 97214, PO 4412, $185.

Behind the scenes the AI adds the client if new, checks whether you have been to that address before, saves the call as `C-2026-0001` with the customer's name kept local, creates a single-day event titled `Rekey C-2026-0001`, attaches the Job Record, and puts the window on your phone.

Emergency — you are already there:

> Locked out at 1042 Elm St Portland 97214. I'm here now.

The AI inserts an ad-hoc call with `scheduled_start` = now, geocodes only if the address is new, and `shift_create`s a window starting now. Reply is one line: "Window's on your phone. Check in now." The 30-minute slack is what lets the punch go through even if the window opened a minute after you parked. ZenSched has no "check in now" without a shift; creating the shift is the workaround.

## 7. The call

Your phone shows the call. At the door, **Check in** (GPS-verified). Do the work. Open the **Job Record**: job type, ID checked (yes / type — not the number), lock type, amount, work photos. **Check out**. Submit.

## 8. Close out

> Close out today. Elm was a Schlage deadbolt, $185 cash, 8 miles.

The AI pulls your GPS-verified arrival (free), reads the Job Record (metered, so it tells you the cost first, about $0.15 with photos), updates the call, stores the miles, and tells you what is now receivable or already paid at the door.

> Was I on time at the Oak rekey?

Answered from the local record, free: scheduled vs GPS-verified check-in, distance from the pin.

> Nobody home at Oak. Get me the trip fee.

Marks the call a no-show (trip and after-hours stay billable) and drafts the note to the property manager with your GPS-verified arrival.

## 9. Money

> Invoice Cascade Properties.

A plain-text invoice under their terms with one line per call (your number, date, type, their PO, fee breakdown). Nothing about customers on it.

> Who owes me money?

Open invoices aged current / 30 / 60 / 90+ days past due.

> Cascade paid INV-2026-0002.

Marks it paid.

> Mileage for September?

Trips, miles, and the deduction at the IRS rate.

Agency: "What do I owe Marcus?" lists his unpaid calls and total; "paid Marcus" marks them.

## What next

- `README.md` for the full explanation, the privacy boundaries, troubleshooting table, and developer notes
- `example-workflow.md` to see the exact tool calls behind each step above
