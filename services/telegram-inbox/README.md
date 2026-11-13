# Private Library inbox for Telegram

This optional Cloudflare Worker is a separate, user-deployed capture service. The Mac feature works without it. It uses Telegram, D1, R2 and a retryable Cloudflare Queue so captures can arrive while the Mac sleeps. Nothing in the development demo is deployed or paired automatically.

The Worker stores only incoming Library capture material and its delivery receipts. Git credentials and LiteLLM keys stay on the Mac. One private Telegram owner is paired once; group chats and other senders are ignored. Incoming text is never executed.

## Set up your private service

1. Create a bot using Telegram's official BotFather, retaining its token privately. Create a Cloudflare account/project with Workers, D1, R2 and Queues enabled. These services may incur charges; select your own account limits.
2. Copy `wrangler.example.toml` to `wrangler.toml`. With the official Wrangler CLI (`npx wrangler@4`), sign in and create the resources:

   ```sh
   npx wrangler@4 d1 create one-ring-library-inbox
   npx wrangler@4 r2 bucket create one-ring-library-inbox-assets
   npx wrangler@4 queues create one-ring-library-ingest
   npx wrangler@4 queues create one-ring-library-ingest-dead-letter
   ```

3. Put the returned D1 database ID in your local configuration. Run the schema:

   ```sh
   npx wrangler@4 d1 execute one-ring-library-inbox --remote --file=schema.sql
   ```

4. Generate independent random secrets (at least 32 random bytes each) and save them through Wrangler's secure prompts:

   ```sh
   npx wrangler@4 secret put BOT_TOKEN
   npx wrangler@4 secret put WEBHOOK_SECRET
   npx wrangler@4 secret put CLIENT_TOKEN
   npx wrangler@4 secret put PAIR_CODE
   npx wrangler@4 deploy
   ```

   `BOT_TOKEN` is BotFather's token. `WEBHOOK_SECRET` protects the Telegram webhook. `CLIENT_TOKEN` is the Mac-only inbox API credential. `PAIR_CODE` is the one-use owner-pairing code. Do not commit these values or paste them into source files. Use independent secrets.

5. Register your deployed HTTPS `/telegram` URL with Telegram's `setWebhook` API and supply `secret_token` equal to `WEBHOOK_SECRET`. Use a local tool which reads secrets securely; avoid putting bot tokens in shell history, printed URLs or logs. Restrict allowed updates to `message` and `edited_message`. The Worker checks `X-Telegram-Bot-Api-Secret-Token` on every delivery.
6. In your private chat with the bot, send `/pair YOUR_PAIR_CODE`. The first valid private sender wins an atomic singleton owner record. Confirm the bot replies that pairing succeeded. Pairing another user requires deliberately resetting the D1 owner record yourself; no unpair endpoint is exposed.
7. In the planner, open **Settings → Library · Telegram inbox**. Enter the deployed service origin and `CLIENT_TOKEN`, then save and enable imports. The token is saved in the existing app Keychain service, under a separate account. Never use your LiteLLM or Git token here.

The Worker supports text, URLs, JPEG photo messages, PNG/JPEG/HEIC documents and UTF-8 Markdown/text documents, up to 20 MB each. Albums settle for five seconds and publish as one capture. If a late album item arrives, a new stable group revision is published; the Mac appends only previously unseen item IDs. Edited Telegram messages are retained as additional source revisions rather than destructively replacing a note's original capture.

Reply to a “Saved to Library inbox” bot acknowledgement to append material to the same note thread. The Mac keeps a durable capture receipt in the same transaction as the note; it acknowledges the hosted capture only after its files and local Git commit are durable. Retried messages, queue delivery and Mac acknowledgements are idempotent. A bot acknowledgement may repeat if Telegram accepted it immediately before a Worker failure, but the saved note remains deduplicated.

## Storage, retention and recovery

R2 attachment bytes and the D1 message row are written before webhook success. The retryable queue publishes capture groups and sends the human-facing acknowledgement. A failed R2 write is not acknowledged. A failed queue send returns an error so Telegram retries the already-durable message. Unimported content is never silently expired.

The default pending-capture limit is 1,000; groups are bounded at 30 items, imports at 20 captures per request and individual files at 20 MB. Capacity or download failures return an error and retain any already-stored content. Monitor Telegram pending updates, Queue retries/dead-letter messages, D1 storage and R2 costs in your own account. Import pending items before raising limits.

This version has **no automatic deletion policy**: acknowledged captures, delivery metadata and attachments remain in D1/R2 until the owner explicitly cleans them up or removes the deployment. This favors recovery and means storage continues to grow. Apply account budgets and plan a retention policy. Do not delete pending message/capture rows or their R2 objects. Before deleting acknowledged data, keep a verified Mac archive. Ordinary note Trash does not erase hosted copies, remote Git history or existing archives.

For queue exhaustion, inspect and redrive the dead-letter queue after fixing the cause. The durable D1 `messages` table and R2 bytes allow `publishGroup` to be retried; do not acknowledge or remove capture data to clear an error. The Mac retries network/import errors, verifies attachment hashes and leaves the capture unacknowledged on local save failure. Authentication errors require fixing Settings; no task or calendar event is created.

Restore the service from your own D1/R2 backups together; metadata-only recovery cannot reconstruct missing image bytes. The application Data archive covers imported Library records and attachments, not this hosted service.

## Offline verification

```sh
node --test worker.test.mjs
```

Tests use Node's built-in SQLite, in-memory R2, a mocked Telegram API and a simulated Queue. They exercise owner validation, durable-before-acknowledgement storage, albums, duplicate deliveries, reply threads, receipt conflicts, queue outages and retries. They make no real network requests. Node 22.13+ with `node:sqlite` is required; validated on Node 25.

Remaining live deployment checks: create resources, apply the schema, install secrets, register the webhook, pair the owner, send a photo/album while the Mac is asleep, verify import and acknowledgement after waking, then verify retry/redrive behavior in your Cloudflare account. These checks need your own service credentials and are not claimed by the offline tests.
