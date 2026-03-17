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

const push = require('./push');

const JWT_SECRET = process.env.JWT_SECRET || 'dev-secret';

function normalizeUsername(username) {
  return (username ?? '').toString().trim().toLowerCase();
}

function validateUsername(username) {
  const u = normalizeUsername(username);
  if (!u) return false;
  // 3-24 chars, letters/numbers/underscore
  if (u.length < 3 || u.length > 24) return false;
  return /^[a-z0-9_]+$/.test(u);
}

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
  const { email, password, username } = req.body || {};
  if (!validateEmail(email)) return res.status(400).json({ error: 'Invalid email' });
  if (!validatePassword(password)) return res.status(400).json({ error: 'Password must be at least 6 characters' });
  if (!validateUsername(username)) return res.status(400).json({ error: 'Invalid username' });

  if (!(await ensureDbReady())) return res.status(503).json({ error: 'Database not ready' });

  const normalizedEmail = email.trim().toLowerCase();
  const normalizedUsername = normalizeUsername(username);

  const existing = await pool.query('SELECT id FROM users WHERE email = $1 LIMIT 1', [normalizedEmail]);
  if (existing.rowCount > 0) return res.status(409).json({ error: 'User already exists' });

  const existingUsername = await pool.query('SELECT id FROM users WHERE username = $1 LIMIT 1', [normalizedUsername]);
  if (existingUsername.rowCount > 0) return res.status(409).json({ error: 'Username already taken' });

  const passwordHash = await bcrypt.hash(password, 10);
  const created = await pool.query(
    'INSERT INTO users(email, username, password_hash) VALUES($1,$2,$3) RETURNING id, email, username',
    [normalizedEmail, normalizedUsername, passwordHash]
  );
  const user = created.rows[0];

  const token = jwt.sign({ id: user.id, email: user.email, username: user.username }, JWT_SECRET, { expiresIn: '1h' });
  return res.status(201).json({ id: user.id, email: user.email, username: user.username, token });
});

app.post('/login', async (req, res) => {
  const { email, password } = req.body || {};
  if (!validateEmail(email)) return res.status(400).json({ error: 'Invalid email' });
  if (!validatePassword(password)) return res.status(400).json({ error: 'Invalid password' });

  if (!(await ensureDbReady())) return res.status(503).json({ error: 'Database not ready' });

  const normalizedEmail = email.trim().toLowerCase();

  const result = await pool.query('SELECT id, email, username, password_hash FROM users WHERE email = $1 LIMIT 1', [normalizedEmail]);
  if (result.rowCount === 0) return res.status(401).json({ error: 'Invalid credentials' });
  const user = result.rows[0];

  const ok = await bcrypt.compare(password, user.password_hash);
  if (!ok) return res.status(401).json({ error: 'Invalid credentials' });

  const token = jwt.sign({ id: user.id, email: user.email, username: user.username }, JWT_SECRET, { expiresIn: '1h' });
  return res.json({ message: 'Login successful', user: { id: user.id, email: user.email, username: user.username }, token });
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
    const result = await pool.query('SELECT id, email, username FROM users ORDER BY id ASC');
    return res.json(result.rows);
  } catch (e) {
    console.error('Failed to fetch users:', e);
    return res.status(500).json({ error: 'Failed to fetch users' });
  }
});

app.get('/me', verifyToken, async (req, res) => {
  if (!(await ensureDbReady())) return res.status(503).json({ error: 'Database not ready' });
  try {
    const result = await pool.query('SELECT id, email, username FROM users WHERE id = $1 LIMIT 1', [req.user.id]);
    if (result.rowCount === 0) return res.status(404).json({ error: 'User not found' });
    return res.json(result.rows[0]);
  } catch (e) {
    console.error('Failed to fetch me:', e);
    return res.status(500).json({ error: 'Failed to fetch user' });
  }
});

app.get('/users/search', verifyToken, async (req, res) => {
  if (!(await ensureDbReady())) return res.status(503).json({ error: 'Database not ready' });
  const q = normalizeUsername(req.query.username);
  if (!q) return res.json([]);
  try {
    const result = await pool.query(
      'SELECT id, username, email FROM users WHERE username LIKE $1 ORDER BY username ASC LIMIT 20',
      [`${q}%`]
    );
    return res.json(result.rows);
  } catch (e) {
    console.error('Failed to search users:', e);
    return res.status(500).json({ error: 'Failed to search users' });
  }
});

