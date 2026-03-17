const express = require('express');
const bcrypt = require('bcryptjs');
const cors = require('cors');
const jwt = require('jsonwebtoken');

// Optional local dev support: load environment variables from backend/.env
try {
  require('dotenv').config();
} catch (_) {
  // dotenv not installed; ignore
}

const app = express();
app.use(cors());
app.use(express.json());

// Postgres (for cloud-ready persistence)
const db = require('./db');
const pool = db.pool;
let dbReady = false;
let lastDbError = null;
let lastDbAttemptAt = 0;

const JWT_SECRET = process.env.JWT_SECRET || 'dev-secret';

const emailRegex = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;
function validateEmail(email) {
  return typeof email === 'string' && emailRegex.test(email.trim());
}

function validatePassword(pw) {
  return typeof pw === 'string' && pw.length >= 6;
}

async function ensureDbReady() {
  if (dbReady) return true;
  const now = Date.now();
  // Avoid hammering the DB (and spamming logs) when it's down.
  if (now - lastDbAttemptAt < 3000) return false;
  lastDbAttemptAt = now;
  try {
    await db.ensureTables();
    dbReady = true;
    lastDbError = null;
    return true;
  } catch (e) {
    dbReady = false;
    const rawMessage = e && e.message ? String(e.message) : String(e);
    lastDbError = {
      code: e && e.code ? String(e.code) : undefined,
      message: rawMessage.replace(/[\r\n]+/g, ' ').trim(),
    };
    console.error('DB not ready:', lastDbError);
    return false;
  }
}

