function getAllStations(serviceDetails) {
  const stations = [];

  if (serviceDetails?.previousCallingPoints?.length > 0) {
    const previous = serviceDetails.previousCallingPoints[0]?.callingPoint || [];
    stations.push(...previous);
  }

  if (serviceDetails?.locationName) {
    stations.push({
      locationName: serviceDetails.locationName,
      crs: serviceDetails.crs,
      st: serviceDetails.std || serviceDetails.sta,
      et: serviceDetails.etd || serviceDetails.eta,
      at: serviceDetails.atd || serviceDetails.ata,
      isCancelled: serviceDetails.isCancelled
    });
  }

  if (serviceDetails?.subsequentCallingPoints?.length > 0) {
    const next = serviceDetails.subsequentCallingPoints[0]?.callingPoint || [];
    stations.push(...next);
  }

  return stations;
}

function isCancelledAtStation(station) {
  return station?.isCancelled === true || station?.at === 'Cancelled' || station?.et === 'Cancelled';
}

function parseStationTime(timeStr) {
  if (!timeStr || timeStr === 'On time' || String(timeStr).toLowerCase() === 'delayed' || timeStr === 'Cancelled') {
    return null;
  }

  const match = String(timeStr).match(/^(\d{2}):(\d{2})$/);
  if (!match) return null;

  const hour = Number(match[1]);
  const minute = Number(match[2]);
  if (!Number.isFinite(hour) || !Number.isFinite(minute)) return null;

  const now = new Date();
  return new Date(now.getFullYear(), now.getMonth(), now.getDate(), hour, minute, 0, 0);
}

function effectiveTime(station) {
  if (station?.et && station.et !== 'On time' && station.et !== 'Cancelled') {
    return parseStationTime(station.et);
  }
  return parseStationTime(station?.st);
}

function calculateStationDelay(station) {
  const scheduledTime = parseStationTime(station?.st);
  if (!scheduledTime) return 0;

  if (station?.at && station.at !== 'Cancelled') {
    if (station.at === 'On time') return 0;
    const actualTime = parseStationTime(station.at);
    if (actualTime) {
      return Math.max(0, Math.round((actualTime.getTime() - scheduledTime.getTime()) / 60000));
    }
  }

  const estimated = station?.et;
  if (!estimated || estimated === 'On time') return 0;
  if (String(estimated).toLowerCase() === 'delayed') return 240;

  const estimatedTime = parseStationTime(estimated);
  if (!estimatedTime) return 0;

  return Math.max(0, Math.round((estimatedTime.getTime() - scheduledTime.getTime()) / 60000));
}

function buildSimpleStatusText(departure, serviceDetails) {
  if (departure?.isCancelled || serviceDetails?.isCancelled) return 'Currently cancelled';

  const estimated = departure?.departure_time?.estimated || serviceDetails?.etd || serviceDetails?.eta;
  const scheduled = departure?.departure_time?.scheduled || serviceDetails?.std || serviceDetails?.sta;

  if (!estimated || estimated === 'On time') return 'Currently on time';
  if (String(estimated).toLowerCase() === 'delayed') return 'Currently delayed for an unknown period of time';

  const scheduledTime = parseStationTime(scheduled);
  const estimatedTime = parseStationTime(estimated);
  if (!scheduledTime || !estimatedTime) return `Currently expected at ${estimated}`;

  const delayMinutes = Math.max(0, Math.round((estimatedTime.getTime() - scheduledTime.getTime()) / 60000));
  if (delayMinutes === 0) return 'Currently on time';
  return `Currently ${delayMinutes} minute${delayMinutes === 1 ? '' : 's'} late`;
}

