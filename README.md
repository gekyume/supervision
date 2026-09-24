# Supervision 🧠

**A gentle, strict supervisor for your Mac, for people with ME/CFS, Long COVID, and other
energy-limiting conditions.**

If thinking hard on a screen makes you crash a day or two later, "stop when it hurts" is
always too late. Supervision sits behind you while you work and stops you *before* it hurts:
short work blocks, a full-screen rest you can't click past, three quick faces after each
break, and a daily budget that grows only when your body says it's ready.

> ⚠️ Early and evolving. Not medical advice. Built by someone living with ME/CFS, for their
> own use first. Talk to a clinician who knows ME/CFS.

## What it does
- **Blocks sized to your morning.** 30 / 25 / 15-minute work blocks depending on your
  wearable's recovery score (or the middle tier if you don't have one).
- **A real rest screen.** Full-screen, every display, no app switching. It explains *why*
  with numbers, offers up to three alternatives (stretch, a slow walk, journal on paper…),
  and never appears during a call (calendar, Zoom, camera, mic, meeting windows).
- **Three faces after each break:** brain fog, headache, how crashy. If they climb, the day
  gets gentler or ends, framed as the experiment working, not a failure.
- **A weighted budget.** Meetings cost more than email; context-switching adds up; paper
  work counts at half. A 3-day cap protects against boom-and-bust.
- **Earns capacity back.** Each day is judged by the two mornings after it. Three clean days
  add time. Capacity drops only on a pattern, never on one bad day.
- **Knows what you did.** An hourly calendar log of what you actually worked on (from window
  titles, kept on your Mac), plus `supervisionctl day` for a ledger.
- **No off switch, on purpose.** It can't be quit from the Dock and relaunches if killed.
  The only way to pause it is to ask Claude, who logs the reason.

Read the full logic, with diagrams: [docs/how-it-works.html](docs/how-it-works.html)
(also in the menu bar: 🧠 → *How Supervision decides…*). Why it's designed this way:
[docs/DESIGN.md](docs/DESIGN.md). The evidence: [RESEARCH.md](RESEARCH.md).

## Requirements
- macOS 13 or later (Apple Silicon or Intel)
- Command Line Tools: `xcode-select --install` (full Xcode not needed)
- Recommended: [Claude Code](https://claude.com/claude-code), to pause, adjust and talk to it

## Install
```bash
git clone <this repo> Supervision && cd Supervision
./scripts/make-signing-identity.sh   # once: keeps macOS permissions across rebuilds
./scripts/build.sh
./scripts/install.sh                 # installs, starts at login, relaunches if killed
```
A welcome window walks you through the two permissions it needs:
**Accessibility** (to see which app/window is in front) and **Calendars** (to avoid
meetings and write the log).

Optional personal settings:
- `scripts/local.env` → `BUNDLE_ID=com.yourname.supervision`
- `~/Library/Application Support/Supervision/profile.json` → `{ "logCalendar": "Energy log" }`
- Places and their break activities: `supervisionctl context add-wifi home "<your Wi-Fi>"`

Wearables, spreadsheets and daily chats: [docs/integrations.md](docs/integrations.md).

## Using it
Open Claude Code in this folder and just talk: "pause for an hour, I'm in a crunch",
"that meeting was intense", "I did 30 minutes on paper", "what did I get done today?".
Claude reads [CLAUDE.md](CLAUDE.md) and runs `supervisionctl` for you:

```
supervisionctl status | day | report 7 | log | symptoms | capacity
supervisionctl pause 60 "why" | resume | budget +30 "why"
supervisionctl flag intense|travel|stress|crash|headache
supervisionctl offscreen 30 "what"
supervisionctl baseline <date> <recovery> <restingHR> <hrv> <sleepH> "source"
```

## Uninstall
```bash
supervisionctl allow-quit
launchctl bootout gui/$(id -u)/com.supervision.mac   # or your BUNDLE_ID
rm -rf ~/Applications/Supervision.app ~/Library/LaunchAgents/com.supervision.mac.plist
rm -rf ~/Library/Application\ Support/Supervision        # your data
```

## Privacy
Everything stays in `~/Library/Application Support/Supervision/` on your Mac. The only thing
it writes elsewhere is the calendar log you choose, plus any integrations you set up yourself.

## License
MIT. See [LICENSE](LICENSE).
