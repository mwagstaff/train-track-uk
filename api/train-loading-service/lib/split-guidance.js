const normalizedCrs = (value) => value?.trim().toUpperCase();

const asArray = (value) => Array.isArray(value) ? value : [];

function positiveLength(value) {
  const length = Number(value);
  return Number.isInteger(length) && length > 0 ? length : null;
}

function associationsAt(location) {
  return asArray(location?.associations).filter((association) => (
    String(association?.category ?? "").toLowerCase() === "divide"
      && association.isCancelled !== true
      && association.rid
  ));
}

export function serviceLocations(service, boardingCrs) {
  const detailedLocations = asArray(service?.locations);
  if (detailedLocations.length > 0) return detailedLocations;

  const locations = [...asArray(service?.previousLocations)];
  const currentCrs = normalizedCrs(service?.crs) ?? normalizedCrs(boardingCrs);
  if (currentCrs) {
    locations.push({
      crs: currentCrs,
      locationName: service?.locationName,
      length: service?.length,
      associations: service?.associations,
      detachFront: service?.detachFront,
    });
  }
  locations.push(...asArray(service?.subsequentLocations));
  return locations;
}

export function serviceHasActiveDivide(service, boardingCrs) {
  return serviceLocations(service, boardingCrs).some((location) => associationsAt(location).length > 0);
}

function firstPortionLength(locations, startIndex, combinedLength) {
  for (let index = startIndex; index < locations.length; index += 1) {
    const length = positiveLength(locations[index]?.length);
    if (length && length < combinedLength) return length;
  }
  return null;
}

function previousTrainLength(locations, splitIndex) {
  for (let index = splitIndex - 1; index >= 0; index -= 1) {
    const length = positiveLength(locations[index]?.length);
    if (length) return length;
  }
  return null;
}

function callsAfter(locations, startIndex, targetCrs) {
  return locations.slice(startIndex + 1)
    .some((location) => normalizedCrs(location?.crs) === targetCrs);
}

export async function resolveSplitGuidance({ service, request, getServiceDetails }) {
  const fromCrs = normalizedCrs(request?.from);
  const targetCrs = normalizedCrs(request?.to);
  if (!fromCrs || !targetCrs || typeof getServiceDetails !== "function") return null;

  const mainLocations = serviceLocations(service, fromCrs);
  const boardingIndex = mainLocations.findIndex((location) => normalizedCrs(location?.crs) === fromCrs);
  if (boardingIndex < 0) return null;

  for (let splitIndex = boardingIndex; splitIndex < mainLocations.length; splitIndex += 1) {
    const splitLocation = mainLocations[splitIndex];
    const associations = associationsAt(splitLocation);
    // Front/rear guidance is only unambiguous when the train divides into two portions.
    if (associations.length === 0) continue;
    if (associations.length !== 1) return null;

    const detachFront = typeof splitLocation.detachFront === "boolean"
      ? splitLocation.detachFront
      : associations[0].detachFront;
    if (typeof detachFront !== "boolean") return null;

    const childService = await getServiceDetails(associations[0].rid);
    const childLocations = serviceLocations(childService);
    const splitCrs = normalizedCrs(splitLocation.crs);
    const childSplitIndex = childLocations.findIndex((location) => normalizedCrs(location?.crs) === splitCrs);
    if (!splitCrs || childSplitIndex < 0) return null;

    const mainCallsTarget = callsAfter(mainLocations, splitIndex, targetCrs);
    const childCallsTarget = callsAfter(childLocations, childSplitIndex, targetCrs);
    if (mainCallsTarget === childCallsTarget) return null;

    const suppliedLength = positiveLength(request.length);
    const precedingLength = previousTrainLength(mainLocations, splitIndex);
    if (suppliedLength && precedingLength && suppliedLength !== precedingLength) return null;
    const combinedLength = suppliedLength ?? precedingLength;
    if (!combinedLength) return null;

    const mainLength = firstPortionLength(mainLocations, splitIndex, combinedLength);
    const childLength = firstPortionLength(childLocations, childSplitIndex, combinedLength);
    if (!mainLength || !childLength || mainLength + childLength !== combinedLength) return null;

    const usesChildPortion = childCallsTarget;
    return {
      splitAt: {
        crs: splitCrs,
        locationName: splitLocation.locationName ?? splitCrs,
      },
      destinationCRS: targetCrs,
      position: usesChildPortion === detachFront ? "front" : "rear",
      coachCount: usesChildPortion ? childLength : mainLength,
      confidence: "validated_lengths",
    };
  }

  return null;
}
