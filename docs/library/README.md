# Personal reference Library

Library is a destination inside The One Ring Planner. Notes, task drafts and meeting data remain separate. Saving a note creates no task, plan or Google event.

## Capture and reuse

Open **Library → New note**, or use the capture panel’s **Inbox / Task / Note** selector. Global capture now opens the [shared Inbox](shared-inbox.md), with advisory AI Task/Note suggestions; explicit Task mode retains AI review. Task microphone recording and Control Option R were removed in 0.25.0; meeting recording remains in The Eye. The two drafts remain independent. Note mode saves locally before background work starts; no title, folder, tag or AI response is required.

Paste exact text/Markdown, a URL, multiple clipboard images or rich text containing images; drag files into the note text area, or use **Attach**. PNG, JPEG, HEIC and UTF-8 Markdown/text files are supported. Original images are retained byte-for-byte. The pilot limits attachments to 20 MB each and 256 MB total; each body, prompt and comment field supports up to 2 MB. Files exceeding a limit fail explicitly and remain in the draft; source text is never truncated to the task cleanup client's 6,000-character limit.

Gallery and list views share query, collection and selection. **All notes / Unreviewed / Favorites** is the single collection menu. Additional tag/kind filters, Archive and Trash live in the action menu. Selecting a note opens a temporary reader; Escape returns to the collection. The reader provides exact copy, editing, full-size images and Markdown export with original attachments. About this note contains source, dates, AI details, original captures and local Git history. Trash is recoverable; restoring keeps source material and edits.

## Storage and recovery

The existing `DataRepository` now coordinates task and note writes through one per-working-tree recursive lock and one journal location. Notes live in `Data/notes/*.json`, content-addressed originals in `Data/note-assets`, and Telegram receipts in `Data/note-imports`. Neutral Inbox captures and routing receipts live in `Data/inbox-items`; planner tasks and Library notes remain separate. The extended journal references validated staged files under `Local/library-staging`; older task-only journals remain recoverable. Local commits include only the declared transaction paths and do not absorb unrelated staged files.

Capture drafts, OCR/search/vector data, thumbnails, jobs and service configuration are under `Local`, outside Git. A damaged note is reported without preventing other notes or planner records from loading. Failed saves keep the draft and any recoverable staged content; local commit success and remote backup success are distinct.

### Private backup

Configure **Settings → Data & backup → Private GitHub remote** with a separate private HTTPS GitHub repository and a suitable GitHub token. The token stays in the existing app Keychain service. GitHub private visibility is checked when configuring and before every push. The public application source repository is blocked. This adapter currently supports GitHub HTTPS only; SSH and other hosts require a future adapter.

This remote backs up **all current and historical Data content**, including tasks, captures, routines, plans, notes and images. Git cannot exclude prior task history using a path-limited push. Notes-only backup would require a distinct export repository. Meeting recordings are outside Data and are not included in this remote backup.

Ordinary Git is the supported storage policy in this version: 20 MB per original attachment and 256 MB total. LFS/filter configurations and LFS pointers are rejected. The app does not claim that LFS objects have uploaded. Growing beyond the bounded policy requires a separately verified LFS/runtime/host/quota/object-upload implementation or a different attachment store.

Pushes debounce after saves and run off the main actor. **Back up now** is available. A successful remote state requires the intended commit to match the remote ref after pushing; network, authentication, storage and conflict errors do not become a green backup state. The app never force-pushes or merges remote changes into the active workspace. Conflicting versions remain available in separate restore previews.

### Independent archives and restore

**Export Data archive** creates a portable `.ringbackup` directory containing a manifest, current canonical planner/Library records, and actual attachment bytes. **Export full-app archive** additionally includes Meetings, and is blocked while recording or processing. Neither contains Keychain credentials, signing keys or prior Git history. Remote Git backup retains history; archives are independent current-state snapshots. Keep the entire directory together when copying it to other storage.

Archive and remote restore build a separate workspace, validate schema/path/attachment hashes, create fresh local Git history without imported hooks, and rebuild the local index. A preview shows note/task counts and whether Meetings is included. Choosing it affects the **next launch**, preserves the current workspace, and requires that recording, processing and saves are idle. Calendar sync and saved calendar writes start suspended until you review them in Settings. Source archives and conflict previews are preserved on failure.

Normal deletion and Trash do not erase older Git versions, hosted captures or existing archives.

## AI, OCR and search

Library reuses the saved LiteLLM gateway and Keychain API key, with a separate schema and model options under **Settings → Library → AI organization & search**. Saving always works without AI. Automatic organization is enabled once by the 0.25.0 update at the owner’s request; later Settings choices are respected. Per-note AI exclusion is available in Edit. Automatic processing never executes captured prompts or skills.

Local Apple Vision OCR indexes English and Russian image text; attached UTF-8 skills/text are indexed even when the note also has its own body. Keyword matching searches titles, bodies, prompts, comments, tags, source URLs, summaries and extracted text, and stays available offline. OCR and model failures leave the original note intact. Background jobs checkpoint locally and provide explicit retry actions and bounded backoff for transient failures.

