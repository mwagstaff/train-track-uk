const https = require('https');
const http = require('http');

// Configure via env vars set on the Lambda function
// API_BASE_URL: e.g. https://train-track-api.fly.dev

const BASE_URL = process.env.API_BASE_URL || 'https://train-track-api.fly.dev';

function doRequest(url) {
  return new Promise((resolve, reject) => {
    const client = url.startsWith('https') ? https : http;
    const req = client.get(url, (res) => {
      let data = '';
      res.setEncoding('utf8');
      res.on('data', (chunk) => (data += chunk));
      res.on('end', () => {
        try {
          const json = JSON.parse(data);
          resolve({ ok: true, json });
        } catch (e) {
          // If not JSON, return raw
          resolve({ ok: res.statusCode >= 200 && res.statusCode < 300, text: data, statusCode: res.statusCode });
        }
      });
    });
    req.on('error', reject);
    req.setTimeout(6000, () => {
      req.destroy(new Error('Request timed out'));
    });
  });
}

async function fetchTrains(fromCrs, toCrs) {
  if (!BASE_URL) {
    return { error: 'API is not configured. Set API_BASE_URL.' };
  }
  if (!fromCrs || !toCrs) {
    return { error: 'Missing CRS codes.' };
  }
  // Endpoint path per provided API spec
  const url = `${BASE_URL.replace(/\/$/, '')}/api/v1/departures/from/${encodeURIComponent(fromCrs)}/to/${encodeURIComponent(toCrs)}`;
  try {
    const res = await doRequest(url);
    if (!res.ok) {
      return { error: `API error ${res.statusCode || ''}`.trim() };
    }

    // Normalize result shape to { trains: [...] }
    const payload = res.json || {};
    let departures = [];
    if (Array.isArray(payload)) departures = payload;
    else if (Array.isArray(payload.departures)) departures = payload.departures;
    else if (Array.isArray(payload.trains)) departures = payload.trains;
    else if (Array.isArray(payload.services)) departures = payload.services;

    return { trains: departures };
  } catch (e) {
    return { error: 'Failed to reach the trains API.' };
  }
}

module.exports = { fetchTrains };
