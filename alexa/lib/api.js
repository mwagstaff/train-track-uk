const https = require('https');
const http = require('http');

const BASE_URL = process.env.API_BASE_URL || 'https://api.skynolimit.dev/train-track';

function doRequest(url) {
  return new Promise((resolve, reject) => {
    const client = url.startsWith('https') ? https : http;
    const req = client.get(url, (res) => {
      let data = '';
      res.setEncoding('utf8');
      res.on('data', (chunk) => (data += chunk));
      res.on('end', () => {
        const ok = res.statusCode >= 200 && res.statusCode < 300;
        try {
          const json = JSON.parse(data);
          resolve({ ok, json, statusCode: res.statusCode });
        } catch (e) {
          // If not JSON, return raw
          resolve({ ok, text: data, statusCode: res.statusCode });
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
      return { error: extractApiError(res, 'Failed to fetch departures.') };
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

function normalizeDeparturePayload(payload) {
  if (!payload) return null;
  if (Array.isArray(payload)) {
    if (payload.length === 1 && payload[0] && typeof payload[0] === 'object') {
      const first = payload[0];
      const key = Object.keys(first)[0];
      if (key && first[key]) {
        return first[key];
      }
    }
    return payload[0] || null;
  }
  return payload;
}

function normalizeServiceDetailsPayload(payload) {
  if (!payload) return null;
  if (Array.isArray(payload)) {
    const first = payload[0];
    if (first && typeof first === 'object') {
      const key = Object.keys(first)[0];
      if (key && first[key] && Object.keys(first[key]).length > 0) {
        return first[key];
      }
    }
    return null;
  }
  return payload;
}

function extractApiError(res, fallbackMessage) {
  const apiMessage = res?.json?.error || res?.text;
  if (typeof apiMessage === 'string' && apiMessage.trim()) {
    return apiMessage.trim();
  }
  return res?.statusCode ? `API error ${res.statusCode}` : fallbackMessage;
}

async function fetchDepartureAtTime(fromCrs, toCrs, departureTime) {
  if (!BASE_URL) {
    return { error: 'API is not configured. Set API_BASE_URL.' };
  }
  if (!fromCrs || !toCrs || !departureTime) {
    return { error: 'Missing CRS codes or departure time.' };
  }

  const url = `${BASE_URL.replace(/\/$/, '')}/api/v2/departures/from/${encodeURIComponent(fromCrs)}/to/${encodeURIComponent(toCrs)}/at/${encodeURIComponent(departureTime)}`;
  try {
    const res = await doRequest(url);
    if (!res.ok) {
      return {
        error: extractApiError(res, 'Failed to fetch departure status.'),
        statusCode: res.statusCode
      };
    }

    return { departure: normalizeDeparturePayload(res.json) };
  } catch (e) {
    return { error: 'Failed to reach the trains API.' };
  }
}

async function fetchServiceDetails(serviceId) {
  if (!BASE_URL) {
    return { error: 'API is not configured. Set API_BASE_URL.' };
  }
  if (!serviceId) {
    return { error: 'Missing service ID.' };
  }

  const url = `${BASE_URL.replace(/\/$/, '')}/api/v1/service_details/${encodeURIComponent(serviceId)}`;
  try {
    const res = await doRequest(url);
    if (!res.ok) {
      return {
        error: extractApiError(res, 'Failed to fetch service details.'),
        statusCode: res.statusCode
      };
    }

    const details = normalizeServiceDetailsPayload(res.json);
    if (!details || (typeof details === 'object' && Object.keys(details).length === 0)) {
      return { error: 'Service details were not available for that train.' };
    }

    return { details };
  } catch (e) {
    return { error: 'Failed to reach the service details API.' };
  }
}

module.exports = { fetchTrains, fetchDepartureAtTime, fetchServiceDetails };
