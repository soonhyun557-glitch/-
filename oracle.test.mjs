import test from 'node:test';
import assert from 'node:assert/strict';
import {assessRainAtCutoff} from './rainfall.mjs';
test('16 contiguous 15-min periods, correctly determines 0.1mm cancellation',()=>{
 const cutoff=Date.parse('2026-11-21T10:59:00+09:00');
 const end=Math.floor(cutoff/900000)*900000;
 const starts=Array.from({length:16},(_,i)=>end-(16-i)*900000);
 const data={minutely_15:{time:starts.map(x=>new Date(x+9*3600000).toISOString().slice(0,19)),precipitation:starts.map((_,i)=>i===0?0.1:0)}};
 assert.equal(assessRainAtCutoff(data,cutoff).cancelled,true);
 data.minutely_15.precipitation[0]=0;
 assert.equal(assessRainAtCutoff(data,cutoff).cancelled,false);
 data.minutely_15.precipitation[0]=null;
 assert.throws(()=>assessRainAtCutoff(data,cutoff));
});
