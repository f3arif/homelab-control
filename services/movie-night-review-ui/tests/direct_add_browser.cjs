// Actual HTTP fixture gateway/API, no real user records or production identity.
const {chromium}=require(process.env.AFZ_PLAYWRIGHT||'/home/coolyo/afz-grocery-browser-test-tools/node_modules/playwright');
const fs=require('fs'),path=require('path'),assert=require('node:assert/strict');
const origin=process.env.AFZ_GATEWAY_QA_ORIGIN,out=process.env.AFZ_GATEWAY_QA_OUTPUT;
assert.equal(new URL(origin).hostname,'localhost');assert.equal(new URL(origin).protocol,'http:');
(async()=>{
 const browser=await chromium.launch({headless:true,executablePath:process.env.AFZ_CHROME||'/home/coolyo/afz-grocery-browser-test-tools/browsers/chromium_headless_shell-1248/chrome-headless-shell-linux64/chrome-headless-shell',args:['--no-sandbox','--disable-dev-shm-usage','--disable-gpu']});
 const results=[];
 try{for(const width of [360,412,1280]){
  const ctx=await browser.newContext({viewport:{width,height:900},extraHTTPHeaders:{'Tailscale-User-Login':'owner@example.test'},reducedMotion:'reduce'});
  await ctx.route('**/posters/*.img',r=>r.fulfill({status:404,body:''}));
  const page=await ctx.newPage(),errors=[],writes=[];page.on('pageerror',e=>errors.push(e.message));
  ctx.on('request',r=>{if(r.method()==='POST')writes.push({path:new URL(r.url()).pathname,body:r.postDataJSON()});});
  await page.goto(origin+'/movie-night/');await page.locator('#open-add-movie:not(:disabled)').waitFor();
  await page.locator('#open-add-movie').click();await page.locator('#manual-add-query').fill('Nothing');await page.locator('#manual-add-search').click();
  await page.waitForFunction(()=>document.querySelector('#manual-add-status').textContent.includes('No matching movies'));
  await page.locator('#manual-add-query').fill('Original');await page.locator('#manual-add-query').press('Enter');
  const add=page.locator('#manual-add-results button').first();await add.waitFor();
  assert.equal(await page.locator('#manual-add-results .manual-add-card').count(),2);
  const texts=await page.locator('#manual-add-results').textContent();assert(texts.includes('2008'));assert(texts.includes('2020'));
  // Simulated failed write cannot display success or disable retry.
  await page.route('**/api/feedback',r=>r.request().postDataJSON()?.action==='add-title'?r.fulfill({status:503,contentType:'application/json',body:'{"detail":"fixture unavailable"}'}):r.continue());
  await add.click();await page.waitForFunction(()=>document.querySelector('#manual-add-status').textContent.includes('temporarily unavailable'));
  assert.equal(await add.isEnabled(),true);assert.equal(await add.textContent(),'Add to Movie Night');await page.unroute('**/api/feedback');
  await add.click();await page.waitForFunction(()=>document.querySelector('#manual-add-results button')?.textContent==='Added');
  assert.equal(await add.isDisabled(),true);
  const saved=await page.evaluate(async()=>{const r=await fetch('/movie-night/api/shortlist');return r.json();});
  assert(saved.movies.some(m=>m.id==='tt90000000'));assert.deepEqual(saved.finalized.ids,['tt12345','tt12346','tt12347']);
  await page.screenshot({path:path.join(out,'added-'+width+'.png')});
  await page.locator('#close-add-movie').click();await page.locator('#add-movie-dialog').waitFor({state:'hidden'});
  await page.reload();await page.locator('#open-add-movie:not(:disabled)').waitFor();
  assert.equal(await page.locator('#movies [data-movie="tt90000000"]').count(),1);
  // Keyboard cancel preserves saved movies; no stale response repopulates a closed dialog.
  await page.locator('#open-add-movie').click();await page.locator('#manual-add-query').fill('Original');
  await page.route('**/api/feedback',async r=>{if(r.request().postDataJSON()?.action==='search-titles')await new Promise(resolve=>setTimeout(resolve,300));await r.continue();});
  await page.locator('#manual-add-search').click();await page.locator('#manual-add-query').press('Escape');
  await page.waitForTimeout(1200);assert.equal(await page.locator('#add-movie-dialog').isVisible(),false);await page.unroute('**/api/feedback');
  await page.locator('#open-add-movie').click();
  const bounds=await page.locator('#add-movie-dialog').evaluate(e=>({left:e.getBoundingClientRect().left,right:e.getBoundingClientRect().right,overflow:e.scrollWidth>e.clientWidth+1}));
  assert(bounds.left>=0&&bounds.right<=width+1);assert.equal(bounds.overflow,false);
  assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth+1),false);
  assert.deepEqual(errors,[]);assert(writes.every(w=>w.path==='/movie-night/api/feedback'&&['search-titles','similar-status','add-title'].includes(w.body.action)));
  const session=await page.evaluate(async()=>{const r=await fetch('/movie-night/api/add-session');return {status:r.status,data:await r.json()};});
  assert.equal(session.status,200);assert.equal(session.data.version,1);assert.equal(session.data.addEnabled,true);
  results.push({width,emptySearch:true,yearDisambiguation:true,retryAfterFailure:true,addedOnlyAfterAck:true,persisted:true,cancelledSearchIgnored:true,noOverflow:true,noFinalizeOrDownload:true,errors});
  await ctx.close();
 }}finally{await browser.close();}
 fs.writeFileSync(path.join(out,'browser-results.json'),JSON.stringify({passed:true,results},null,2));console.log(JSON.stringify(results));
})().catch(e=>{console.error(e);process.exitCode=1;});
