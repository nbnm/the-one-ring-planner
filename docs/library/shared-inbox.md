# Shared Inbox · 0.26.0

Inbox holds undecided captures. Save text, links, screenshots, multiple images or UTF-8 Markdown/text files without deciding whether the item is work or reference material. Control Option Space and Command N open Inbox capture by default. The capture selector retains explicit Task and Note modes for direct actions; Library → New note opens Note mode.

Saving commits the original locally first. Background AI uses the saved LiteLLM task model to suggest **Task**, **Note** or **Unsorted**, a concise title and searchable project/product/topic tags. The suggestion does not move the item. The shared Library request budget applies; missing configuration, unsupported responses, rate limits and network failures leave the item available. Use its action menu to retry, or choose a destination yourself. Classification uses text, locally extracted attachment text, filenames and URL strings. Links are stored and opened through explicit clicks.

## Arrange the capture

- Drag a capture into a visible priority quadrant, or use **Move → Q1–Q4**. Confirm the task title, priority and required duration. Cancel keeps it in Inbox. Confirmation creates the task and its original capture together. Q2 retains the existing time-slot suggestion workflow.
- Drag onto **Library** in the navigation, onto the Library workspace beside Inbox, or use **Move → Library · Note**. This creates a Library note with its exact original text, source URL, tags and attachments.
- Either destination overrides the AI suggestion. A suggested Note can become a task, and a suggested Task can become a note.
- Existing task-based Inbox records also offer **Move → Library · Note**, retaining their original capture, supporting notes, context and images. Existing planner tasks are left in place until an explicit move.

The main Inbox destination provides search, item details, manual title/tag corrections, and an archive collection. Archive is reversible through **Restore to Inbox**. Copy icons copy original text or the individual URL and briefly show a checkmark. Links are clickable in Inbox, task details and Library readers.

## Persistence and recovery

Neutral records and their routing receipts live in `Data/inbox-items/*.json`. A saved neutral capture creates neither a planner task nor a Library note. Original source fields are immutable; suggestions and user metadata remain distinct. Destination creation and the routing receipt share the existing transaction journal and commit. Stable capture identities protect retries, including after a saved item has been classified or placed. Late AI replies cannot overwrite a route or user corrections. Attachment bytes remain content-addressed in the shared asset store.

Text/image capture drafts and retry checkpoints live under Local. Drafts survive restart. The Data archive and verified remote backup include Inbox records and original attachments; restore previews now report an Inbox count. Existing limits remain: 2 MB source text, 20 MB per attachment and 256 MB combined attachment storage.

## Controlled verification

Run the core and native media checks:

```sh
./scripts/test.sh
./scripts/test-library.sh
./scripts/test-meetings.sh
swift run -c release RingCoreChecks
```

The six additional core groups cover neutral capture, journal/retry idempotence, destination overrides, duration gating, late AI replies, manual corrections, safe links, archive restore, legacy conversion and validated model classification. Native clipboard checks include URL-only paste. Native isolated QA verified actual drags into Library and Q1, Cancel before placement, a two-image/link/code capture, exact copy through the pasteboard, and archive/restore in dark mode. Only synthetic fixtures and mocked AI responses were used; production model quality and connectivity depend on the configured gateway.

For an isolated native demo:

```sh
open -n "build/The One Ring Planner.app" --args --inbox-demo --demo-light
```

Use `--demo-dark --demo-reduce-motion` for the other appearance. Demo suggestions are synthetic and never contact a model, publish a calendar event or read the regular workspace.

Image-only Command-V was repaired in 0.26.1: native text editors now advertise attachment formats to macOS so the Paste menu command reaches the capture handler. The native clipboard suite includes this responder-path regression.
