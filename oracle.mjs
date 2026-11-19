import {ethers} from 'ethers';
import {assessRainAtCutoff} from './rainfall.mjs';

// Classroom demonstration: forecast/model rainfall, NOT a verified weather-station observation.
const RPC = process.env.BIFROST_RPC || 'https://public-01.testnet.bifrostnetwork.com/rpc';
const ORACLE = process.env.ORACLE_ADDRESS;
const ESCROW = process.env.ESCROW_ADDRESS;
const KEY = process.env.ORACLE_REPORTER_PRIVATE_KEY;
const THRESHOLD_MM = 0.1;
const CUTOFF_BEFORE_SECONDS = 60;
const INTERVAL_MS = 15 * 60 * 1000;
const JEJU = {latitude: 33.4996, longitude: 126.5312};

const escrowAbi = [
  'function eventCount() view returns (uint256)',
  'function getEvent(uint256) view returns (tuple(address organizer,string title,uint256 fee,uint32 minimum,uint64 registrationDeadline,uint64 eventTime,uint32 activeCount,uint256 heldBalance,uint256 cancellationFeesHeld,uint8 status,bool withdrawn,uint32 daySeconds,uint64 oracleReportedAt,bytes32 oracleEvidenceHash))',
  'function finalizeRegistration(uint256)',
];
const oracleAbi = [
  'function reporter() view returns (address)',
  'function getReport(address,uint256) view returns (tuple(uint8 outcome,bytes32 evidenceHash,uint64 reportedAt))',
  'function submitOutcome(address,uint256,uint8,bytes32)',
];


async function fetchRain() {
  const u = new URL('https://api.open-meteo.com/v1/forecast');
  Object.entries({...JEJU,minutely_15:'precipitation',past_minutely_15:'192',forecast_minutely_15:'1',timezone:'Asia/Seoul'}).forEach(([k,v])=>u.searchParams.set(k,String(v)));
  const response=await fetch(u,{signal:AbortSignal.timeout(18000)});
  if(!response.ok) throw Error(`Weather API HTTP ${response.status}`);
  const body=await response.json();
  if(body.error)throw Error(body.reason || 'Weather API error');
  return {body,sourceUrl:u.toString()};
}

export async function main() {
  if (!ESCROW || !ORACLE || !KEY) throw Error('Set ESCROW_ADDRESS, ORACLE_ADDRESS, ORACLE_REPORTER_PRIVATE_KEY as environment secrets');
  const provider = new ethers.JsonRpcProvider(RPC,49088,{staticNetwork:true});
  const signer = new ethers.Wallet(KEY,provider);
  const escrow = new ethers.Contract(ESCROW,escrowAbi,signer);
  const oracle = new ethers.Contract(ORACLE,oracleAbi,signer);
  if((await oracle.reporter()).toLowerCase() !== signer.address.toLowerCase()) throw Error('Reporter wallet does not match Oracle contract');
  const now=Math.floor(Date.now()/1000);
  const count=Number(await escrow.eventCount());
  console.log(`Events found: ${count}`);
  for(let id=1;id<=count;id++) {
    try {
      const e=await escrow.getFunction('getEvent(uint256)')(id);
      const eventTime=Number(e.eventTime);
      const cutoff=eventTime-CUTOFF_BEFORE_SECONDS;
      if(now<cutoff || now>eventTime+86400 || Number(e.oracleReportedAt)!==0)continue;
      if(![0,1].includes(Number(e.status)))continue;
      // For zero active participants, registration may have failed; do not push a bogus report.
      if(Number(e.activeCount)<Number(e.minimum) && now>=Number(e.registrationDeadline)) {
        if(Number(e.status)===0){const tx=await escrow.finalizeRegistration(id);await tx.wait();}
        console.log(`Event ${id}: registration failed, no oracle outcome`);
        continue;
      }
      if(now < Number(e.registrationDeadline)) {console.log(`Event ${id}: registration still open`);continue;}
      const {body,sourceUrl}=await fetchRain();
      const rain=assessRainAtCutoff(body,cutoff*1000);
      let outcome=rain.cancelled?2:1;
      // Existing contract refuses HELD until the event start and registration finalization.
      if(outcome===1 && now<eventTime){console.log(`Event ${id}: dry; waiting until event starts to report HELD`);continue;}
      if(outcome===1 && Number(e.status)===0) {const tx=await escrow.finalizeRegistration(id);await tx.wait();}
      const proof={v:1,source:'Open-Meteo 15-minute MODEL precipitation (not verified station observation)',sourceUrl,location:JEJU,eventId:id,eventTime,cutoff,thresholdMm:THRESHOLD_MM, ...rain};
      const evidenceHash=ethers.keccak256(ethers.toUtf8Bytes(JSON.stringify(proof)));
      const tx=await oracle.submitOutcome(ESCROW,id,outcome,evidenceHash);
      console.log(JSON.stringify({id,outcome,mm:rain.rainfallMm,hash:evidenceHash,tx:tx.hash,proof}));
      await tx.wait();
    } catch(error) {
      console.error(`Event ${id} FAILED:`,error.shortMessage||error.message);
      process.exitCode=1;
    }
  }
}
if(process.argv[1] && import.meta.url===new URL('file://'+process.argv[1]).href)main().catch(e=>{console.error(e);process.exitCode=1});