app.post('/push/register', verifyToken, async (req, res) => {
  if (!(await ensureDbReady())) return res.status(503).json({ error: 'Database not ready' });
  const token = req.body && typeof req.body.token === 'string' ? req.body.token.trim() : '';
  const platform = req.body && typeof req.body.platform === 'string' ? req.body.platform.trim() : null;
  if (!token) return res.status(400).json({ error: 'Missing token' });
  if (token.length > 4096) return res.status(400).json({ error: 'Token too long' });

  try {
    await pool.query(
      `
      INSERT INTO user_devices(user_id, platform, fcm_token, updated_at)
      VALUES($1, $2, $3, now())
      ON CONFLICT (fcm_token)
      DO UPDATE SET user_id = EXCLUDED.user_id, platform = EXCLUDED.platform, updated_at = now()
      `,
      [req.user.id, platform, token]
    );
    return res.json({ ok: true });
  } catch (e) {
    console.error('Failed to register push token:', e);
    return res.status(500).json({ error: 'Failed to register token' });
  }
});

async function getGlobalChatId() {
  const result = await pool.query('SELECT id FROM chats WHERE is_global = true LIMIT 1');
  if (result.rowCount === 0) throw new Error('Global chat missing');
  return result.rows[0].id;
}

async function isMember(userId, chatId) {
  const r = await pool.query('SELECT 1 FROM chat_members WHERE chat_id = $1 AND user_id = $2 LIMIT 1', [chatId, userId]);
  return r.rowCount > 0;
}

async function getUsernameById(userId) {
  try {
    const r = await pool.query('SELECT username FROM users WHERE id = $1 LIMIT 1', [userId]);
    if (r.rowCount === 0) return null;
    return r.rows[0].username ?? null;
  } catch (_) {
    return null;
  }
}

app.get('/chats', verifyToken, async (req, res) => {
  if (!(await ensureDbReady())) return res.status(503).json({ error: 'Database not ready' });
  const userId = req.user.id;
  try {
    const globalChatId = await getGlobalChatId();

    const result = await pool.query(
      `
      SELECT c.id, c.name, c.is_group, c.is_global, c.e2ee_enabled,
             lm.plaintext AS last_text,
             lm.ciphertext AS last_ciphertext,
             lm.e2ee_flag AS last_e2ee,
             lm.time AS last_time
      FROM chats c
      LEFT JOIN LATERAL (
        SELECT plaintext, ciphertext, e2ee_flag, time
        FROM messages m
        WHERE m.chat_id = c.id
        ORDER BY time DESC
        LIMIT 1
      ) lm ON TRUE
      WHERE c.is_global = true
         OR c.id IN (SELECT chat_id FROM chat_members WHERE user_id = $1)
      ORDER BY c.is_global DESC, COALESCE(lm.time, c.created_at) DESC
      `,
      [userId]
    );

    // Attach members for non-global chats to support DM display naming.
    const chats = [];
    for (const row of result.rows) {
      const chat = {
        id: row.id,
        name: row.name,
        is_group: row.is_group,
        is_global: row.is_global,
        e2ee_enabled: row.e2ee_enabled === true,
        last: row.last_e2ee ? '[encrypted]' : (row.last_text ?? null),
        last_time: row.last_time,
        members: [],
      };
      if (!row.is_global) {
        const mem = await pool.query(
          `
          SELECT u.id, u.username, u.email
          FROM chat_members cm
          JOIN users u ON u.id = cm.user_id
          WHERE cm.chat_id = $1
          ORDER BY u.id ASC
          `,
          [row.id]
        );
        chat.members = mem.rows;
      }
      if (row.is_global && row.id !== globalChatId) {
        // no-op; keeping for clarity
      }
      chats.push(chat);
    }
    return res.json(chats);
  } catch (e) {
    console.error('Failed to list chats:', e);
    return res.status(500).json({ error: 'Failed to list chats' });
  }
});

// Fetch chat metadata including E2EE settings
app.get('/chats/:id', verifyToken, async (req, res) => {
  const chatId = parseInt(req.params.id, 10) || 1;
  if (!(await ensureDbReady())) return res.status(503).json({ error: 'Database not ready' });
  try {
    const meta = await pool.query(
      'SELECT id, name, is_group, is_global, e2ee_enabled, e2ee_key_base64 FROM chats WHERE id = $1 LIMIT 1',
      [chatId]
    );
    if (meta.rowCount === 0) return res.status(404).json({ error: 'Chat not found' });
    const chat = meta.rows[0];
    if (!chat.is_global) {
      const ok = await isMember(req.user.id, chatId);
      if (!ok) return res.status(403).json({ error: 'Forbidden' });
    }
    const members = chat.is_global
      ? []
      : (await pool.query(
          `
          SELECT u.id, u.username, u.email
          FROM chat_members cm
          JOIN users u ON u.id = cm.user_id
          WHERE cm.chat_id = $1
          ORDER BY u.id ASC
          `,
          [chatId]
        )).rows;
    return res.json({
      id: chat.id,
      name: chat.name,
      is_group: chat.is_group,
      is_global: chat.is_global,
      e2ee_enabled: chat.e2ee_enabled === true,
      e2ee_key_base64: chat.e2ee_key_base64 ?? null,
      members,
    });
  } catch (e) {
    console.error('Failed to fetch chat meta:', e);
    return res.status(500).json({ error: 'Failed to fetch chat' });
  }
});

