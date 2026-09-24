# Optional integrations

Supervision works on its own. These make it smarter. All of them run through
[Claude](https://claude.com/claude-code) (Claude Code or the Claude desktop app's Code tab)
with the matching connector, as scheduled tasks.

## Wearable recovery (Whoop, Oura, Garmin…)
The morning tier comes from `baseline.json`. Without a wearable, every day is treated as
"yellow". To feed it, create a scheduled task (e.g. 8:15, 10:15, 12:15, 14:15 daily) in
Claude with a prompt like:

> Using the Whoop connector, get today's scored recovery and last night's non-nap sleep.
> Run: `supervisionctl baseline YYYY-MM-DD RECOVERY RESTING_HR HRV SLEEP_HOURS "whoop"`
> with today's local date. If today's recovery isn't scored yet, do nothing.

Any source works as long as it ends with that command. You can also tell Claude your
numbers by hand.

## Calendar log
Supervision writes one event per hour (minutes by kind of work, what you worked on) and one
per break to a calendar named in `~/Library/Application Support/Supervision/profile.json`:

```json
{ "logCalendar": "Energy log" }
```

For it to reach your phone, create a calendar with that name in Google Calendar (or iCloud)
first; macOS syncs it in the background. If none exists, Supervision creates a local one.

## A spreadsheet or Airtable log
`supervisionctl daily-json` prints the whole day as JSON: weighted load, screen and meeting
minutes, minutes by kind, what you worked on, breaks, symptom readings, flags. A nightly
Claude task can copy it anywhere, e.g.:

> Run `supervisionctl daily-json`. In Airtable base <BASE_ID>, table <TABLE_ID>, upsert one
> row for that date with: Weighted Load, Screen Min, Meeting Min, Work By Kind, Worked On,
> Breaks, Symptoms, Flags.

## Talking to it
Open Claude Code in this project folder. `CLAUDE.md` briefs Claude on everything; add a
`CLAUDE.local.md` describing yourself (how you like to be spoken to, your connectors, your
history) and Claude will read that too. It's excluded from anything you publish.
