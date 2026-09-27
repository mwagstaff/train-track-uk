// Run with node to exercise cancellation rows against normalized captured staff data.
import http from 'node:http';
import fs from 'node:fs';
import { normalizeStaffDepartureBoard } from '../../../api/train-track-api/lib/staff-departures.js';
import { parseResponseDataLiveDepartureBoard } from '../../../api/train-track-api/lib/realtime-trains-api.js';
const raw = JSON.parse(fs.readFileSync(new URL('../../../api/train-track-api/test/fixtures/brighton-short-terminations.json', import.meta.url)));
const normalized = normalizeStaffDepartureBoard(raw, { station: 'ECR', destination: 'BTN' });
const original = (await parseResponseDataLiveDepartureBoard(normalized.board)).departures;
const clock = date => new Intl.DateTimeFormat('en-GB', { timeZone:'Europe/London', hour:'2-digit',minute:'2-digit',hourCycle:'h23' }).format(date);
const stations = [
 { crs:'ECR', name:'East Croydon', longitude:'-0.092', latitude:'51.375' },
 { crs:'BTN', name:'Brighton', longitude:'-0.141', latitude:'50.829' }
];
http.createServer((req,res)=>{
 const url = new URL(req.url, 'http://localhost');
 let body;
 if (url.pathname.endsWith('/stations')) body=stations;
 else if (url.pathname.includes('/departures/from/')) {
  const departures=original.map((d,i)=>({...d,departure_time:{scheduled:clock(new Date(Date.now()-(100-i*30)*60000)),estimated:clock(new Date(Date.now()+(10+i*30)*60000))}}));
  body=[{ECR_BTN:url.searchParams.get('includeStatus')==='true'?{departures,data_status:'live',last_successful_update:new Date().toISOString()}:departures}];
 } else if (url.pathname.includes('/service_details/')) {
  body=url.pathname.split('/service_details/')[1].split('/').map(id=>({[id]:{error:'Service no longer available',unavailable:true}}));
 } else if (url.pathname.endsWith('/health')) body={ok:true};
 else {res.writeHead(404,{'Content-Type':'application/json'});res.end('{}');return;}
 res.writeHead(200,{'Content-Type':'application/json'});res.end(JSON.stringify(body));
}).listen(3016,'127.0.0.1',()=>console.log('Staff departure UI fixture on 3016'));