app.post('/chats/dm', verifyToken, async (req, res) => {
  if (!(await ensureDbReady())) return res.status(503).json({ error: 'Database not ready' });
  const userId = req.user.id;
  const targetUsername = normalizeUsername(req.body && req.body.username);
  if (!validateUsername(targetUsername)) return res.status(400).json({ error: 'Invalid username' });
  try {
    const target = await pool.query('SELECT id, username FROM users WHERE username = $1 LIMIT 1', [targetUsername]);
    if (target.rowCount === 0) return res.status(404).json({ error: 'User not found' });
    const targetId = target.rows[0].id;
    if (Number(targetId) === Number(userId)) return res.status(400).json({ error: 'Cannot DM yourself' });

    // Find existing DM chat between these two users.
    const existing = await pool.query(
      `
      SELECT c.id
      FROM chats c
      JOIN chat_members a ON a.chat_id = c.id AND a.user_id = $1
      JOIN chat_members b ON b.chat_id = c.id AND b.user_id = $2
      WHERE c.is_group = false AND c.is_global = false
      LIMIT 1
      `,
      [userId, targetId]
    );
    if (existing.rowCount > 0) {
      return res.json({ chatId: existing.rows[0].id });
    }

    const created = await pool.query('INSERT INTO chats(name, is_group, is_global) VALUES($1,$2,$3) RETURNING id', [null, false, false]);
    const chatId = created.rows[0].id;
    await pool.query('INSERT INTO chat_members(chat_id, user_id) VALUES($1,$2),($1,$3)', [chatId, userId, targetId]);
    return res.status(201).json({ chatId });
  } catch (e) {
    console.error('Failed to create DM:', e);
    return res.status(500).json({ error: 'Failed to create DM' });
  }
});

app.post('/chats/group', verifyToken, async (req, res) => {
  if (!(await ensureDbReady())) return res.status(503).json({ error: 'Database not ready' });
  const userId = req.user.id;
  const name = (req.body && req.body.name ? String(req.body.name) : '').trim();
  const usernames = Array.isArray(req.body && req.body.usernames) ? req.body.usernames : [];
  if (!name) return res.status(400).json({ error: 'Group name required' });
  if (name.length > 60) return res.status(400).json({ error: 'Group name too long' });

  const normalized = usernames.map(normalizeUsername).filter(Boolean);
  const unique = [...new Set(normalized)];
  // At least 1 additional member.
  if (unique.length < 1) return res.status(400).json({ error: 'Add at least one username' });

  try {
    const usersResult = await pool.query(
      'SELECT id, username FROM users WHERE username = ANY($1::text[])',
      [unique]
    );
    const found = new Map(usersResult.rows.map((r) => [r.username, r.id]));
    for (const u of unique) {
      if (!found.has(u)) return res.status(404).json({ error: `User not found: ${u}` });
    }

    const created = await pool.query('INSERT INTO chats(name, is_group, is_global) VALUES($1,$2,$3) RETURNING id', [name, true, false]);
    const chatId = created.rows[0].id;

    // Members = requester + provided usernames.
    const memberIds = new Set([Number(userId)]);
    for (const id of found.values()) memberIds.add(Number(id));
    const values = Array.from(memberIds);

    // Insert membership rows.
    for (const id of values) {
      await pool.query('INSERT INTO chat_members(chat_id, user_id) VALUES($1,$2) ON CONFLICT DO NOTHING', [chatId, id]);
    }

    return res.status(201).json({ chatId });
  } catch (e) {
    console.error('Failed to create group:', e);
    return res.status(500).json({ error: 'Failed to create group' });
  }
});

