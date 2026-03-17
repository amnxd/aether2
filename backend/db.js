const { Pool } = require('pg');

const connectionString = process.env.DATABASE_URL || undefined;

function shouldEnableSslForDatabaseUrl(url) {
  if (!url) return false;
  const forced = (process.env.DATABASE_SSL || '').toLowerCase();
  if (forced === 'true' || forced === '1' || forced === 'yes') return true;
  if (forced === 'false' || forced === '0' || forced === 'no') return false;

  // Render/managed Postgres commonly requires SSL; local dev does not.
  const isLocal = url.includes('localhost') || url.includes('127.0.0.1');
  if (isLocal) return false;

  const sslMode = (process.env.PGSSLMODE || '').toLowerCase();
  if (sslMode === 'require' || sslMode === 'verify-ca' || sslMode === 'verify-full') return true;

  // Default to SSL for non-local DATABASE_URL.
  return true;
}

const sslEnabled = shouldEnableSslForDatabaseUrl(connectionString);
const ssl = sslEnabled ? { rejectUnauthorized: false } : undefined;

const pool = new Pool({
  connectionString,
  ssl,
});

async function ensureTables() {
  // Create Users, Chats, Messages tables
  await pool.query(`
    CREATE TABLE IF NOT EXISTS users (
      id SERIAL PRIMARY KEY,
      email TEXT UNIQUE NOT NULL,
      username TEXT UNIQUE,
      password_hash TEXT NOT NULL,
      created_at TIMESTAMP WITH TIME ZONE DEFAULT now()
    );

    CREATE TABLE IF NOT EXISTS chats (
      id SERIAL PRIMARY KEY,
      name TEXT,
      is_group BOOLEAN DEFAULT false,
      is_global BOOLEAN DEFAULT false,
      e2ee_enabled BOOLEAN DEFAULT false,
      e2ee_key_base64 TEXT,
      created_at TIMESTAMP WITH TIME ZONE DEFAULT now()
    );

    CREATE TABLE IF NOT EXISTS chat_members (
      chat_id INTEGER REFERENCES chats(id) ON DELETE CASCADE,
      user_id INTEGER REFERENCES users(id) ON DELETE CASCADE,
      added_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
      PRIMARY KEY(chat_id, user_id)
    );

    CREATE TABLE IF NOT EXISTS messages (
      id SERIAL PRIMARY KEY,
      chat_id INTEGER REFERENCES chats(id) ON DELETE CASCADE,
      sender_email TEXT,
      e2ee_flag BOOLEAN DEFAULT false,
      ciphertext TEXT,
      nonce TEXT,
      mac TEXT,
      plaintext TEXT,
      time TIMESTAMP WITH TIME ZONE DEFAULT now()
    );

    CREATE TABLE IF NOT EXISTS user_devices (
      id SERIAL PRIMARY KEY,
      user_id INTEGER REFERENCES users(id) ON DELETE CASCADE,
      platform TEXT,
      fcm_token TEXT UNIQUE NOT NULL,
      updated_at TIMESTAMP WITH TIME ZONE DEFAULT now()
    );
  `);

  // Forward-compatible schema updates
  await pool.query('ALTER TABLE users ADD COLUMN IF NOT EXISTS username TEXT');
  // Ensure uniqueness (case-sensitive). The app normalizes usernames to lowercase.
  await pool.query('CREATE UNIQUE INDEX IF NOT EXISTS users_username_unique ON users(username)');

  await pool.query('ALTER TABLE chats ADD COLUMN IF NOT EXISTS is_global BOOLEAN DEFAULT false');
  await pool.query('ALTER TABLE chats ADD COLUMN IF NOT EXISTS e2ee_enabled BOOLEAN DEFAULT false');
  await pool.query('ALTER TABLE chats ADD COLUMN IF NOT EXISTS e2ee_key_base64 TEXT');
  // Ensure only one global chat.
  await pool.query('CREATE UNIQUE INDEX IF NOT EXISTS chats_one_global_true ON chats(is_global) WHERE is_global');

  // If table existed from older schema, add missing columns.
  await pool.query('ALTER TABLE messages ADD COLUMN IF NOT EXISTS nonce TEXT');
  await pool.query('ALTER TABLE messages ADD COLUMN IF NOT EXISTS mac TEXT');

  await pool.query('CREATE INDEX IF NOT EXISTS user_devices_user_id_idx ON user_devices(user_id)');

  // Ensure a single global chat exists.
  const existingGlobal = await pool.query('SELECT id FROM chats WHERE is_global = true LIMIT 1');
  if (existingGlobal.rowCount === 0) {
    await pool.query('INSERT INTO chats(name, is_group, is_global) VALUES($1,$2,$3)', ['Global', true, true]);
  }
}

module.exports = {
  pool,
  ensureTables,
  sslEnabled,
};
