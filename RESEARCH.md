# Research notes — what the evidence says, and what Supervision does with it

Reddit blocks my tools, so these come from clinical and patient-organization sources. Paste r/cfs threads into chat and I'll fold them in.

## 1. Computer work vs. walking around

**What's known**
- Both trigger PEM. ~90% of patients get PEM from physical *and* cognitive exertion; "medium" levels of either account for most episodes. ([Frontiers 2023](https://www.frontiersin.org/journals/physiology/articles/10.3389/fphys.2023.1257557/full))
- Physical exertion tends to bring PEM on *faster*; cognitive PEM is often the slower, 1–2 day kind. Onset in daily life: within minutes 35%, within hours 40%, a day or more 25%. ([Frontiers 2023](https://www.frontiersin.org/journals/physiology/articles/10.3389/fphys.2023.1257557/full), [Deconstructing PEM survey](https://pubmed.ncbi.nlm.nih.gov/29856774/))
- **Being upright is its own cost.** Standing drops brain blood flow up to ~26% in ME/CFS vs ~7% in healthy people; "sitting at a desk" and "walking" both count as upright exertion that can trigger PEM. ([RTHM on OI](https://www.rthm.com/resources/blogs/me-cfs-orthostatic-intolerance), [Frontiers 2023](https://www.frontiersin.org/journals/physiology/articles/10.3389/fphys.2023.1257557/full))
- Cognitive load is cumulative: a call, a text thread, deciding lunch, radio in the car all draw from the same envelope. ([RTHM cognitive pacing](https://www.rthm.com/resources/blogs/cognitive-pacing-brain-fog))
- **No study directly shows that alternating cognitive and physical tasks is protective.** Researchers say daily-activity PEM is under-studied. Alternating modalities is a reasonable *variety* strategy, not a way to get free energy.

**What it means for you**
| Activity | Cost | Notes |
|---|---|---|
| Lying down, eyes closed, quiet | ~0 | The only thing that is actually rest |
| Music, lying down | low | Fine as rest |
| Talking to Claude while lying down | low–med | Cognitive + social, no orthostatic load. Best "active" option |
| Desk work, sitting | med | Cognitive + orthostatic |
| Desk work, reclined / laptop in bed | lower | Same cognition, much less orthostatic load. Worth trying for reading and email |
| Walking + thinking through a task | med–high | Physical + orthostatic + cognitive, and physical PEM comes on faster |
| Freestyle rap, crafts | med | Real exertion, but a different kind. Good on low-load days |
| Podcasts, scrolling, video | med | Not rest. Counts as screen time |

So: a walk is a *swap*, not a break. Supervision will offer swaps only when the day's load is low, and count them.

## 2. Pacing rules the app follows
| Rule | Source | Where it lives |
|---|---|---|
| Do 50% of what you think you can | RTHM, AMMES | 15-min blocks vs your ~30-min tolerance |
| Cognitive work in 10–15 min intervals, then rest | RTHM energy envelope | `workMinutes = 15` |
| Rest must be scheduled and pre-emptive, before you feel tired | RTHM, AMMES, CDC | Timer-based, not feeling-based |
| Stop before you feel like stopping | AMMES | Nudge at 13 min, lock at 15 |
| Plan rest after known exertion (meetings) | CDC, PLRC | Meeting minutes spend the daily budget |
| Diaries find personal limits | CDC | Window-title log + one-tap check-ins |
| HR alerts (resting HR + 15 bpm) | Workwell, RTHM | Later, via Whoop / Baseline |
| Reduce orthostatic load: work reclined | RTHM | Suggestion on the break screen; tracked later |

## 3. What existing products do, and the lessons
- **Visible** (ME/CFS pacing app): morning HRV + sleep rating → daily "stability score" 1–5 → how much pacing today. PacePoints budget from a wearable. Lesson: **one number in the morning sets the day's budget.** That's the Whoop/Baseline hook: recovery score → `dailyBudgetMinutes`. ([ME Association review](https://meassociation.org.uk/2024/04/visible-the-pacing-app-for-people-with-me-cfs-and-long-covid/))
- **Bearable**: symptom + factor tracking with correlations. Lesson: the value is in "crash days followed days with X" — build the weekly correlation report.
- **Time Out, Stretchly, BreakTimer**: optional skip/postpone. **LookAway**: strict mode plus auto-pause for meetings, calls, screen sharing. The reviewer's line: "If breaks are too strict, you disable the app." Lesson: **strictness only survives with context awareness.** Supervision has Zoom + calendar detection; next is screen-sharing and full-screen video detection. ([Mac break apps 2026](https://lookaway.com/blog/2026/04/24/best-break-reminder-apps-for-mac-in-2026/))

## 4. Credibility rules (from Atomic Habits + alert-fatigue research)
- Make it obvious: the menu bar always shows block progress and today's load.
- Make it easy: one nudge, one lock, no menus during a break.
- Make it satisfying: end-of-day "you protected tomorrow" and streaks (next).
- Every intervention states its reason with numbers. `supervisionctl log` shows every decision.
- Never ask for typed input. At most two one-tap check-ins a day.

## 5. Deeper dive (Solve M.E., Bateman Horne, Stanford/OMF, digital-pacing evidence)

### What the patient-org guides agree on
- **Rest is the treatment.** Solve M.E.: "Rest! Rest! Rest!" Bateman Horne: "Resting is the single most important pacing strategy and mitigates further cellular damage." ([Solve M.E. PEM & Rest guide](https://solvecfs.org/wp-content/uploads/2021/09/PEM-REST-Combined.pdf), [BHC pacing packet](https://bpb-us-e1.wpmucdn.com/sites.uw.edu/dist/0/27887/files/2024/11/Bateman-Horne-Pacing-Packet.pdf))
- **Rest is pre-emptive, on a schedule, not in reaction to symptoms.** "Schedule rest time (even if you don't think you need it)." Pre-emptive rest programs report *more* energy and *lower* symptoms; one case went from 15 h of daily rest to 3 h over six months by using frequent short rests. ([Solve M.E.](https://solvecfs.org/wp-content/uploads/2021/09/PEM-REST-Combined.pdf), [CFS Self-Help: pre-emptive rest](https://www.cfsselfhelp.org/library/4-nurture-yourself-with-pre-emptive-rest))
- **Rest means lying down, eyes closed, quiet.** TV, reading and phone calls don't count "even when reclined." ([CFS Self-Help](https://www.cfsselfhelp.org/library/4-nurture-yourself-with-pre-emptive-rest))
- **Four energy consumers, all on one bill:** physical, cognitive, emotional, **orthostatic** (time with feet on the floor, standing *or sitting*). A 10-minute video call is charged in all four. ([BHC crash guide](https://batemanhornecenter.org/wp-content/uploads/2022/01/Crash-Care-Survival-Guide-v3.pdf))
- **Repeated PEM worsens long-term prognosis.** "Continued and repeated episodes of PEM … appear to be associated with a worsened long-term functional prognosis." Each crash can end at the old baseline *or a new, more restricted one*. ([BHC pacing packet](https://bpb-us-e1.wpmucdn.com/sites.uw.edu/dist/0/27887/files/2024/11/Bateman-Horne-Pacing-Packet.pdf))
- **Early illness matters most.** The ME Association's advice for the first stretch of illness is old-fashioned convalescence; never try to work or exercise your way out of the early stages. ([ME Association pacing](https://meassociation.org.uk/wp-content/uploads/2025/10/PACING-V2-1.pdf))

### Concrete numbers from the guides
| Rule | Source |
|---|---|
| Use 80% of your energy, keep 20% in reserve every day | BHC crash guide |
| Go horizontal 10–15 min every couple of hours | BHC crash guide |
| Upright tasks: 5 min of activity, then 10–15 min rest | BHC crash guide |
| Cognitive work: 10 min focus, 20 min cognitive rest (severe end) / 10–15 min blocks (moderate) | RTHM |
| 1–2 pre-emptive rests a day of 15–30 min, or 10–15 min every 1–2 h | CFS Self-Help |
| HR ceiling: resting HR + 15 bpm; stop immediately when the alarm sounds | RTHM, Workwell, BHC |
| Schedule "brain breaks"; set timers during activities | BHC crash guide |

### What the digital-pacing evidence says (PLOS Digital Health 2025 review)
- Wearable + app "just-in-time" prompts are **feasible and safe**, users report "greater insight and control."
- The one RCT (PaceMe, Long COVID, prompts at 50/75/100% of a daily allowance) showed **no benefit over usual care**. Authors think ME/CFS is where a signal would show, because there's little natural recovery.
- **Abandonment drivers:** notification fatigue, data overload, "fixation" on numbers, manual programming burden.
- **Design recommendations:** limit notification frequency, quiet hours, conservative personalized thresholds, passive data over manual entry. ([PLOS Digital Health](https://journals.plos.org/digitalhealth/article?id=10.1371/journal.pdig.0001586))

→ This is exactly the alert-fatigue risk to design against. Supervision's rules: one nudge per block, one lock, ≤2 check-ins a day, numbers only on request.

### Cognitive profile (what's actually impaired)
Processing speed (most consistent), sustained attention, working memory. Hardest: **multitasking/divided attention**, complex reading and writing, real-time conversation, sensory-rich settings. Accommodations: single-task, close everything else, silence, text-to-speech to offload reading, **work horizontal**, short focus / longer rest, external scaffolding (checklists, calendars), schedule hard thinking for the best hours. ([RTHM cognitive dysfunction](https://www.rthm.com/resources/blogs/me-cfs-cognitive-dysfunction))

Brain fog makes pacing itself hard (time blindness, executive dysfunction), so the structure has to be external and automatic: timers, defaults, positive reinforcement, "treat pacing failures as a system-design problem, not a personal failing." ([ME and more](https://www.meandmore.net/blog/mwsyqsqnpy7j1n3epobd384vm31r8k))

### Stanford / OMF: state of the science, end of 2025
- OMF funds five centers (Stanford – Ron Davis; Harvard – Systrom; Melbourne; Uppsala; Montréal). 17 ME/CFS papers in the last 12 months.
- **Leading hypotheses:** (1) *Itaconate shunt* (Robert Phair / Ron Davis): an infection-time metabolic switch that drains ATP and drives inflammation stays chronically on; tested in E. coli and zebrafish, thousands of drugs screened, 2–3 candidates that switch it off. (2) *Blood flow*: "incontrovertible" evidence of over-relaxed blood vessels and preload insufficiency (Systrom); red blood cells that break down with exertion and move slowly under low oxygen; fewer capillaries in muscle. (3) *Mitochondria*: baseline citrate-synthase and electron-transport problems in muscle biopsies.
- **Treatments in trial:** Mestinon (pyridostigmine) and low-dose naltrexone (OMF LIFT trial); JAK/STAT inhibitors being watched; oxaloacetate RCT (RESTORE ME).
- **Severity may be "how many cells are affected"** by the same process, which would mean one treatment helps everyone.
- **The hopeful part:** when people recover, they recover *completely* — even after years of severe illness — which suggests ME/CFS does not cause permanent tissue damage the way a stroke does. ([Health Rising, OMF directors 2025](https://www.healthrising.org/blog/2025/12/31/open-medicine-foundation-researchers-2025/))

**What this means for managing it now:** nothing in the biology changes the advice — it explains it. Exertion above your (very low) anaerobic threshold spends energy the cells can't regenerate, and each push can lower the baseline. Protect the baseline now so the body is intact when treatments arrive.

## 6. Changes this suggests for Supervision
1. **Horizontal reminders.** Add "go horizontal 10–15 min" as the default break instruction (it already is) and a *separate* mid-morning/mid-afternoon horizontal prompt on meeting-heavy days (BHC: every couple of hours).
2. **Orthostatic budget.** Later, count upright time (desk + meetings + standing) separately from cognitive time; the break screen can suggest working reclined for reading/email.
3. **Nudge frequency stays at the floor.** The RCT evidence says more notifications don't help and drive abandonment. Keep: 1 nudge, 1 lock, ≤2 check-ins.
4. **Weekly "what cost you" report** (Bearable-style correlations): crash days vs prior-day minutes by category, meeting load, and check-in scores.
5. **80/20 rule in the budget.** Daily budget already ~50% of tolerance; keep the day-lock message framed as "keeping your 20% reserve."
6. **Whoop/Baseline hook:** resting HR + 15 bpm ceiling and morning recovery → `dailyBudgetMinutes`.

## 7. Not yet reachable
- **r/cfs**: Reddit blocks my fetch tools, the in-app browser refuses it, and the Chrome extension isn't connected right now. If you connect Claude in Chrome (or paste threads), I'll fold in the community rules of thumb.
- ME Association PACING PDF link returns a web page, not the PDF.
- OMF Canada symposium page and Health Rising via fetch are 403; I read Health Rising through the in-app browser instead.

## 8. Varied breaks: what's safe, and how the planner decides (added Sept 23)

**Question:** do breaks have to be lying-down-eyes-closed, or can they be varied (stretch, foot PT, walk, Pilates, journal, rap, poetry)?

**Evidence**
- True cognitive rest is still eyes closed, lying down, quiet: reading, TV and calls don't count even when reclined ([CFS Self-Help](https://www.cfsselfhelp.org/library/4-nurture-yourself-with-pre-emptive-rest)). If you already work lying down, the *orthostatic* part of rest is mostly covered; the *sensory/cognitive* part isn't.
- Movement is allowed for mild/moderate illness if it's "subaerobic": doesn't raise heart rate, stopped immediately if symptoms rise. Stretching first (1–2 min then rest), then slow walking/swimming; "how fast, how far, how much is not only irrelevant, it can be counterproductive" ([AMMES exercise](https://ammes.org/exercise/), [MEpedia stretching](https://me-pedia.org/wiki/Stretching)).
- Heart-rate ceiling: resting HR + 15 bpm (RTHM) or (220 − age) × 0.6 (Solve M.E.); stop when the alarm sounds; a raised resting HR the next morning means yesterday was too much ([Solve M.E. HR monitor](https://solvecfs.org/using-a-heart-rate-monitor-to-prevent-post-exertional-malaise-in-me-cfs/)).
- ME/CFS shows blunted parasympathetic recovery after exertion ([PMC8509376](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC8509376/)), which is why every active break in the planner ends with 2+ minutes flat.
- No study shows that alternating activity types is protective. It's a *tolerability* strategy (so rest doesn't become unbearable), not an energy strategy.

**Why the morning number:** day-to-day recovery in ME/CFS swings widely (it's common to see green and red mornings in the same week), so the day's break tier comes from the morning reading, not a fixed schedule.

**Planner rules (deterministic, every choice explained)**
| Signal | Effect |
|---|---|
| Whoop recovery red (<34) | rest only |
| Last check-in ≤ 2/5 | rest only |
| ≥ 60 meeting minutes today | rest only ("eyes and ears") |
| ≥ 70% of budget used | rest only |
| Previous break was active | rest (movement is always followed by rest) |
| ≥ 3 active breaks today, or after 5 pm | rest only |
| Yellow (34–66) | stretch, foot PT, journal, music |
| Green (≥ 67) and < 40% load | + walk, Pilates (once, before 3 pm, 20-min break), rap, poetry |
| Always | never the same activity twice in a row; prefer what hasn't been done today; physical breaks show the HR ceiling |
| Peloton | off the list: aerobic by design; revisit only with live HR data and a run of green days |

**Contexts:** places (e.g. home / office) decide which activities exist; switched by Wi-Fi name or `supervisionctl context`.
**Completion tap:** "Did it / Rested instead / Skipped" at the end of each break feeds the log, the calendar and tomorrow's choices.
