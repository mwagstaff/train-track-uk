// Minimal Alexa Lambda handler without external deps.
// Reads station names, maps to CRS using stations.json, calls backend API, and speaks next trains.

const { findStationCRS, sanitizeStationName } = require('./lib/stations');
const { fetchTrains } = require('./lib/api');

// Text helpers
const speakError = (msg) => ({
  version: '1.0',
  response: {
    shouldEndSession: false,
    outputSpeech: { type: 'PlainText', text: msg },
    reprompt: { outputSpeech: { type: 'PlainText', text: 'Please say the start and end stations.' } }
  }
});

const ask = (prompt, reprompt) => ({
  version: '1.0',
  response: {
    shouldEndSession: false,
    outputSpeech: { type: 'PlainText', text: prompt },
    reprompt: { outputSpeech: { type: 'PlainText', text: reprompt || prompt } }
  }
});

const elicitSlot = (slotToElicit, prompt, updatedIntent) => ({
  version: '1.0',
  response: {
    shouldEndSession: false,
    outputSpeech: { type: 'PlainText', text: prompt },
    reprompt: { outputSpeech: { type: 'PlainText', text: prompt } },
    directives: [
      {
        type: 'Dialog.ElicitSlot',
        slotToElicit,
        updatedIntent
      }
    ]
  }
});

function parseHHMM(s) {
  if (!s || typeof s !== 'string') return null;
  const m = s.match(/^(\d{2}):(\d{2})$/);
  if (!m) return null;
  const hh = parseInt(m[1], 10);
  const mm = parseInt(m[2], 10);
  if (Number.isNaN(hh) || Number.isNaN(mm)) return null;
  return hh * 60 + mm;
}

function extractName(obj) {
  if (!obj) return undefined;
  if (typeof obj === 'string') return obj;
  return obj.locationName || obj.location || obj.name || undefined;
}

function extractDestination(dep) {
  const d = dep.destination || dep.destinations;
  if (!d) return undefined;
  if (Array.isArray(d)) return extractName(d[0]);
  return extractName(d);
}

const speakTrains = (fromName, toName, trains) => {
  if (!Array.isArray(trains) || trains.length === 0) {
    return {
      version: '1.0',
      response: {
        shouldEndSession: false,
        outputSpeech: { type: 'PlainText', text: `I couldn't find any upcoming trains from ${fromName} to ${toName} right now.` },
        reprompt: { outputSpeech: { type: 'PlainText', text: 'Try another station or time.' } }
      }
    };
  }

  const firstThree = trains.slice(0, 3);
  const parts = firstThree.map((t, idx) => {
    const n = idx + 1;
    const scheduled = t?.departure_time?.scheduled || t.std || t.time || 'unknown time';
    const estimated = t?.departure_time?.estimated || t.etd || undefined;
    const operator = t?.operator || t?.serviceOperator || 'train';
    const originName = extractName(t?.origin) || fromName;
    const destName = extractDestination(t) || toName;
    const platform = t?.platform ? `, departing platform ${t.platform}` : '';
    const isCancelled = Boolean(t?.isCancelled || t?.is_cancelled || t?.cancelled);

    if (isCancelled) {
      return `Departure ${n} has been cancelled, which was the ${scheduled} ${operator} service from ${originName} to ${destName}.`;
    }

    let runningPart = 'running on time';
    if (estimated && typeof estimated === 'string') {
      const estLower = estimated.toLowerCase();
      if (estLower === 'on time') {
        runningPart = 'running on time';
      } else if (estLower === 'delayed') {
        runningPart = 'which has been delayed';
      } else {
        // Try to compute lateness if HH:MM
        const sMin = parseHHMM(scheduled);
        const eMin = parseHHMM(estimated);
        if (sMin != null && eMin != null) {
          const diff = eMin - sMin;
          if (diff > 0) {
            runningPart = `running ${diff} minute${diff === 1 ? '' : 's'} late and expected at ${estimated}`;
          } else if (diff < 0) {
            runningPart = `running ${Math.abs(diff)} minute${diff === -1 ? '' : 's'} early and expected at ${estimated}`;
          } else {
            runningPart = 'running on time';
          }
        } else {
          // Not a HH:MM, just state expected time/status
          runningPart = `expected at ${estimated}`;
        }
      }
    }

    return `Departure ${n} is the ${scheduled} ${operator} service from ${originName} to ${destName}, ${runningPart}${platform}.`;
  });

  const preface = `Your next trains from ${fromName} to ${toName}.`;
  const text = [preface, ...parts].join(' ');

  return {
    version: '1.0',
    response: {
      shouldEndSession: true,
      outputSpeech: {
        type: 'PlainText',
        text
      }
    }
  };
};

