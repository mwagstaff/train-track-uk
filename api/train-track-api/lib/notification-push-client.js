import fs from 'fs';
import path from 'path';
import http2 from 'http2';
import crypto from 'crypto';

function base64UrlEncode(input) {
    const buffer = Buffer.isBuffer(input) ? input : Buffer.from(input);
    return buffer.toString('base64').replace(/=/g, '').replace(/\+/g, '-').replace(/\//g, '_');
}

export class NotificationPushClient {
    constructor(options = {}) {
        this.keyId = options.keyId || process.env.APNS_KEY_ID;
        this.teamId = options.teamId || process.env.APNS_TEAM_ID;
        this.topic = options.topic || process.env.APNS_NOTIFICATION_TOPIC || 'dev.skynolimit.traintrack';
        const sandboxFlag = process.env.APNS_USE_SANDBOX;
        this.useSandbox = typeof sandboxFlag === 'string' ? sandboxFlag.toLowerCase() !== 'false' : false;
        this.privateKey = options.privateKey || this.loadPrivateKey(options.keyPath);
    }

    loadPrivateKey(customPath) {
        if (process.env.APNS_AUTH_KEY) {
            return process.env.APNS_AUTH_KEY.replace(/\\n/g, '\n');
        }

        const fallbackPath = path.join(process.cwd(), 'certs', 'APNS_AuthKey_SkyNoLimit_SandboxAndProd.p8');
        const keyPath = customPath || process.env.APNS_AUTH_KEY_PATH || fallbackPath;
        if (fs.existsSync(keyPath)) {
            return fs.readFileSync(keyPath, 'utf8');
        }
        return null;
    }

    isConfigured() {
        return Boolean(this.keyId && this.teamId && this.topic && this.privateKey);
    }

    buildJwt() {
        if (!this.isConfigured()) {
            throw new Error('APNS credentials are not configured');
        }

        const header = { alg: 'ES256', kid: this.keyId, typ: 'JWT' };
        const payload = { iss: this.teamId, iat: Math.floor(Date.now() / 1000) };
        const headerEncoded = base64UrlEncode(JSON.stringify(header));
        const payloadEncoded = base64UrlEncode(JSON.stringify(payload));
        const signingInput = `${headerEncoded}.${payloadEncoded}`;

        const signer = crypto.createSign('sha256');
        signer.update(signingInput);
        signer.end();
        const signature = signer.sign(this.privateKey);
        const signatureEncoded = base64UrlEncode(signature);
        return `${signingInput}.${signatureEncoded}`;
    }

    async sendNotification(deviceToken, payload, options = {}) {
        if (!deviceToken) {
            throw new Error('Missing device token for notification');
        }

        if (!this.isConfigured()) {
            console.warn('APNS credentials missing; skipping notification send');
            return { skipped: true, reason: 'apns_not_configured', payload };
        }

        const useSandbox = options.useSandbox === true ? true : this.useSandbox;
        const host = useSandbox ? 'api.sandbox.push.apple.com' : 'api.push.apple.com';
        const session = http2.connect(`https://${host}`);
        const jwt = this.buildJwt();
        const body = JSON.stringify(payload);
        const headers = {
            ':method': 'POST',
            ':path': `/3/device/${deviceToken}`,
            'apns-topic': this.topic,
            'apns-push-type': 'alert',
            'apns-priority': '10',
            authorization: `bearer ${jwt}`,
            'content-type': 'application/json'
        };

        return await new Promise((resolve) => {
            let status;
            let responseBody = '';
            const request = session.request(headers);
            request.setEncoding('utf8');
            request.on('response', (headers) => {
                status = headers[':status'];
            });
            request.on('data', (chunk) => {
                responseBody += chunk;
            });
            request.on('end', () => {
                session.close();
                const parsedBody = safeParseJson(responseBody);
                const isBadToken = status === 410 || parsedBody?.reason === 'BadDeviceToken' || parsedBody?.reason === 'Unregistered';
                resolve({ status, body: parsedBody, isBadToken });
            });
            request.on('error', (error) => {
                session.close();
                console.error(`APNS notification push failed: ${error?.message || error}`);
                resolve({ status: 'error', error: error?.message || error.toString() });
            });
            request.write(body);
            request.end();
        });
    }
}

function safeParseJson(input) {
    try {
        if (!input) return {};
        return JSON.parse(input);
    } catch (error) {
        return { raw: input, parseError: error?.message || 'Failed to parse APNS response JSON' };
    }
}
