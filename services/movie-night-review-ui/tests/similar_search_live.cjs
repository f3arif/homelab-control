// Real HTTPS title search, read-only metadata actions. Never add, rate or finalize.
const {chromium}=require(process.env.AFZ_PLAYWRIGHT||'/home/coolyo/afz-grocery-browser-test-tools/node_modules/playwright');
const fs=require('fs'),path=require('path'),assert=require('node:assert/strict');
const out=path.resolve(__dirname,'../qa/similar-search-live');fs.mkdirSync(out,{recursive:true});
(async()=>{
 const browser=await chromium.launch({headless:true,executablePath:process.env.AFZ_CHROME||'/home/coolyo/afz-grocery-browser-test-tools/browsers/chromium_headless_shell-1248/chrome-headless-shell-linux64/chrome-headless-shell',args:['--no-sandbox','--disable-dev-shm-usage','--disable-gpu','--host-resolver-rules=MAP hpenvy.tailc9bb62.ts.net 100.71.26.69']});
 const results=[];
 try{for(const width of [360,412,1280]){
  const p=await browser.newPage({viewport:{width,height:860},reducedMotion:'reduce'}),errors=[],blocked=[],actions=[];
  p.on('pageerror',e=>errors.push(e.message));
  await p.route('**/*',route=>{
   const r=route.request();if(['GET','HEAD'].includes(r.method()))return route.continue();
   const action=r.postDataJSON()?.action;
   if(new URL(r.url()).pathname==='/movie-night/api/feedback'&&['search-titles','find-similar','similar-status'].includes(action)){actions.push(action);return route.continue();}
   blocked.push(r.method());return route.abort();
  });
  const response=await p.goto('https://hpenvy.tailc9bb62.ts.net:8453/movie-night/',{waitUntil:'networkidle'});assert.equal(response.status(),200);
  await p.locator('#search-titles:not(:disabled)').waitFor();
  const before=await p.evaluate(async()=>fetch('/movie-night/api/shortlist').then(r=>r.json()));assert(before.similarSearchEnabled);
  await p.locator('#similar-query').pressSequentially('Inception',{delay:70});
  await p.getByRole('option',{name:'Inception · 2010',exact:true}).waitFor({timeout:30000});
  assert.equal(await p.locator('#similar-query').getAttribute('aria-expanded'),'true');
  const popup=await p.locator('#title-popup').boundingBox();assert(popup.x>=0&&popup.x+popup.width<=width+1&&popup.y>=0&&popup.y+popup.height<=860);
  await p.screenshot({path:path.join(out,'popup-'+width+'.png')});
  await p.getByRole('option',{name:'Inception · 2010',exact:true}).click();await p.locator('#similar-results').waitFor({state:'visible',timeout:80000});
  assert(await p.locator('#title-popup').isHidden());
  const cards=p.locator('#similar-movies .movie-card');const count=await cards.count();assert(count>0);
  assert.equal(await p.locator('#similar-movies [data-movie="tt26584495"]').count(),0);
  assert.equal(await p.locator('#similar-movies [data-movie="tt1375666"]').count(),0);
  assert.equal(await cards.locator('.similar-reasons').count(),count);
  await p.locator('#similar-results-title').scrollIntoViewIfNeeded();
  const overflow=await p.evaluate(()=>document.documentElement.scrollWidth>innerWidth);
  const small=await p.locator('#similar-search button:visible,#similar-search input:visible').evaluateAll(es=>es.filter(e=>e.getBoundingClientRect().height<40).length);
  assert(!overflow);assert.equal(small,0);assert.deepEqual(errors,[]);assert.deepEqual(blocked,[]);
  await p.screenshot({path:path.join(out,'related-'+width+'.png')});
  await p.locator('#clear-similar').click();assert(await p.locator('#similar-results').isHidden());
  const after=await p.evaluate(async()=>fetch('/movie-night/api/shortlist').then(r=>r.json()));
  assert.deepEqual(after.genreSettings,before.genreSettings);assert.deepEqual(after.finalized,before.finalized);assert.deepEqual(after.disliked,before.disliked);assert.deepEqual(after.seen,before.seen);
  results.push({width,count,overflow,smallControls:small,errors,blocked,readOnlyMetadataActions:actions.length,savedStateUnchanged:true});await p.close();
 }}finally{await browser.close();}
 fs.writeFileSync(path.join(out,'results.json'),JSON.stringify({passed:true,results},null,2));console.log('TITLE_POPUP_LIVE_HTTPS_PASS_360_412_1280_NO_SAVED_STATE_WRITES');console.log(JSON.stringify(results));
})().catch(e=>{console.error(e);process.exitCode=1;});
