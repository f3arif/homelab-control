// Read-only genre acceptance on the actual owner page; all posters and ready cards.
const {chromium}=require(process.env.AFZ_PLAYWRIGHT||'/home/coolyo/afz-grocery-browser-test-tools/node_modules/playwright');
const fs=require('fs'),path=require('path'),assert=require('node:assert/strict');
const out=path.resolve(__dirname,'../qa/genre-exclusions-live');fs.mkdirSync(out,{recursive:true});
(async()=>{
 const browser=await chromium.launch({headless:true,executablePath:process.env.AFZ_CHROME||'/home/coolyo/afz-grocery-browser-test-tools/browsers/chromium_headless_shell-1248/chrome-headless-shell-linux64/chrome-headless-shell',args:['--no-sandbox','--disable-dev-shm-usage','--disable-gpu','--host-resolver-rules=MAP hpenvy.tailc9bb62.ts.net 100.71.26.69']});
 const results=[];
 try{for(const width of [360,412,1280]){
  const p=await browser.newPage({viewport:{width,height:860},reducedMotion:'reduce'}),errors=[],blocked=[],posters=[];
  p.on('pageerror',e=>errors.push(e.message));
  p.on('response',r=>{if(/\/posters\/tt\d+\.img$/.test(r.url()))posters.push({status:r.status(),mime:r.headers()['content-type']});});
  await p.route('**/*',route=>{if(!['GET','HEAD'].includes(route.request().method())){blocked.push(route.request().method());return route.abort();}return route.continue();});
  const response=await p.goto('https://hpenvy.tailc9bb62.ts.net:8453/movie-night/',{waitUntil:'networkidle'});assert.equal(response.status(),200);
  assert.equal(await p.locator('.liked-note').count(),0);
  assert.match(await p.locator('#genre-guidance').textContent(),/genres; stories, themes and styles can vary/);
  const api=await p.evaluate(async()=>{const r=await fetch('/movie-night/api/shortlist',{cache:'no-store'});if(!r.ok)throw new Error('shortlist unavailable');return r.json();});
  assert(api.movies.length>0&&api.movies.every(m=>m.similarToLiked===false));
  assert.deepEqual(api.excludedGenres,['Animation','Drama','Comedy']);
  assert(api.movies.every(m=>(m.genres||[]).every(g=>!/(animation|animated|anime|cartoon|drama|comedy|dramedy)/i.test(g))));
  assert.equal(await p.locator('.genre-excluded').count(),(api.finalized.excludedIds||[]).length);
  for(const id of api.finalized.excludedIds||[])assert.equal(await p.locator('.movie-card[data-movie="'+id+'"]').count(),0);
  assert.deepEqual(await p.locator('.chips li').allTextContents(),['2016 onward','No Animation','No Drama','No Comedy']);
  assert.deepEqual(api.selectionLimits,{min:3,max:10,visible:10});assert.equal(api.autoDownloads,true);
  const cards=p.locator('.movie-card');await cards.first().waitFor();const count=await cards.count();assert(count>0);
  for(let i=0;i<count;i++){
   const card=cards.nth(i);await card.scrollIntoViewIfNeeded();
   await p.waitForFunction(index=>{const card=document.querySelectorAll('.movie-card')[index],img=card.querySelector('.movie-poster img');return img&&img.complete&&img.naturalWidth>0&&card.querySelector('.poster-fallback').hidden;},i,{timeout:12000});
  }
  const state=await p.evaluate(()=>({cards:document.querySelectorAll('.movie-card').length,loaded:[...document.querySelectorAll('.movie-poster img')].filter(x=>x.complete&&x.naturalWidth>0).length,missing:[...document.querySelectorAll('.poster-fallback')].filter(x=>!x.hidden).length,ready:document.querySelectorAll('#finalized-movies .card-download[data-state="ready"]').length,overflow:document.documentElement.scrollWidth>innerWidth}));
  assert.equal(state.cards,state.loaded);assert.equal(state.missing,0);assert(!state.overflow);assert(state.ready>0);assert.deepEqual(errors,[]);assert.deepEqual(blocked,[]);
  assert(posters.length>0&&posters.every(r=>r.status===200&&/^image\/(jpeg|webp)/.test(r.mime)));
  await cards.nth(Math.min(4,count-1)).scrollIntoViewIfNeeded();await p.screenshot({path:path.join(out,'posters-'+width+'.png')});
  results.push({width,...state,responses:posters.length,errors,blocked});await p.close();
 }}finally{await browser.close();}
 fs.writeFileSync(path.join(out,'results.json'),JSON.stringify({passed:true,results},null,2));
 console.log('LIVE_GENRE_EXCLUSIONS_AND_POSTERS_PASS_360_412_1280_NO_WRITES');console.log(JSON.stringify(results));
})().catch(e=>{console.error(e);process.exitCode=1;});