// Fetch messages for a chat (persisted in Postgres)
app.get('/chats/:id/messages', verifyToken, async (req, res) => {
  const chatId = parseInt(req.params.id, 10) || 1;
  if (!(await ensureDbReady())) return res.status(503).json({ error: 'Database not ready' });
  try {
    const chatMeta = await pool.query('SELECT is_global FROM chats WHERE id = $1 LIMIT 1', [chatId]);
    if (chatMeta.rowCount === 0) return res.status(404).json({ error: 'Chat not found' });
    const isGlobal = chatMeta.rows[0].is_global === true;
    if (!isGlobal) {
      const ok = await isMember(req.user.id, chatId);
      if (!ok) return res.status(403).json({ error: 'Forbidden' });
    }
    const result = await pool.query(
      `
      SELECT m.id, m.chat_id, m.sender_email, u.username AS sender_username,
             m.e2ee_flag, m.ciphertext, m.nonce, m.mac, m.plaintext, m.time
      FROM messages m
      LEFT JOIN users u ON u.email = m.sender_email
      WHERE m.chat_id = $1
      ORDER BY m.time ASC
      `,
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

async function getFcmTokensForUsers(userIds) {
  const ids = (userIds || []).map((x) => Number(x)).filter((x) => Number.isFinite(x));
  if (ids.length === 0) return [];
  const r = await pool.query('SELECT fcm_token FROM user_devices WHERE user_id = ANY($1::int[])', [ids]);
  return r.rows.map((row) => row.fcm_token).filter(Boolean);
}

async function getAllowedUserIdsForChat(chatId) {
  const mem = await pool.query('SELECT user_id FROM chat_members WHERE chat_id = $1', [chatId]);
  return new Set(mem.rows.map((r) => Number(r.user_id)));
}

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
  } catch (_) {
    ws.close(1008, 'Invalid connection');
    return;
  }

  clients.add(ws);
  console.log('WebSocket client connected. Total:', clients.size);

  ws.on('message', async (message) => {
    const raw = typeof message === 'string' ? message : message.toString();

    const senderEmail = (ws.user && ws.user.email) ? String(ws.user.email) : 'unknown';
    const senderUserId = (ws.user && ws.user.id != null) ? Number(ws.user.id) : null;
    let senderUsername = (ws.user && ws.user.username) ? String(ws.user.username) : null;
    if (!senderUsername && senderUserId) {
      senderUsername = await getUsernameById(senderUserId);
    }

    let outPayload = null;

    try {
      const parsed = JSON.parse(raw);
      const chatIdNum = Number(parsed.chat_id);
      const globalChatId = await getGlobalChatId();
      const effectiveChatId = Number.isFinite(chatIdNum) && chatIdNum > 0 ? chatIdNum : globalChatId;

      // Check sender has access to this chat.
      const meta = await pool.query('SELECT is_global FROM chats WHERE id = $1 LIMIT 1', [effectiveChatId]);
      if (meta.rowCount === 0) {
        ws.send(JSON.stringify({ error: 'Chat not found', chat_id: effectiveChatId }));
        return;
      }
      const isGlobal = meta.rows[0].is_global === true;
      if (!isGlobal) {
        const ok = await isMember(ws.user.id, effectiveChatId);
        if (!ok) {
          ws.send(JSON.stringify({ error: 'Forbidden', chat_id: effectiveChatId }));
          return;
        }
      }

      // Settings update message (used to sync E2EE toggles/key)
      if (parsed && parsed.type === 'chat_settings_update') {
        const enabled = parsed.e2ee_enabled === true;
        const key = typeof parsed.e2ee_key_base64 === 'string' ? parsed.e2ee_key_base64 : null;
        if (await ensureDbReady()) {
          try {
            if (enabled) {
              await pool.query(
                'UPDATE chats SET e2ee_enabled = true, e2ee_key_base64 = COALESCE($2, e2ee_key_base64) WHERE id = $1',
                [effectiveChatId, key]
              );
            } else {
              await pool.query('UPDATE chats SET e2ee_enabled = false WHERE id = $1', [effectiveChatId]);
            }
          } catch (e) {
            console.error('Failed to update chat settings:', e);
          }
        }
        outPayload = {
          type: 'chat_settings',
          chat_id: effectiveChatId,
          e2ee_enabled: enabled,
          e2ee_key_base64: enabled ? key : null,
          sender_email: senderEmail,
          sender_username: senderUsername,
          sender_user_id: senderUserId,
          time: new Date().toISOString(),
        };
      } else {
        const now = new Date();
        const clientId = parsed && parsed.client_id != null ? parsed.client_id : null;

        if (parsed.e2ee_flag === true) {
          outPayload = {
            sender_email: senderEmail,
            sender_username: senderUsername,
            sender_user_id: senderUserId,
            e2ee_flag: true,
            ciphertext: parsed.ciphertext ?? parsed.text ?? String(parsed),
            nonce: parsed.nonce,
            mac: parsed.mac,
            time: now.toISOString(),
            chat_id: effectiveChatId,
            client_id: clientId,
          };

          if (await ensureDbReady()) {
            try {
              await pool.query(
                'INSERT INTO messages(chat_id, sender_email, e2ee_flag, ciphertext, nonce, mac, plaintext, time) VALUES($1,$2,$3,$4,$5,$6,$7,$8)',
                [effectiveChatId, senderEmail, true, outPayload.ciphertext, outPayload.nonce ?? null, outPayload.mac ?? null, null, now]
              );
            } catch (e) {
              console.error('DB insert error (encrypted):', e);
            }
          }
        } else {
          const plain = parsed.text ?? String(parsed);
          outPayload = {
            sender_email: senderEmail,
            sender_username: senderUsername,
            sender_user_id: senderUserId,
            text: plain,
            time: now.toISOString(),
            chat_id: effectiveChatId,
            client_id: clientId,
          };

          if (await ensureDbReady()) {
            try {
              await pool.query(
                'INSERT INTO messages(chat_id, sender_email, e2ee_flag, ciphertext, nonce, mac, plaintext, time) VALUES($1,$2,$3,$4,$5,$6,$7,$8)',
                [effectiveChatId, senderEmail, false, null, null, null, plain, now]
              );
            } catch (e) {
              console.error('DB insert error (plain):', e);
            }
          }
        }
      }
    } catch (_) {
      // Non-JSON -> treat as plaintext to global chat
      const now = new Date();
      const globalChatId = await getGlobalChatId();
      outPayload = {
        sender_email: senderEmail,
        sender_username: senderUsername,
        sender_user_id: senderUserId,
        text: raw,
        time: now.toISOString(),
        chat_id: globalChatId,
        client_id: null,
      };
      if (await ensureDbReady()) {
        try {
          await pool.query(
            'INSERT INTO messages(chat_id, sender_email, e2ee_flag, ciphertext, nonce, mac, plaintext, time) VALUES($1,$2,$3,$4,$5,$6,$7,$8)',
            [globalChatId, senderEmail, false, null, null, null, raw, now]
          );
        } catch (ex) {
          console.error('DB insert error (raw):', ex);
        }
      }
    }

    if (!outPayload) return;

    // Best-effort push notifications to offline recipients.
    // (When the app is closed, it won't have a WS connection, so this is how notifications appear.)
    try {
      if (!outPayload.type) {
        const chatId = Number(outPayload.chat_id);
        const meta = await pool.query('SELECT is_global FROM chats WHERE id = $1 LIMIT 1', [chatId]);
        const isGlobal = meta.rowCount > 0 && meta.rows[0].is_global === true;
        if (!isGlobal && senderUserId) {
          const allowedUserIds = await getAllowedUserIdsForChat(chatId);
          allowedUserIds.delete(Number(senderUserId));

          const onlineUserIds = new Set();
          for (const c of clients) {
            if (c.readyState !== WebSocket.OPEN) continue;
            if (c.user && c.user.id != null) onlineUserIds.add(Number(c.user.id));
          }

          const offlineUserIds = [...allowedUserIds].filter((uid) => !onlineUserIds.has(uid));
          if (offlineUserIds.length > 0) {
            const tokens = await getFcmTokensForUsers(offlineUserIds);
            const title = senderUsername ? `New message from @${senderUsername}` : 'New message';
            const body = outPayload.e2ee_flag === true ? 'Encrypted message' : (outPayload.text || '');
            await push.sendPushToTokens(tokens, {
              title,
              body,
              data: {
                chat_id: String(chatId),
              },
            });
          }
        }
      }
    } catch (e) {
      console.error('Push send failed:', e);
    }

    // Broadcast to relevant recipients.
    try {
      const out = JSON.stringify(outPayload);
      const chatId = Number(outPayload.chat_id);
      const meta = await pool.query('SELECT is_global FROM chats WHERE id = $1 LIMIT 1', [chatId]);
      const isGlobal = meta.rowCount > 0 && meta.rows[0].is_global === true;

      let allowedUserIds = null;
      if (!isGlobal) {
        allowedUserIds = await getAllowedUserIdsForChat(chatId);
      }

      for (const c of clients) {
        if (c.readyState !== WebSocket.OPEN) continue;
        if (isGlobal) {
          c.send(out);
          continue;
        }
        if (c.user && allowedUserIds && allowedUserIds.has(Number(c.user.id))) {
          c.send(out);
        }
      }
    } catch (ex) {
      console.error('WS broadcast error:', ex);
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
