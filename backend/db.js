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

const ssl = shouldEnableSslForDatabaseUrl(connectionString)
  ? { rejectUnauthorized: false }
  : undefined;

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
      password_hash TEXT NOT NULL,
      created_at TIMESTAMP WITH TIME ZONE DEFAULT now()
    );

    CREATE TABLE IF NOT EXISTS chats (
      id SERIAL PRIMARY KEY,
      name TEXT,
      is_group BOOLEAN DEFAULT false,
      created_at TIMESTAMP WITH TIME ZONE DEFAULT now()
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
  `);

  // If table existed from older schema, add missing columns.
  await pool.query('ALTER TABLE messages ADD COLUMN IF NOT EXISTS nonce TEXT');
  await pool.query('ALTER TABLE messages ADD COLUMN IF NOT EXISTS mac TEXT');

  // Ensure there's at least one default chat (id will be serial)
  const chk = await pool.query('SELECT count(*) as c FROM chats');
  const count = parseInt(chk.rows[0].c, 10);
  if (count === 0) {
    await pool.query("INSERT INTO chats(name, is_group) VALUES($1,$2)", ['general', false]);
  }
}

module.exports = {
  pool,
  ensureTables,
};