exports.handler = async (event) => {
  try {
    const req = event.request || event;

    if (req.type === 'LaunchRequest') {
      return ask(
        'Welcome to Train Track. Tell me your route, for example: from East Croydon to Gatwick Airport.',
        'Please say the start and end stations.'
      );
    }

    if (req.type === 'IntentRequest') {
      const intent = req.intent || {};
      const name = intent.name;

      if (name === 'GetTrainsIntent') {
        const slots = intent.slots || {};
        const startRaw = slots.StartStation && (slots.StartStation.value || slots.StartStation.resolutions?.resolutionsPerAuthority?.[0]?.values?.[0]?.value?.name);
        const endRaw = slots.EndStation && (slots.EndStation.value || slots.EndStation.resolutions?.resolutionsPerAuthority?.[0]?.values?.[0]?.value?.name);

        // If both stations are missing, elicit the start station first
        if (!startRaw && !endRaw) {
          const updatedIntent = {
            name: 'GetTrainsIntent',
            slots: {
              StartStation: { name: 'StartStation' },
              EndStation: { name: 'EndStation' }
            }
          };
          return elicitSlot('StartStation', 'What station are you departing from?', updatedIntent);
        }

        // If one is missing, elicit the missing one, preserving what we already have
        if (!startRaw && endRaw) {
          const updatedIntent = {
            name: 'GetTrainsIntent',
            slots: {
              StartStation: { name: 'StartStation' },
              EndStation: { name: 'EndStation', value: endRaw }
            }
          };
          return elicitSlot('StartStation', 'What station are you departing from?', updatedIntent);
        }

        if (startRaw && !endRaw) {
          const updatedIntent = {
            name: 'GetTrainsIntent',
            slots: {
              StartStation: { name: 'StartStation', value: startRaw },
              EndStation: { name: 'EndStation' }
            }
          };
          return elicitSlot('EndStation', 'Where are you going to?', updatedIntent);
        }

        const startName = sanitizeStationName(startRaw);
        const endName = sanitizeStationName(endRaw);

        const from = findStationCRS(startName);
        const to = findStationCRS(endName);

        if (!from) {
          const updatedIntent = {
            name: 'GetTrainsIntent',
            slots: {
              StartStation: { name: 'StartStation' },
              EndStation: { name: 'EndStation', value: endName }
            }
          };
          return elicitSlot('StartStation', `I couldn't find ${startName} in my station list. What station are you departing from?`, updatedIntent);
        }
        if (!to) {
          const updatedIntent = {
            name: 'GetTrainsIntent',
            slots: {
              StartStation: { name: 'StartStation', value: startName },
              EndStation: { name: 'EndStation' }
            }
          };
          return elicitSlot('EndStation', `I couldn't find ${endName} in my station list. Where are you going to?`, updatedIntent);
        }

        const apiResult = await fetchTrains(from.crs, to.crs);
        if (apiResult.error) {
          return speakError(apiResult.error);
        }

        // Expect apiResult.trains to be an array of items with fields like departureTime/std, platform, estimated/etd
        return speakTrains(from.name, to.name, apiResult.trains || []);
      }

      // Fallback
      return speakError("Sorry, I didn't get that. Say, from Kings Cross to Cambridge.");
    }

    // SessionEndedRequest or unknown
    return { version: '1.0', response: { shouldEndSession: true } };
  } catch (err) {
    console.error('Unhandled error', err);
    return speakError('Something went wrong while looking up trains.');
  }
};
