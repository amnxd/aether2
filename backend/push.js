const admin = require('firebase-admin');

let initialized = false;
let initError = null;

function initFirebase() {
  if (initialized) return true;
  try {
    const json = process.env.FIREBASE_SERVICE_ACCOUNT_JSON;
    if (json && json.trim()) {
      const serviceAccount = JSON.parse(json);
      admin.initializeApp({
        credential: admin.credential.cert(serviceAccount),
      });
      initialized = true;
      return true;
    }

    // Fallback: allow using Application Default Credentials
    // via GOOGLE_APPLICATION_CREDENTIALS.
    if (process.env.GOOGLE_APPLICATION_CREDENTIALS) {
      admin.initializeApp();
      initialized = true;
      return true;
    }

    initError = 'Missing FIREBASE_SERVICE_ACCOUNT_JSON or GOOGLE_APPLICATION_CREDENTIALS';
    return false;
  } catch (e) {
    initError = e && e.message ? String(e.message) : String(e);
    return false;
  }
}

async function sendPushToTokens(tokens, { title, body, data }) {
  if (!tokens || tokens.length === 0) return { ok: true, sent: 0 };
  if (!initFirebase()) {
    // Don’t hard-fail chat flow if push isn't configured.
    return { ok: false, sent: 0, error: initError };
  }

  const message = {
    tokens,
    notification: {
      title: title || 'Aether',
      body: body || '',
    },
    data: data || {},
    android: {
      priority: 'high',
    },
  };

  const resp = await admin.messaging().sendEachForMulticast(message);
  return {
    ok: true,
    sent: resp.successCount,
    failed: resp.failureCount,
    responses: resp.responses,
  };
}

module.exports = {
  sendPushToTokens,
};
