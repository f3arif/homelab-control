// Real API/gateway with disposable state: broad search, deliberate Add, no acquisition.
const {chromium}=require(process.env.AFZ_PLAYWRIGHT||'/home/coolyo/afz-grocery-browser-test-tools/node_modules/playwright');
const fs=require('fs'),path=require('path'),assert=require('node:assert/strict');
const origin=process.env.AFZ_GATEWAY_QA_ORIGIN,out=process.env.AFZ_GATEWAY_QA_OUTPUT;
(async()=>{
 const browser=await chromium.launch({headless:true,executablePath:process.env.AFZ_CHROME||'/home/coolyo/afz-grocery-browser-test-tools/browsers/chromium_headless_shell-1248/chrome-headless-shell-linux64/chrome-headless-shell',args:['--no-sandbox','--disable-dev-shm-usage','--disable-gpu']});
 const results=[];
 try{for(const width of [360,412,1280]){
  const ctx=await browser.newContext({viewport:{width,height:860},hasTouch:width<600,extraHTTPHeaders:{'Tailscale-User-Login':'owner@example.test'},reducedMotion:'reduce'});
  await ctx.route('**/posters/*.img',r=>r.fulfill({status:404,body:''}));
  const p=await ctx.newPage(),errors=[],writes=[];p.on('pageerror',e=>errors.push(e.message));
  ctx.on('request',r=>{if(r.method()==='POST')writes.push({path:new URL(r.url()).pathname,body:r.postDataJSON()});});
  await p.goto(origin+'/movie-night/');await p.locator('#search-titles:not(:disabled)').waitFor();
  const read=()=>p.evaluate(async()=>fetch('/movie-night/api/shortlist').then(r=>r.json()));
  const before=await read();assert(before.genreSettings.excluded.includes('Animation'));
  await p.locator('#similar-query').fill('Original');
  await p.getByRole('option',{name:'Original · 2008',exact:true}).click();
  await p.locator('#similar-results').waitFor({state:'visible'});
  assert.equal(await p.locator('#similar-movies .movie-card').count(),4);
  assert((await p.locator('#similar-status').textContent()).includes('all genres and years'));
  const old=p.locator('#similar-movies [data-movie="tt90000004"]');
  assert((await old.textContent()).includes('2010'));assert((await old.textContent()).includes('Animation'));
  const watched=p.locator('[data-similar-add="tt90000001"]'),known=p.locator('[data-similar-add="tt90000002"]');
  assert(await watched.isDisabled());assert(await known.isDisabled());assert((await watched.textContent()).includes('Watched'));
  assert.deepEqual((await read()).genreSettings,before.genreSettings);
  // A normal preference save must leave the explicit search and Add controls usable.
  await p.locator('#edit-genres').click();await p.locator('#genre-editor').waitFor({state:'visible'});
  if(before.genreSettings.excluded.includes('Sci-Fi'))await p.locator('#include-add').selectOption('Sci-Fi');
  else await p.locator('#exclude-add').selectOption('Sci-Fi');
  await p.locator('#save-genres').click();await p.locator('#genre-editor').waitFor({state:'hidden'});
  assert(await p.locator('#similar-results').isVisible());assert(await watched.isDisabled());assert(await known.isDisabled());
  const add=p.locator('[data-similar-add="tt90000004"]');assert(await add.isEnabled());
  await p.locator('#similar-results-title').scrollIntoViewIfNeeded();await p.screenshot({path:path.join(out,'all-genres-'+width+'.png')});
  if(width<600)await add.tap();else await add.click();
  const admitted=p.locator('#movies [data-movie="tt90000004"]');await admitted.waitFor();
  assert((await read()).eligibleIds.includes('tt90000004'));
  await admitted.locator('.pick-toggle').click();assert((await p.locator('#selection-count').textContent()).includes('4 of 10'));
  await p.reload();await p.locator('#search-titles:not(:disabled)').waitFor();
  assert.equal(await p.locator('#movies [data-movie="tt90000004"]').count(),1);
  const after=await read();assert(after.genreSettings.excluded.includes('Animation'));assert(after.movies.find(r=>r.id==='tt90000004').manualSuggestion);
  assert.deepEqual(after.finalized,before.finalized);assert.deepEqual(after.seen,before.seen);assert.deepEqual(after.disliked,before.disliked);
  const overflow=await p.evaluate(()=>document.documentElement.scrollWidth>innerWidth);assert(!overflow);
  const small=await p.locator('#similar-search button:visible,#similar-search input:visible').evaluateAll(es=>es.filter(e=>e.getBoundingClientRect().height<40).length);assert.equal(small,0);
  assert.deepEqual(errors,[]);assert(writes.every(w=>w.path==='/movie-night/api/feedback'&&['search-titles','title-preview','find-similar','similar-status','add-similar','set-genre-settings'].includes(w.body.action)));
  await p.screenshot({path:path.join(out,'added-'+width+'.png')});
  results.push({width,unfiltered:true,watchedVisibleAndBlocked:true,genreEditKeptSearch:true,oldExcludedAddPersisted:true,canPick:true,savedChoicesUnchanged:true,overflow,smallControls:small,errors});await ctx.close();
 }}finally{await browser.close();}
 fs.writeFileSync(path.join(out,'browser-results.json'),JSON.stringify({passed:true,results},null,2));console.log(JSON.stringify(results));
})().catch(e=>{console.error(e);process.exitCode=1;});