function getDatabaseUrlInfo() {
  const url = process.env.DATABASE_URL;
  if (!url) return { present: false };
  try {
    const u = new URL(url);
    const database = u.pathname ? u.pathname.replace(/^\//, '') : null;
    const host = u.hostname || null;
    const looksPlaceholder =
      host === 'HOST' ||
      database === 'DBNAME' ||
      (typeof host === 'string' && host.toUpperCase() === 'HOST') ||
      (typeof database === 'string' && database.toUpperCase() === 'DBNAME');
    return {
      present: true,
      host,
      port: u.port ? Number(u.port) : null,
      database,
      scheme: u.protocol ? u.protocol.replace(':', '') : null,
      looksPlaceholder,
    };
  } catch (e) {
    return { present: true, parseError: true };
  }
}

app.get('/health', async (req, res) => {
  const ok = await ensureDbReady();
  const databaseUrl = getDatabaseUrlInfo();

  // Provide an actionable hint when someone accidentally sets the example string.
  const hint = databaseUrl.present && databaseUrl.looksPlaceholder
    ? 'DATABASE_URL looks like the example placeholder. On Render, set DATABASE_URL to your Postgres "Internal Database URL".'
    : null;
  return res.json({
    ok: true,
    dbReady: ok,
    dbError: ok ? null : lastDbError,
    hasDatabaseUrl: Boolean(process.env.DATABASE_URL),
    databaseUrl,
    sslEnabled: Boolean(db.sslEnabled),
    hint,
  });
});

app.get('/', (req, res) => {
  return res.json({
    ok: true,
    service: 'aether-backend',
    endpoints: {
      health: '/health',
      signup: 'POST /signup',
      login: 'POST /login',
      users: 'GET /users (Bearer)',
      messages: 'GET /chats/:id/messages (Bearer)',
      ws: '/ws?token=...'
    },
  });
});

app.post('/signup', async (req, res) => {
  const { email, password } = req.body || {};
  if (!validateEmail(email)) return res.status(400).json({ error: 'Invalid email' });
  if (!validatePassword(password)) return res.status(400).json({ error: 'Password must be at least 6 characters' });

  if (!(await ensureDbReady())) return res.status(503).json({ error: 'Database not ready' });

  const normalizedEmail = email.trim().toLowerCase();

  const existing = await pool.query('SELECT id FROM users WHERE email = $1 LIMIT 1', [normalizedEmail]);
  if (existing.rowCount > 0) return res.status(409).json({ error: 'User already exists' });

  const passwordHash = await bcrypt.hash(password, 10);
  const created = await pool.query(
    'INSERT INTO users(email, password_hash) VALUES($1,$2) RETURNING id, email',
    [normalizedEmail, passwordHash]
  );
  const user = created.rows[0];

  const token = jwt.sign({ id: user.id, email: user.email }, JWT_SECRET, { expiresIn: '1h' });
  return res.status(201).json({ id: user.id, email: user.email, token });
});

app.post('/login', async (req, res) => {
  const { email, password } = req.body || {};
  if (!validateEmail(email)) return res.status(400).json({ error: 'Invalid email' });
  if (!validatePassword(password)) return res.status(400).json({ error: 'Invalid password' });

  if (!(await ensureDbReady())) return res.status(503).json({ error: 'Database not ready' });

  const normalizedEmail = email.trim().toLowerCase();

  const result = await pool.query('SELECT id, email, password_hash FROM users WHERE email = $1 LIMIT 1', [normalizedEmail]);
  if (result.rowCount === 0) return res.status(401).json({ error: 'Invalid credentials' });
  const user = result.rows[0];

  const ok = await bcrypt.compare(password, user.password_hash);
  if (!ok) return res.status(401).json({ error: 'Invalid credentials' });

  const token = jwt.sign({ id: user.id, email: user.email }, JWT_SECRET, { expiresIn: '1h' });
  return res.json({ message: 'Login successful', user: { id: user.id, email: user.email }, token });
});

function verifyToken(req, res, next) {
  const auth = req.headers.authorization;
  if (!auth || !auth.startsWith('Bearer ')) return res.status(401).json({ error: 'Missing token' });
  const token = auth.split(' ')[1];
  try {
    const payload = jwt.verify(token, JWT_SECRET);
    req.user = payload;
    return next();
  } catch (e) {
    return res.status(401).json({ error: 'Invalid token' });
  }
}

app.get('/users', verifyToken, async (req, res) => {
  if (!(await ensureDbReady())) return res.status(503).json({ error: 'Database not ready' });
  try {
    const result = await pool.query('SELECT id, email FROM users ORDER BY id ASC');
    return res.json(result.rows);
  } catch (e) {
    console.error('Failed to fetch users:', e);
    return res.status(500).json({ error: 'Failed to fetch users' });
  }
});

// Fetch messages for a chat (persisted in Postgres)
app.get('/chats/:id/messages', verifyToken, async (req, res) => {
  const chatId = parseInt(req.params.id, 10) || 1;
  if (!(await ensureDbReady())) return res.status(503).json({ error: 'Database not ready' });
  try {
    const result = await pool.query(
      'SELECT id, chat_id, sender_email, e2ee_flag, ciphertext, nonce, mac, plaintext, time FROM messages WHERE chat_id = $1 ORDER BY time ASC',
      [chatId]
    );
    return res.json(result.rows);
  } catch (e) {
    console.error('Failed to fetch messages:', e);
    return res.status(500).json({ error: 'Failed to fetch messages' });
  }
});

const http = require('http');
const WebSocket = require('ws');

// Create HTTP server and upgrade to WebSocket server at /ws
const server = http.createServer(app);
const wss = new WebSocket.Server({ server, path: '/ws' });

// Simple set of clients
const clients = new Set();

wss.on('connection', (ws, req) => {
  // Expect token in query string: /ws?token=...
  try {
    const url = new URL(req.url, `http://${req.headers.host}`);
    const token = url.searchParams.get('token');
    if (!token) {
      ws.close(1008, 'Missing token');
      return;
    }
    let payload;
    try {
      payload = jwt.verify(token, JWT_SECRET);
    } catch (e) {
      ws.close(1008, 'Invalid token');
      return;
    }
    ws.user = payload; // attach decoded token payload
  } catch (e) {
    ws.close(1008, 'Invalid connection');
    return;
  }

  clients.add(ws);
  console.log('WebSocket client connected. Total:', clients.size);

  ws.on('message', async (message) => {
    const text = typeof message === 'string' ? message : message.toString();
    const sender = (ws.user && ws.user.email) ? ws.user.email : 'unknown';
    let outPayload;
    try {
      const parsed = JSON.parse(text);
      const chatId = parsed.chat_id || 1;
      const now = new Date();
      if (parsed.e2ee_flag === true) {
        // Encrypted message: store ciphertext (and optional nonce/mac) and relay without decrypting
        outPayload = {
          sender,
          e2ee_flag: true,
          ciphertext: parsed.ciphertext ?? parsed.text ?? String(parsed),
          nonce: parsed.nonce,
          mac: parsed.mac,
          time: now.toISOString(),
          chat_id: chatId,
        };

        // Persist encrypted message (best effort)
        if (await ensureDbReady()) {
          try {
            await pool.query(
              'INSERT INTO messages(chat_id, sender_email, e2ee_flag, ciphertext, nonce, mac, plaintext, time) VALUES($1,$2,$3,$4,$5,$6,$7,$8)',
              [chatId, sender, true, outPayload.ciphertext, outPayload.nonce ?? null, outPayload.mac ?? null, null, now]
            );
          } catch (e) {
            console.error('DB insert error (encrypted):', e);
          }
        }
      } else {
        const plain = parsed.text ?? String(parsed);
        outPayload = { sender, text: plain, time: now.toISOString(), chat_id: chatId };
        // Persist plaintext message (best effort)
        if (await ensureDbReady()) {
          try {
            await pool.query(
              'INSERT INTO messages(chat_id, sender_email, e2ee_flag, ciphertext, nonce, mac, plaintext, time) VALUES($1,$2,$3,$4,$5,$6,$7,$8)',
              [chatId, sender, false, null, null, null, plain, now]
            );
          } catch (e) {
            console.error('DB insert error (plain):', e);
          }
        }
      }
    } catch (e) {
      // Non-JSON -> treat as plaintext
      const now = new Date();
      outPayload = { sender, text: text, time: now.toISOString(), chat_id: 1 };
      if (await ensureDbReady()) {
        try {
          await pool.query(
            'INSERT INTO messages(chat_id, sender_email, e2ee_flag, ciphertext, nonce, mac, plaintext, time) VALUES($1,$2,$3,$4,$5,$6,$7,$8)',
            [1, sender, false, null, null, null, text, now]
          );
        } catch (ex) {
          console.error('DB insert error (raw):', ex);
        }
      }
    }

    const out = JSON.stringify(outPayload);
    for (const c of clients) {
      if (c.readyState === WebSocket.OPEN) c.send(out);
    }
  });

  ws.on('close', () => {
    clients.delete(ws);
    console.log('WebSocket client disconnected. Total:', clients.size);
  });
});

// 404 handler (after all routes)
app.use((req, res) => res.status(404).json({ error: 'Not found' }));

const PORT = process.env.PORT || 8080;

(async () => {
  try {
    await db.ensureTables();
    console.log('Database tables ensured');
    dbReady = true;
  } catch (e) {
    console.error('Failed to ensure DB tables:', e);
    dbReady = false;
  }

  server.listen(PORT, () => console.log(`Aether backend listening on port ${PORT}`));
})();
