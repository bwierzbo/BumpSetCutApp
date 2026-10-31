---
name: net-ai-proposals-pilot-direction
status: accepted
created: 2026-10-31T18:53:32Z
updated: 2026-10-31T18:53:32Z
source: owner, delivered to Claude Code on 2026-10-31 (late morning, MDT)
---

> Verbatim record of the owner's direction, reproduced as received. In summary:
> - A 10-recording pilot of AI-assisted net-corner proposals is authorised: Claude's vision proposes the four corners of each recording's net on the Net labels tab's frame; the owner approves or corrects them in RallyLab, and only that confirmation makes a training label.
> - Exclusions (withheld closure, aliases, final test, handheld) are verified before any frame is extracted; the exposure is recorded before inference, or the inference is refused; proposals live apart from `net-labels.json`.
> - Stop after the pilot: no scaling to the 138 recordings, no training, no dataset export, no production detector change, no merge, until the owner has reviewed the previews and the implementation.
>
> Implementation: [NET_MODEL_PLAN.md](../ml-roadmap/NET_MODEL_PLAN.md) §2, "AI-assisted proposals". Logged as a decision when the owner approves the workflow for the remaining recordings.

# BumpSetCut — Claude-Assisted Net Corner Labeling

I want you to help automate the manual net-labeling process using your vision capabilities.

Rather than having me draw the four corners of the volleyball net on all 138 eligible recordings, I want you to inspect the frames yourself, estimate the net corners and prepare labels that I can quickly approve or correct in RallyLab.

I authorize a **10-recording pilot of AI-assisted proposals**, subject to the safeguards below.

## 1. Use the existing RallyLab infrastructure

Reuse the current Net labels system, including:

- `NetQuad` and its four named corners
- Recording fingerprints and frame timestamps
- The split manifest and withheld-recording exclusions
- Existing confirmed labels and box-only annotations
- The `net_proposal` exposure ledger mechanism

Do not change the existing confirmed annotations.

Do not create a separate incompatible labeling format.

## 2. Extract eligible frames

Select 10 eligible, fixed-camera development recordings that still need corner labels.

Use the existing frame-selection rules.

Before extracting anything, verify the complete withheld closure, aliases, final-test restrictions and handheld exclusions.

No withheld or protected footage may be opened, decoded, transmitted to an AI service, or included in this pilot.

Create a small working directory containing the selected upright frames and a manifest with recording ID, timestamp, dimensions, fingerprint and image hash.

## 3. Use your vision to identify the net

Actually inspect each frame using your image-reading capability.

For each image, locate the volleyball net and identify:

- Top-left: left endpoint of the net's upper tape
- Top-right: right endpoint of the upper tape
- Bottom-right: bottom corner where the mesh meets the right post
- Bottom-left: bottom corner where the mesh meets the left post

These are the net's physical corners, not the corners of a rectangular object-detection box.

Provide four coordinates in the existing `NetQuad` format (Vision-normalized, bottom-up), plus a confidence assessment and reason for uncertainty.

If the net is not visible enough to identify reliably, mark the recording `needs_manual_review`. Do not invent corners.

## 4. Provenance and exposure

Record each AI-model exposure before invoking vision inference. Use a distinct model/run reference under the appropriate ledger mechanism.

Include the frame hash, recording fingerprint, model identity and timestamp in the proposal's provenance.

If the exposure record cannot be written, refuse the inference.

Do not describe AI-generated points as human-confirmed ground truth.

## 5. RallyLab integration

Store the results in a separate AI-proposal file, not directly in `net-labels.json`.

Implement the smallest safe integration that lets RallyLab:

- Load the AI-generated four-corner proposal for the matching recording and frame
- Display the proposed points over the image
- Let me drag any incorrect corner
- Confirm the completed label using the existing human-confirmation process
- Reject or skip an incorrect proposal

Only my confirmation converts an AI proposal into an approved training label.

Preserve any existing box-only label as a separate original record until I confirm its four corners.

## 6. Verify quality

Generate an image preview for each of the 10 recordings with the four proposed corners and net outline overlaid.

Check the coordinate conversion against the original upright image, not a cropped or resized image.

Pay particular attention to the top tape endpoints because errors there directly affect the above-net gate.

Report how many predictions were confident, uncertain, and unable to identify a net.

## 7. Stop after the pilot

Do not automatically process all 138 recordings yet.

First show me the 10 annotated previews and the implementation/test results.

Do not train the net model, export a final training dataset, change production detectors, merge a PR, or access protected holdouts.

Once I review the quality and approve the workflow, we can scale it to the remaining eligible recordings.
