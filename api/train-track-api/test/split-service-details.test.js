import assert from 'node:assert/strict';
import test from 'node:test';

import { parseResponseDataLiveDepartureBoard } from '../lib/realtime-trains-api.js';
import { resolveAssociatedServiceDetails } from '../lib/service-details.js';

test('departure parsing preserves every destination for a dividing train', async () => {
    const result = await parseResponseDataLiveDepartureBoard({
        trainServices: [{
            std: '13:32',
            etd: '13:41',
            operator: 'Southern',
            serviceType: 'train',
            platform: '3',
            isCancelled: false,
            length: 12,
            origin: [{ crs: 'VIC', locationName: 'London Victoria' }],
            destination: [
                { crs: 'PMH', locationName: 'Portsmouth Harbour', via: 'via Hove & Worthing' },
                { crs: 'LIT', locationName: 'Littlehampton', via: 'via Hove & Worthing' }
            ],
            serviceID: '7785586ECROYDN_'
        }]
    });

    assert.deepEqual(result.departures[0].destination, [
        { crs: 'PMH', locationName: 'Portsmouth Harbour', via: 'via Hove & Worthing' },
        { crs: 'LIT', locationName: 'Littlehampton', via: 'via Hove & Worthing' }
    ]);
});

test('an unresolved combined service is rebuilt from both split portions', async () => {
    const detailsByID = {
        '7785586WORTHNG_': serviceDetails({
            destinationCRS: 'PMH',
            branch: [
                callingPoint('Ford', 'FOD', '15:04'),
                callingPoint('Portsmouth Harbour', 'PMH', '15:47')
            ],
            length: 4
        }),
        '7776123WORTHNG_': serviceDetails({
            destinationCRS: 'LIT',
            branch: [
                callingPoint('West Worthing', 'WWO', '14:55'),
                callingPoint('Littlehampton', 'LIT', '15:13')
            ],
            length: 8
        })
    };
    const departuresByDestination = {
        PMH: [departure('7785586WORTHNG_', 'PMH', '14:47')],
        LIT: [
            departure('unrelated-service', 'LIT', '14:10', 'BTN'),
            departure('7776123WORTHNG_', 'LIT', '14:51')
        ]
    };

    const result = await resolveAssociatedServiceDetails({
        serviceId: '7785586ECROYDN_',
        context: {
            fromCRS: 'ECR',
            toCRS: 'WRH',
            originCRS: 'VIC',
            operator: 'Southern',
            destinationCRSs: ['PMH', 'LIT'],
            length: 12
        },
        getDepartures: async (_from, to) => ({ departures: departuresByDestination[to] || [] }),
        getDetails: async (serviceID) => detailsByID[serviceID] || { error: 'No data' }
    });

    assert.ok(result);
    assert.equal(result.length, 12);
    assert.deepEqual(result.associatedServiceIDs, [
        '7785586WORTHNG_',
        '7776123WORTHNG_'
    ]);
    assert.deepEqual(
        result.subsequentCallingPoints.map((group) => group.callingPoint.at(-1).crs),
        ['PMH', 'LIT']
    );
    assert.deepEqual(
        result.previousCallingPoints[0].callingPoint.map((point) => point.crs),
        ['VIC', 'CLJ', 'ECR']
    );
});

function departure(serviceID, destinationCRS, scheduled, originCRS = 'VIC') {
    return {
        serviceID,
        operator: 'Southern',
        departure_time: { scheduled, estimated: scheduled },
        origin: { crs: originCRS, locationName: originCRS },
        destination: { crs: destinationCRS, locationName: destinationCRS }
    };
}

function serviceDetails({ destinationCRS, branch, length }) {
    return {
        generatedAt: '2026-08-16T13:00:00Z',
        serviceType: 'train',
        locationName: 'Worthing',
        crs: 'WRH',
        operator: 'Southern',
        operatorCode: 'SN',
        isCancelled: false,
        length,
        platform: '3',
        std: destinationCRS === 'PMH' ? '14:47' : '14:51',
        etd: 'On time',
        previousCallingPoints: [{
            callingPoint: [
                callingPoint('London Victoria', 'VIC', '13:15'),
                callingPoint('Clapham Junction', 'CLJ', '13:22'),
                callingPoint('East Croydon', 'ECR', '13:32')
            ]
        }],
        subsequentCallingPoints: [{ callingPoint: branch }]
    };
}

function callingPoint(locationName, crs, st) {
    return { locationName, crs, st, et: 'On time', isCancelled: false };
}
