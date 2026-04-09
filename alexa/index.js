// Minimal Alexa Lambda handler without external deps.
// Reads station names, maps to CRS using stations.json, calls backend API, and speaks next trains.

const { findStationCRS, sanitizeStationName } = require('./lib/stations');
const { fetchTrains, fetchDepartureAtTime, fetchServiceDetails } = require('./lib/api');
const { computeLiveStatusText } = require('./lib/status');

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

function extractSlotValue(slot) {
  if (!slot) return undefined;
  return slot.value || slot.resolutions?.resolutionsPerAuthority?.[0]?.values?.[0]?.value?.name;
}

function normalizeAlexaTime(rawValue) {
  if (!rawValue || typeof rawValue !== 'string') return null;
  const trimmed = rawValue.trim();
  const match = trimmed.match(/(\d{2}):(\d{2})/);
  if (!match) return null;
  const hour = Number(match[1]);
  const minute = Number(match[2]);
  if (!Number.isFinite(hour) || !Number.isFinite(minute) || hour > 23 || minute > 59) return null;
  return `${String(hour).padStart(2, '0')}:${String(minute).padStart(2, '0')}`;
}

function lowerCaseFirst(text) {
  if (!text || typeof text !== 'string') return text;
  return text.charAt(0).toLowerCase() + text.slice(1);
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

const speakServiceStatus = (departureTime, fromName, toName, statusText) => {
  const suffix = statusText ? lowerCaseFirst(statusText) : 'status is unavailable right now';
  return {
    version: '1.0',
    response: {
      shouldEndSession: true,
      outputSpeech: {
        type: 'PlainText',
        text: `${departureTime} from ${fromName} to ${toName} ${suffix}.`
      }
    }
  };
};

async function handleSpecificDepartureStatus(intent) {
  const slots = intent.slots || {};
  const startRaw = extractSlotValue(slots.StartStation);
  const endRaw = extractSlotValue(slots.EndStation);
  const departureTimeRaw = extractSlotValue(slots.DepartureTime || slots.Time || slots.TrainTime);

  if (!startRaw && !endRaw && !departureTimeRaw) {
    const updatedIntent = {
      name: intent.name,
      slots: {
        DepartureTime: { name: 'DepartureTime' },
        StartStation: { name: 'StartStation' },
        EndStation: { name: 'EndStation' }
      }
    };
    return elicitSlot('DepartureTime', 'What departure time should I check?', updatedIntent);
  }

  if (!departureTimeRaw) {
    const updatedIntent = {
      name: intent.name,
      slots: {
        DepartureTime: { name: 'DepartureTime' },
        StartStation: startRaw ? { name: 'StartStation', value: startRaw } : { name: 'StartStation' },
        EndStation: endRaw ? { name: 'EndStation', value: endRaw } : { name: 'EndStation' }
      }
    };
    return elicitSlot('DepartureTime', 'What departure time should I check?', updatedIntent);
  }

  if (!startRaw) {
    const updatedIntent = {
      name: intent.name,
      slots: {
        DepartureTime: { name: 'DepartureTime', value: departureTimeRaw },
        StartStation: { name: 'StartStation' },
        EndStation: endRaw ? { name: 'EndStation', value: endRaw } : { name: 'EndStation' }
      }
    };
    return elicitSlot('StartStation', 'What station are you departing from?', updatedIntent);
  }

  if (!endRaw) {
    const updatedIntent = {
      name: intent.name,
      slots: {
        DepartureTime: { name: 'DepartureTime', value: departureTimeRaw },
        StartStation: { name: 'StartStation', value: startRaw },
        EndStation: { name: 'EndStation' }
      }
    };
    return elicitSlot('EndStation', 'Where are you going to?', updatedIntent);
  }

  const departureTime = normalizeAlexaTime(departureTimeRaw);
  if (!departureTime) {
    const updatedIntent = {
      name: intent.name,
      slots: {
        DepartureTime: { name: 'DepartureTime' },
        StartStation: { name: 'StartStation', value: startRaw },
        EndStation: { name: 'EndStation', value: endRaw }
      }
    };
    return elicitSlot('DepartureTime', 'Tell me the departure time in 24 hour format, for example 23:42.', updatedIntent);
  }

  const startName = sanitizeStationName(startRaw);
  const endName = sanitizeStationName(endRaw);
  const from = findStationCRS(startName);
  const to = findStationCRS(endName);
  const spokenFromName = startName || from?.name;
  const spokenToName = endName || to?.name;

  if (!from) {
    const updatedIntent = {
      name: intent.name,
      slots: {
        DepartureTime: { name: 'DepartureTime', value: departureTime },
        StartStation: { name: 'StartStation' },
        EndStation: { name: 'EndStation', value: endName }
      }
    };
    return elicitSlot('StartStation', `I couldn't find ${startName} in my station list. What station are you departing from?`, updatedIntent);
  }

  if (!to) {
    const updatedIntent = {
      name: intent.name,
      slots: {
        DepartureTime: { name: 'DepartureTime', value: departureTime },
        StartStation: { name: 'StartStation', value: startName },
        EndStation: { name: 'EndStation' }
      }
    };
    return elicitSlot('EndStation', `I couldn't find ${endName} in my station list. Where are you going to?`, updatedIntent);
  }

  const departureResult = await fetchDepartureAtTime(from.crs, to.crs, departureTime);
  if (departureResult.error) {
    if (departureResult.statusCode === 404) {
      return speakError(`I couldn't find a ${departureTime} departure from ${spokenFromName} to ${spokenToName} right now.`);
    }
    return speakError(departureResult.error);
  }

  const departure = departureResult.departure;
  if (!departure?.serviceID) {
    return speakError(`I couldn't find a ${departureTime} departure from ${spokenFromName} to ${spokenToName} right now.`);
  }

  const serviceDetailsResult = await fetchServiceDetails(departure.serviceID);
  if (serviceDetailsResult.error) {
    const estimated = departure?.departure_time?.estimated || departureTime;
    const scheduled = departure?.departure_time?.scheduled || departureTime;
    let fallbackStatus = departure?.isCancelled ? 'Currently cancelled' : null;
    if (!fallbackStatus) {
      const scheduledMinutes = parseHHMM(scheduled);
      const estimatedMinutes = parseHHMM(estimated);
      if (!estimated || estimated === 'On time' || estimated === scheduled) {
        fallbackStatus = 'Currently on time';
      } else if (String(estimated).toLowerCase() === 'delayed') {
        fallbackStatus = 'Currently delayed for an unknown period of time';
      } else if (scheduledMinutes != null && estimatedMinutes != null && estimatedMinutes > scheduledMinutes) {
        const diff = estimatedMinutes - scheduledMinutes;
        fallbackStatus = `Currently ${diff} minute${diff === 1 ? '' : 's'} late`;
      } else {
        fallbackStatus = `Currently expected at ${estimated}`;
      }
    }
    return speakServiceStatus(departureTime, spokenFromName, spokenToName, fallbackStatus);
  }

  const statusText = computeLiveStatusText(serviceDetailsResult.details, departure);
  return speakServiceStatus(departureTime, spokenFromName, spokenToName, statusText);
}

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

      if (name === 'GetServiceStatusIntent') {
        return handleSpecificDepartureStatus(intent);
      }

      if (name === 'GetTrainsIntent') {
        const slots = intent.slots || {};
        const departureTimeRaw = extractSlotValue(slots.DepartureTime || slots.Time || slots.TrainTime);
        if (departureTimeRaw) {
          return handleSpecificDepartureStatus(intent);
        }

        const startRaw = extractSlotValue(slots.StartStation);
        const endRaw = extractSlotValue(slots.EndStation);

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
