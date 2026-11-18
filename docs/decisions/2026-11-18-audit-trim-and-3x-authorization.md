---
name: audit-trim-and-3x-authorization
status: accepted (owner authorisation); D-040
created: 2026-11-18T16:29:43Z
updated: 2026-11-18T16:29:43Z
source: owner, delivered to Claude Code on 2026-11-18 from the iPhone during the pilot review
---

> Verbatim record of the owner's request and authorisation, reproduced as received, with the three questions the
> authorisation answers. In summary: a one-tap trim for boundary errors on the phone and a 3× speed (PR #191, merged and
> shipped to internal TestFlight on this authorisation); recorded trims applied to the neighbouring rally marks on the
> Mac, built now and applied only after the pilot is finished; 3× counts toward `clean`.

**The owner's request (2026-11-18, with a screenshot of the Audit tab):**

What I am seeing is most common is just end at the start of these dead times or the serve is just contacted, I need a way to trim the dead time and that trimmed time is added back to their adjacent rallies that they were cut from. I also want 2X and 3x

**The questions put to the owner (Claude Code, 2026-11-18):**

1. **Merge #191 and ship an internal TestFlight build?** Codex has not reviewed it yet.
2. **Apply trims to the rally marks on the Mac?** I would build a step in the marking pass that extends the neighbouring mark to each recorded trim, with you confirming each one. Moving a mark changes what the pilot's draw was made from, so those intervals need a new draw afterwards. I recommend building it now but applying it only after the pilot is finished.
3. **Should 3× count toward Clean?** That needs a new protocol document replacing the frozen one, and a call on the verdicts already given under the 2× rule. I recommend leaving the cap at 2×.

**The owner's answer (2026-11-18):**

Yes on all of those and what's this error
