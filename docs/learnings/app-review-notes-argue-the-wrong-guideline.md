# App Review notes that pre-empt one guideline can invite another

The 2026-08-13 submission of version 1.0 (build 211) was rejected on
2026-08-27 under **Guideline 4.3(a) — Design: Spam**: "shares a similar
binary, metadata, and/or concept as apps submitted to the App Store by other
developers, with only minor differences."

The App Review notes opened with this:

> This app is a GPL source port of the classic Doom engine (Woof!/Boom
> lineage). … Comparable approved apps: GenZD, RetroArch.

Both sentences were deliberate. They were written to defend **5.2**
(intellectual property — nothing copyrighted is bundled) and **2.5.2** (no
code is downloaded or executed), which are the guidelines a Doom port author
naturally expects to be asked about. Read by a reviewer weighing 4.3(a)
instead, the same paragraph says: *this is a port of someone else's engine*,
and *here are two apps already on the store that do the same thing.* The
rejection's wording tracks it closely enough that the notes are the most
likely trigger.

**A defence is written against a specific charge. State it and you also
choose which charge the reader has in mind.** Naming comparable approved apps
is a precedent argument — it only works on a reviewer already asking "is this
*allowed*?" To one asking "is this a *duplicate*?" it is a confession with the
comparison helpfully supplied.

`docs/app-store/metadata.md` had no mention of 4.3 or spam anywhere in it
before this. The whole submission was planned against the wrong guideline.

**Rules that fall out of this:**

- **Lead with what the app does, not what it descends from.** The notes and
  the §4 description both opened on "source port". Lineage is credibility to
  a Doom player and a liability to a reviewer counting duplicates.
- **Never name another App Store app in review notes.** Precedent you cannot
  see the reasoning behind is not precedent; it is a comparison you supplied.
- **Keep the substantive disclosures.** Everything else in the notes — data
  not code, import is optional, the four-finger cheat gesture — closes a real
  gap and was retained verbatim through the rewrite.

**On the response.** 4.3(a) is answered in Resolution Center, not by
resubmitting: `appStoreReviewDetails` allows `UPDATE` while the version sits
in `REJECTED`, so the notes can be corrected in place with no new build and
no re-entry into the review queue. Silently resubmitting a similar app is the
behaviour 4.3 exists to police, and the first submission waited 14 days in
`WAITING_FOR_REVIEW` before anyone looked at it. Fix the metadata, reply, and
keep the stale build attached; ship accumulated work as the next version once
the version is approved.

**The reviewer's message is not in the API and not in the email.** The public
App Store Connect API exposes only the state (`appStoreState: REJECTED`,
`reviewSubmissions.state: UNRESOLVED_ISSUES`), and both Apple notification
emails withhold the text — the itemised section of the HTML mail is empty.
The message exists only in Resolution Center, behind an interactive login.
Budget for a human to fetch it.
