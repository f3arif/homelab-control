// Actual owner HTTPS route, strictly GET/HEAD. No choices, approvals or transfers.
const {chromium}=require(process.env.AFZ_PLAYWRIGHT||'/home/coolyo/afz-grocery-browser-test-tools/node_modules/playwright');
const fs=require('fs'),path=require('path'),assert=require('node:assert/strict');
const out=path.resolve(__dirname,'../qa/card-status-live');fs.mkdirSync(out,{recursive:true});
(async()=>{
 const browser=await chromium.launch({headless:true,executablePath:process.env.AFZ_CHROME||'/home/coolyo/afz-grocery-browser-test-tools/browsers/chromium_headless_shell-1248/chrome-headless-shell-linux64/chrome-headless-shell',args:['--no-sandbox','--disable-dev-shm-usage','--disable-gpu','--host-resolver-rules=MAP hpenvy.tailc9bb62.ts.net 100.71.26.69']});
 const results=[];
 try{for(const width of [360,412,1280]){
  const p=await browser.newPage({viewport:{width,height:860},reducedMotion:'reduce'}),errors=[],blocked=[];
  p.on('pageerror',e=>errors.push(e.message));
  await p.route('**/*',route=>{if(!['GET','HEAD'].includes(route.request().method())){blocked.push(route.request().method());return route.abort();}return route.continue();});
  const response=await p.goto('https://hpenvy.tailc9bb62.ts.net:8453/movie-night/',{waitUntil:'networkidle'});assert.equal(response.status(),200);
  await p.waitForSelector('#finalized-movies .card-download[data-state="ready"]');
  const state=await p.evaluate(async()=>{
   const data=await fetch('/movie-night/api/downloads',{cache:'no-store'}).then(r=>r.json());
   const jobs=new Map(data.jobs.map(j=>[j.id,j]));
   const cards=[...document.querySelectorAll('#finalized-movies .movie-card')];
   const available=new Set(data.jobs.filter(j=>j.downloaded&&j.indexed).map(j=>j.imdb));
   const mismatch=cards.filter(card=>available.has(card.dataset.movie)!==!!card.querySelector('.server-file:not([hidden])')).length;
   const sizes=cards.filter(c=>available.has(c.dataset.movie)).map(c=>data.jobs.find(j=>j.imdb===c.dataset.movie&&j.indexed).size);
   const ranges=[];
   for(const link of document.querySelectorAll('#finalized-movies .server-file:not([hidden])')){
    const r=await fetch(link.href,{headers:{Range:'bytes=0-31'},cache:'no-store'});ranges.push({status:r.status,bytes:(await r.arrayBuffer()).byteLength});
   }
   return {cards:cards.length,ready:cards.filter(c=>available.has(c.dataset.movie)).length,mismatch,sizes,ranges,
    overflow:document.documentElement.scrollWidth>innerWidth,smallControls:[...document.querySelectorAll('button,.server-file')].filter(x=>x.getClientRects().length&&x.getBoundingClientRect().height<40).length,
    summary:document.querySelector('#finalized-status').textContent,tray:document.querySelector('#finalize').textContent};
  });
  assert.equal(state.mismatch,0);assert(state.ready>0);assert(!state.overflow);assert.equal(state.smallControls,0);
  assert(state.ranges.every(r=>r.status===206&&r.bytes===32));assert.deepEqual(errors,[]);assert.deepEqual(blocked,[]);
  await p.locator('#finalized-movies .card-download .secondary').first().click();
  assert(await p.evaluate(()=>document.activeElement.classList.contains('download-row')));
  await p.locator('#finalized').scrollIntoViewIfNeeded();await p.screenshot({path:path.join(out,'live-'+width+'.png')});
  results.push({width,...state,errors,blocked});await p.close();
 }}finally{await browser.close();}
 fs.writeFileSync(path.join(out,'results.json'),JSON.stringify({passed:true,results},null,2));
 console.log('LIVE_CARD_STATUS_HTTPS_RANGE_PASS_360_412_1280_NO_WRITES');
 console.log(JSON.stringify(results));
})().catch(e=>{console.error(e);process.exitCode=1;});
