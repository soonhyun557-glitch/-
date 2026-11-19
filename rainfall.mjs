const THRESHOLD_MM = 0.1;
const INTERVAL_MS = 15 * 60 * 1000;
export function assessRainAtCutoff(data, cutoffMs) {
  if (!data?.minutely_15?.time || !data?.minutely_15?.precipitation) throw Error('15-minute precipitation data missing');
  // Open-Meteo time strings without timezone are returned in Asia/Seoul local time.
  const byStart = new Map(data.minutely_15.time.map((t,i) => [Date.parse(t + '+09:00'), data.minutely_15.precipitation[i]]));
  // Align cutoff to last fully completed 15-minute interval; 16 bins = previous four full hours.
  const end = Math.floor(cutoffMs / INTERVAL_MS) * INTERVAL_MS;
  let sum = 0;
  const bins=[];
  for (let start=end-16*INTERVAL_MS;start<end;start+=INTERVAL_MS) {
    const value=byStart.get(start);
    if (typeof value !== 'number' || !Number.isFinite(value) || value < 0) throw Error(`Rainfall data unavailable for ${new Date(start).toISOString()}`);
    sum += value;
    bins.push({start:new Date(start).toISOString(), mm:value});
  }
  return {rainfallMm:Math.round(sum*1000)/1000, cancelled:sum >= THRESHOLD_MM-1e-9, bins, windowStart:new Date(end-16*INTERVAL_MS).toISOString(), windowEnd:new Date(end).toISOString()};
}