Automatic organization can suggest title, summary, tags, kinds, image descriptions and related references. User title/tag/kind corrections take precedence; results for stale revisions or changed gateway configuration are discarded. Large references stay complete locally while AI receives a labelled bounded excerpt.

Vision and embeddings are verified independently with synthetic requests. Images are sent only when the user enables thumbnail uploads and the current gateway/vision alias passed verification. Embeddings require a valid nonzero vector and consistent dimensions from the configured alias. A small local vector scan provides **Find by meaning**; keyword results remain available if the service fails or indexing has not finished. Source text and embeddings are not sent to a second provider.

A monthly **request-count** budget applies to organization, embeddings, queries, capability probes and retries; this is not a monetary spending estimate. Unsupported aliases, invalid schemas, rate limits and used-up budgets are explicit. **Generate design prompt** is a separate confirmed note action and saves a new reusable prompt; it does not run it or overwrite the original prompt.

## Telegram

See [the hosted service guide](../../services/telegram-inbox/README.md). The optional Worker/D1/R2/Queue inbox is deployed and paired by the owner. It persists incoming attachment bytes and message metadata before acknowledging capture, groups albums, supports reply-to-acknowledgement additions and retains retryable delivery receipts. The Mac imports through the same Library transaction path, acknowledges only after durable commit, and marks notes Unreviewed. Git and AI credentials never go to the Worker.

The service currently retains acknowledged and unacknowledged content until owner-managed cleanup. Apply Cloudflare account/storage budgets; no automatic retention purge is claimed.

## Isolated demo and controlled verification

Build the native app with `./scripts/build-app.sh`, then launch its built bundle in example mode:

```sh
open -n "build/The One Ring Planner.app" --args --library-demo
```

This flag implies demo mode, uses temporary Data/Local/Meetings folders and separate preferences/Keychain services, seeds fictional Shire/Fellowship reference notes, and disables external AI, Telegram and remote backup calls. It is the same native application, not a web mockup or separate Library product. Do not launch it without this flag when doing isolated QA.

Add `--demo-light` or `--demo-dark` to inspect either appearance, and `--demo-reduce-motion` to disable Library transitions without changing system preferences. These switches apply only in example mode. Every launch creates a new temporary workspace. The local QA bundle under `build/Library QA.app` also has an isolation flag, so reopening that QA bundle cannot load the regular workspace.

Verification commands:

```sh
./scripts/test.sh
./scripts/test-audio-input.sh
./scripts/test-voice.sh
./scripts/test-meetings.sh
./scripts/test-library.sh  # native media/OCR plus hosted-inbox checks; Node 22.13+ required
swift build
swift run -c release RingCoreChecks
```

The core checks use temporary repositories, a local bare Git remote and mocked HTTP responses. Worker checks use built-in SQLite and in-memory/mock services. No real planner records, recordings, API keys, Google events or data remotes are used.

Validated for 0.24.0 build 38: 172 core checks in debug and optimized release, 11 audio input checks, 6 voice lifecycle checks, 45 meeting audio checks, 9 native Library media checks and 9 Worker checks. Native QA additionally verified independent Task/Note drafts, literal code/tabs/Cyrillic, mixed PNG/Markdown capture, editing, favorite/Trash/restore, exact-byte export, keyboard Space/Return/arrows/Escape and focus return, accessibility labels, light/dark appearances, Reduce Motion, capture during a generated-audio meeting, and separate archive restore preview. This checked accessibility labels and focus through the native accessibility tree; it was not a spoken VoiceOver usability study.

Live setup still needs the owner's private GitHub remote/token, LiteLLM aliases and optional Telegram deployment. Production visibility/authentication, actual model quality/cost, real remote uploads/restore and sleeping-Mac capture require those credentials and are not claimed by mocked checks.


## 0.25.0 capture and Shire layout update

Task mode now accepts the same literal clipboard input and multiple original images as Note mode. A mixed clipboard inserts its text and attaches each image; rich-text image attachments are preserved individually instead of using a flattened preview. Both capture modes show image thumbnails. Selected task proposals share the source images and retain the original capture receipt; task details open the saved images. Images join the task/capture journal and survive archives and restore. Existing tasks decode with no images, without rewriting unrelated records. The 20 MB per-original and 256 MB combined attachment policy applies to task and Library images.

Task review sends up to 12 bounded thumbnails to the saved task model and suggests project/product/topic tags. Choose a vision-capable model for image interpretation. A gateway failure leaves text/images available for retry or manual review. Library uses its independent background organizer, local OCR and configured model/capability settings. Original source text stays exact. Demo mode never calls a gateway; its task proposals and tags are explicitly synthetic.

Task microphone controls, application/menu-bar actions, the recording shortcut and runtime speech-capture implementation are removed. Legacy voice fixtures remain under Tests only. The Eye still records and transcribes meetings.

The layout uses warm parchment, moss-green navigation, rounded selections and an original native landscape of rolling hills and a round-door cottage. Both appearances keep clear text contrast; the landscape has no motion or accessibility-tree clutter.

See [Shared Inbox · 0.26.0](shared-inbox.md) for capture, advisory classification, destination overrides, link handling and recovery verification.
