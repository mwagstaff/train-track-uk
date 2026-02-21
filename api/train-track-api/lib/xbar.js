import _ from 'lodash';
import moment from 'moment';
import { getTrainTimes } from './realtime-trains-api.js';

const MAX_DEPARTURES = 3;

export async function getXbarOutput(fromStation, toStation, maxDepartures, returnAfter) {

    let xBarOutput = '';

    // If the current time is after the returnAfter time, swap the stations
    const returnAfterTime = moment(returnAfter, 'HH:mm');
    if (moment(returnAfterTime).isValid() && moment().isAfter(returnAfterTime)) {
        const fromStationCopy = fromStation;
        fromStation = toStation;
        toStation = fromStationCopy;
    }

    const departures = (await getTrainTimes(fromStation, toStation)).departures;
    xBarOutput += getDeparturesOutput(fromStation, toStation, departures, maxDepartures);

    return xBarOutput;

}

function getDeparturesOutput(fromStation, toStation, departures, maxDepartures) {
    let menuBarOutput = `${fromStation} → ${toStation}: `;
    let dropdownOutput = '';

    if (!departures || departures.length === 0) {
        menuBarOutput += '❌';
        dropdownOutput += `No upcoming trains found for today | href=https://departureboard.io/journey/${fromStation}/${toStation}/`;
    }

    else {
        for (const departure of departures.slice(0, maxDepartures)) {
            // Check if train is cancelled
            const cancelReasonCode = _.get(departure, 'locationDetail.cancelReasonCode');
            if (cancelReasonCode) {
                menuBarOutput += `❌`;
                dropdownOutput += getDropdownOutputForCancellation(fromStation, toStation, departure);
            }
            // If no cancellation, get any delay information
            else {
                const delay = getDepartureDelay(departure);
                if (departure.serviceType === 'bus') {
                    menuBarOutput += '🚌';
                }
                else {
                    menuBarOutput += getDelayLabel(delay);
                }
                dropdownOutput += getDropdownOutput(fromStation, toStation, departure, delay);
            }
        }
    }
    return menuBarOutput + `\n --- \n` + dropdownOutput;
}

function getDropdownOutput(fromStation, toStation, departure, delay) {

    if (departure.serviceType === 'bus') {
        return getBusDropdownOutput(fromStation, toStation, departure);
    }

    // Scheduled and actual departure times
    const gbttBookedDeparture = _.get(departure, 'locationDetail.gbttBookedDeparture', 'Unknown');
    const bookedDepartureTime = moment(gbttBookedDeparture, 'HHmm').format('HH:mm');
    const realtimeDeparture = _.get(departure, 'locationDetail.realtimeDeparture', 'Unknown');
    const realtimeDepartureTime = moment(realtimeDeparture, 'HHmm').format('HH:mm');

    // Station names and platform
    const fromStationName = _.get(departure, 'locationDetail.description', 'Unknown');
    const toStationName = _.get(departure, 'locationDetail.destination[0].description', 'Unknown');
    const platform = _.get(departure, 'locationDetail.platform', 'Unknown');

    const delayText = delay > 0 ? `, delay: +${delay}` : '';

    return `${bookedDepartureTime} (actual: ${realtimeDepartureTime}${delayText}) ${fromStationName} to ${toStationName} - Platform ${platform} | href=https://departureboard.io/journey/${fromStation}/${toStation}/ \n`;
}

function getBusDropdownOutput(fromStation, toStation, departure) {

    const gbttBookedDeparture = _.get(departure, 'locationDetail.gbttBookedDeparture', 'Unknown');
    const bookedDepartureTime = moment(gbttBookedDeparture, 'HHmm').format('HH:mm');

    const fromStationName = _.get(departure, 'locationDetail.description', 'Unknown');
    const toStationName = _.get(departure, 'locationDetail.destination[0].description', 'Unknown');

    return `${bookedDepartureTime} - Replacement bus service from ${fromStationName} to ${toStationName} | href=https://departureboard.io/journey/${fromStation}/${toStation}/ \n`;

}

function getDropdownOutputForCancellation(fromStation, toStation, departure) {

    // Scheduled and actual departure times
    const gbttBookedDeparture = _.get(departure, 'locationDetail.gbttBookedDeparture', 'Unknown');
    const bookedDepartureTime = moment(gbttBookedDeparture, 'HHmm').format('HH:mm');

    // Station names and platform
    const fromStationName = _.get(departure, 'locationDetail.description', 'Unknown');
    const toStationName = _.get(departure, 'locationDetail.destination[0].description', 'Unknown');
    const cancelReasonLongText = _.get(departure, 'locationDetail.cancelReasonLongText', 'Unknown');

    return `CANCELLED: ${bookedDepartureTime} ${fromStationName} to ${toStationName} - ${cancelReasonLongText} | href=https://departureboard.io/journey/${fromStation}/${toStation}/ \n`;
}

function getDelayLabel(delay) {
    switch (delay) {
        case 0: return '🟢';
        case 1: return '1️⃣';
        case 2: return '2️⃣';
        case 3: return '3️⃣';
        case 4: return '4️⃣';
        case 5: return '5️⃣';
        case 6: return '6️⃣';
        case 7: return '7️⃣';
        case 8: return '8️⃣';
        case 9: return '9️⃣';
        default: return `🔴`;
    }
}

function getDepartureDelay(departure) {
    const bookedDepartureTime = _.get(departure, 'locationDetail.gbttBookedDeparture');
    const realtimeDepartureTime = _.get(departure, 'locationDetail.realtimeDeparture');
    // Return the difference in minutes between the booked and realtime departure times, which are in format HHMM
    return moment(realtimeDepartureTime, 'HHmm').diff(moment(bookedDepartureTime, 'HHmm'), 'minutes');
}