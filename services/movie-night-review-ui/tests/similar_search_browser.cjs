// Public metadata fixture behind the real authenticated owner gateway and API.
const {chromium}=require(process.env.AFZ_PLAYWRIGHT||'/home/coolyo/afz-grocery-browser-test-tools/node_modules/playwright');
const fs=require('fs'),path=require('path'),assert=require('node:assert/strict');
const origin=process.env.AFZ_GATEWAY_QA_ORIGIN,out=process.env.AFZ_GATEWAY_QA_OUTPUT;
(async()=>{
 const browser=await chromium.launch({headless:true,executablePath:process.env.AFZ_CHROME||'/home/coolyo/afz-grocery-browser-test-tools/browsers/chromium_headless_shell-1248/chrome-headless-shell-linux64/chrome-headless-shell',args:['--no-sandbox','--disable-dev-shm-usage','--disable-gpu']});
 const results=[];
 try{for(const width of [360,412,1280]){
  const ctx=await browser.newContext({viewport:{width,height:860},extraHTTPHeaders:{'Tailscale-User-Login':'owner@example.test'},reducedMotion:'reduce'});
  await ctx.route('**/posters/*.img',r=>r.fulfill({status:404,body:''}));
  const p=await ctx.newPage(),errors=[],writes=[];p.on('pageerror',e=>errors.push(e.message));
  ctx.on('request',r=>{if(r.method()==='POST')writes.push({path:new URL(r.url()).pathname,body:r.postDataJSON()});});
  await p.goto(origin+'/movie-night/');await p.locator('#search-titles:not(:disabled)').waitFor();
  await p.locator('#similar-query').fill('Nothing');await p.locator('#search-titles').click();
  await p.waitForFunction(()=>document.querySelector('#similar-status').textContent.includes('No movie titles'));
  await p.locator('#similar-query').fill('Original');await p.locator('#similar-query').press('Enter');
  await p.getByRole('option',{name:'Original · 2008',exact:true}).waitFor();
  assert.equal(await p.getByRole('option',{name:'Original · 2020',exact:true}).count(),1);
  await p.getByRole('option',{name:'Original · 2008',exact:true}).click();
  await p.locator('#similar-results').waitFor({state:'visible'});
  assert.equal(await p.locator('#similar-movies .movie-card').count(),2);
  assert((await p.locator('#similar-movies').textContent()).includes('Genre match only'));
  await p.locator('#similar-results').scrollIntoViewIfNeeded();await p.screenshot({path:path.join(out,'results-'+width+'.png')});
  const add=p.locator('#similar-movies [data-similar-add="tt90000001"]');
  if(width===360){
   await p.route('**/api/feedback',r=>r.request().postDataJSON()?.action==='add-similar'?r.abort():r.continue());
   await add.click();await p.waitForFunction(()=>document.querySelector('#similar-status').textContent.includes('interrupted'));
   await p.unroute('**/api/feedback');
  }
  await add.click();await p.locator('#movies [data-movie="tt90000001"]').waitFor();
  assert((await p.locator('#movies').textContent()).includes('Dream Mission 1'));
  await p.locator('#movies [data-movie="tt90000001"] .pick-toggle').click();
  assert((await p.locator('#selection-count').textContent()).includes('4 of 10'));
  await p.reload();await p.locator('#search-titles:not(:disabled)').waitFor();
  assert.equal(await p.locator('#movies [data-movie="tt90000001"]').count(),1);
  // Provider/API failure leaves the page and its saved selections usable.
  await p.route('**/api/feedback',r=>r.request().postDataJSON()?.action==='search-titles'?r.fulfill({status:503,contentType:'application/json',body:'{"detail":"unavailable"}'}):r.continue());
  await p.locator('#similar-query').fill('Original');await p.locator('#search-titles').click();
  await p.waitForFunction(()=>document.querySelector('#similar-status').textContent.includes('temporarily unavailable'));
  await p.unroute('**/api/feedback');
  // Clear invalidates an in-flight response instead of repopulating old results.
  await p.route('**/api/feedback',async r=>{if(r.request().postDataJSON()?.action==='search-titles')await new Promise(x=>setTimeout(x,400));await r.continue();});
  await p.locator('#search-titles').click();await p.locator('#clear-similar').click();await p.waitForTimeout(1200);
  assert.equal(await p.locator('#similar-titles button').count(),0);assert(await p.locator('#similar-results').isHidden());await p.unroute('**/api/feedback');
  await p.locator('#similar-search').scrollIntoViewIfNeeded();
  const overflow=await p.evaluate(()=>document.documentElement.scrollWidth>innerWidth);
  const small=await p.locator('#similar-search button:visible,#similar-search input:visible').evaluateAll(es=>es.filter(e=>e.getBoundingClientRect().height<40).length);
  assert(!overflow);assert.equal(small,0);assert.deepEqual(errors,[]);
  assert(writes.every(w=>w.path==='/movie-night/api/feedback'&&['search-titles','find-similar','similar-status','add-similar'].includes(w.body.action)));
  await p.screenshot({path:path.join(out,'search-'+width+'.png')});
  results.push({width,emptySearch:true,disambiguation:true,persisted:true,canPick:true,failedSearchRecovery:true,clearIgnoresLateResults:true,overflow,smallControls:small,errors});await ctx.close();
 }}finally{await browser.close();}
 fs.writeFileSync(path.join(out,'browser-results.json'),JSON.stringify({passed:true,results},null,2));console.log(JSON.stringify(results));
})().catch(e=>{console.error(e);process.exitCode=1;});