function computeLiveStatusText(serviceDetails, departure) {
  if (!serviceDetails || String(serviceDetails.serviceType || '').toLowerCase() !== 'train') {
    return buildSimpleStatusText(departure, serviceDetails);
  }

  const allStations = getAllStations(serviceDetails);
  if (!allStations.length || allStations.every((station) => isCancelledAtStation(station))) {
    return buildSimpleStatusText(departure, serviceDetails);
  }

  const now = new Date();
  const approachWindowMs = 60 * 1000;
  const atGraceWindowMs = 30 * 1000;

  for (let index = 0; index < allStations.length; index += 1) {
    const station = allStations[index];
    if (isCancelledAtStation(station)) continue;
    if (station.at && station.at !== 'Cancelled') continue;

    const stationTime = effectiveTime(station);
    if (!stationTime) continue;

    const arriveTime = new Date(stationTime.getTime() - approachWindowMs);
    if (now < arriveTime) {
      if (index === 0) {
        const delayMinutes = calculateStationDelay(station);
        if (String(station.et || '').toLowerCase() === 'delayed') {
          return `Currently delayed before departure from ${station.locationName}`;
        }
        const lateText = delayMinutes === 0 ? 'on time' : `${delayMinutes} minute${delayMinutes === 1 ? '' : 's'} late`;
        return `Currently scheduled to depart ${station.locationName} ${lateText}`;
      }

      let previousIndex = index - 1;
      while (previousIndex >= 0 && isCancelledAtStation(allStations[previousIndex])) {
        previousIndex -= 1;
      }
      if (previousIndex >= 0) {
        const previous = allStations[previousIndex];
        const delayMinutes = Math.max(calculateStationDelay(previous), calculateStationDelay(station));
        const lateText = delayMinutes >= 240
          ? 'delayed for an unknown period of time'
          : (delayMinutes === 0 ? 'on time' : `${delayMinutes} minute${delayMinutes === 1 ? '' : 's'} late`);
        return `Currently ${lateText}, between ${previous.locationName} and ${station.locationName}`;
      }
    } else if (now < stationTime) {
      const nextDelayMinutes = calculateStationDelay(station);
      const nextLateText = nextDelayMinutes === 0 ? 'on time' : `${nextDelayMinutes} minute${nextDelayMinutes === 1 ? '' : 's'} late`;

      if (index > 0) {
        let previousIndex = index - 1;
        while (previousIndex >= 0 && isCancelledAtStation(allStations[previousIndex])) {
          previousIndex -= 1;
        }
        if (previousIndex >= 0) {
          const previous = allStations[previousIndex];
          if (previous.at && previous.at !== 'Cancelled') {
            const previousEstimatedTime = effectiveTime(previous);
            if (previousEstimatedTime && now <= new Date(previousEstimatedTime.getTime() + atGraceWindowMs)) {
              const previousDelayMinutes = calculateStationDelay(previous);
              const previousLateText = previousDelayMinutes === 0 ? 'on time' : `${previousDelayMinutes} minute${previousDelayMinutes === 1 ? '' : 's'} late`;
              return `Currently ${previousLateText}, at ${previous.locationName}`;
            }
          }
        }
      }

      return `Currently ${nextLateText}, at or near ${station.locationName}`;
    }
  }

  let lastActualIndex = -1;
  for (let index = 0; index < allStations.length; index += 1) {
    if (allStations[index]?.at && allStations[index].at !== 'Cancelled') {
      lastActualIndex = index;
    }
  }

  if (lastActualIndex >= 0 && lastActualIndex < allStations.length - 1) {
    let nextIndex = lastActualIndex + 1;
    while (nextIndex < allStations.length && isCancelledAtStation(allStations[nextIndex])) {
      nextIndex += 1;
    }

    if (nextIndex < allStations.length) {
      const next = allStations[nextIndex];
      if (String(next.et || '').toLowerCase() === 'delayed' || !next.at) {
        const previous = allStations[lastActualIndex];
        const delayMinutes = Math.max(calculateStationDelay(previous), calculateStationDelay(next));
        const lateText = delayMinutes >= 240
          ? 'delayed for an unknown period of time'
          : (delayMinutes === 0 ? 'on time' : `${delayMinutes} minute${delayMinutes === 1 ? '' : 's'} late`);
        return `Currently ${lateText}, between ${previous.locationName} and ${next.locationName}`;
      }
    }
  }

  const last = allStations[allStations.length - 1];
  if (last) {
    const delayMinutes = calculateStationDelay(last);
    const lateText = delayMinutes === 0 ? 'on time' : `${delayMinutes} minute${delayMinutes === 1 ? '' : 's'} late`;
    return `Currently arrived ${lateText} at ${last.locationName}`;
  }

  return buildSimpleStatusText(departure, serviceDetails);
}

module.exports = {
  computeLiveStatusText
};
