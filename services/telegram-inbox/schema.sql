CREATE TABLE IF NOT EXISTS owner (singleton INTEGER PRIMARY KEY CHECK(singleton=1), user_id TEXT NOT NULL, chat_id TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS messages (id TEXT PRIMARY KEY, group_key TEXT NOT NULL, thread_id TEXT NOT NULL, chat_id TEXT NOT NULL, payload TEXT NOT NULL, updated_at INTEGER NOT NULL);
CREATE INDEX IF NOT EXISTS message_groups ON messages(group_key,updated_at);
CREATE TABLE IF NOT EXISTS captures (id TEXT PRIMARY KEY, thread_id TEXT NOT NULL, payload TEXT NOT NULL, created_at INTEGER NOT NULL, ack_note_id TEXT, ack_at INTEGER);
CREATE INDEX IF NOT EXISTS capture_delivery ON captures(ack_at,created_at);
CREATE TABLE IF NOT EXISTS notified (capture_id TEXT PRIMARY KEY, chat_id TEXT NOT NULL, message_id TEXT NOT NULL, thread_id TEXT NOT NULL);
CREATE UNIQUE INDEX IF NOT EXISTS notification_replies ON notified(chat_id,message_id);
