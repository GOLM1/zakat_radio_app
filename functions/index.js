const crypto = require("node:crypto");

const admin = require("firebase-admin");
const {onRequest} = require("firebase-functions/v2/https");
const {defineSecret} = require("firebase-functions/params");

admin.initializeApp();

const adminUsername = defineSecret("ADMIN_USERNAME");
const adminPassword = defineSecret("ADMIN_PASSWORD");
const adminTokenSecret = defineSecret("ADMIN_TOKEN_SECRET");

const tokenTtlMs = 30 * 60 * 1000;

function jsonResponse(response, status, payload) {
  response.status(status).json(payload);
}

function base64UrlEncode(value) {
  return Buffer.from(JSON.stringify(value)).toString("base64url");
}

function sign(value, secret) {
  return crypto.createHmac("sha256", secret).update(value).digest("base64url");
}

function createToken(username) {
  const payload = {
    sub: username,
    exp: Date.now() + tokenTtlMs,
  };
  const encodedPayload = base64UrlEncode(payload);
  const signature = sign(encodedPayload, adminTokenSecret.value());
  return `${encodedPayload}.${signature}`;
}

function verifyToken(token) {
  if (!token || !token.includes(".")) return null;

  const [encodedPayload, signature] = token.split(".");
  const expectedSignature = sign(encodedPayload, adminTokenSecret.value());
  const validSignature = crypto.timingSafeEqual(
    Buffer.from(signature),
    Buffer.from(expectedSignature),
  );

  if (!validSignature) return null;

  const payload = JSON.parse(
    Buffer.from(encodedPayload, "base64url").toString("utf8"),
  );
  if (!payload.exp || Date.now() > payload.exp) return null;
  return payload;
}

exports.adminLogin = onRequest(
  {
    region: "us-central1",
    cors: false,
    secrets: [adminUsername, adminPassword, adminTokenSecret],
  },
  (request, response) => {
    if (request.method !== "POST") {
      jsonResponse(response, 405, {error: "method_not_allowed"});
      return;
    }

    const {username, password} = request.body || {};
    const isValid =
      typeof username === "string" &&
      typeof password === "string" &&
      username === adminUsername.value() &&
      password === adminPassword.value();

    if (!isValid) {
      jsonResponse(response, 401, {error: "invalid_credentials"});
      return;
    }

    jsonResponse(response, 200, {token: createToken(username)});
  },
);

exports.sendNotification = onRequest(
  {
    region: "us-central1",
    cors: false,
    secrets: [adminTokenSecret],
  },
  async (request, response) => {
    if (request.method !== "POST") {
      jsonResponse(response, 405, {error: "method_not_allowed"});
      return;
    }

    const authHeader = request.get("authorization") || "";
    const token = authHeader.startsWith("Bearer ")
      ? authHeader.substring("Bearer ".length)
      : "";
    const session = verifyToken(token);

    if (!session) {
      jsonResponse(response, 401, {error: "invalid_token"});
      return;
    }

    const {title, body} = request.body || {};
    if (typeof title !== "string" || typeof body !== "string") {
      jsonResponse(response, 400, {error: "invalid_payload"});
      return;
    }

    const trimmedTitle = title.trim();
    const trimmedBody = body.trim();
    if (!trimmedTitle || !trimmedBody) {
      jsonResponse(response, 400, {error: "empty_notification"});
      return;
    }

    const messageId = await admin.messaging().send({
      topic: "all",
      notification: {
        title: trimmedTitle,
        body: trimmedBody,
      },
      android: {
        priority: "high",
        notification: {
          sound: "default",
        },
      },
    });

    jsonResponse(response, 200, {ok: true, messageId});
  },
);
