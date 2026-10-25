// Real HTTPS title search, read-only metadata actions. Never add, rate or finalize.
const {chromium}=require(process.env.AFZ_PLAYWRIGHT||'/home/coolyo/afz-grocery-browser-test-tools/node_modules/playwright');
const fs=require('fs'),path=require('path'),assert=require('node:assert/strict');
const out=path.resolve(__dirname,'../qa/related-search-live');fs.mkdirSync(out,{recursive:true});
(async()=>{
 const browser=await chromium.launch({headless:true,executablePath:process.env.AFZ_CHROME||'/home/coolyo/afz-grocery-browser-test-tools/browsers/chromium_headless_shell-1248/chrome-headless-shell-linux64/chrome-headless-shell',args:['--no-sandbox','--disable-dev-shm-usage','--disable-gpu','--host-resolver-rules=MAP hpenvy.tailc9bb62.ts.net 100.71.26.69']});
 const results=[];
 try{for(const width of [360,412,1280]){
  const p=await browser.newPage({viewport:{width,height:860},reducedMotion:'reduce'}),errors=[],blocked=[],actions=[];
  p.on('pageerror',e=>errors.push(e.message));
  await p.route('**/*',route=>{
   const r=route.request();if(['GET','HEAD'].includes(r.method()))return route.continue();
   const action=r.postDataJSON()?.action;
   if(new URL(r.url()).pathname==='/movie-night/api/feedback'&&['search-titles','title-preview','find-similar','similar-status'].includes(action)){actions.push(action);return route.continue();}
   blocked.push(r.method());return route.abort();
  });
  const response=await p.goto('https://hpenvy.tailc9bb62.ts.net:8453/movie-night/',{waitUntil:'networkidle'});assert.equal(response.status(),200);
  await p.locator('#search-titles:not(:disabled)').waitFor();
  const before=await p.evaluate(async()=>fetch('/movie-night/api/shortlist').then(r=>r.json()));assert(before.similarSearchEnabled);
  for(const query of ['Holid','Holiday','Holiday 2014']){
   await p.locator('#similar-query').fill(query);
   await p.getByRole('option',{name:'Holiday · 2014',exact:true}).waitFor({timeout:30000});
   const options=await p.getByRole('option').evaluateAll(es=>es.map(e=>e.getAttribute('aria-label')));assert(options.length>12);
   assert(options.indexOf('Holiday · 2014')<4,JSON.stringify(options.slice(0,5)));
   if(query==='Holiday 2014')assert.equal(options[0],'Holiday · 2014');
  }
  await p.getByRole('option',{name:'Holiday · 2014',exact:true}).waitFor({timeout:30000});
  assert.equal(await p.locator('#similar-query').getAttribute('aria-expanded'),'true');
  const popup=await p.locator('#title-popup').boundingBox();assert(popup.x>=0&&popup.x+popup.width<=width+1&&popup.y>=0&&popup.y+popup.height<=(await p.locator('#selection').boundingBox()).y+1);
  const chosen=p.getByRole('option',{name:'Holiday · 2014',exact:true});
  await chosen.scrollIntoViewIfNeeded();await chosen.locator('.title-option-people').waitFor({timeout:30000});
  const detailText=await chosen.textContent();
  assert(detailText.includes('Akshay Kumar'));assert(detailText.includes('Sonakshi Sinha'));assert(detailText.includes('A.R. Murugadoss'));
  assert(detailText.includes('Action'));assert(await chosen.locator('.title-option-story').textContent());
  await p.waitForFunction(()=>{const option=[...document.querySelectorAll('[role=option]')].find(e=>e.getAttribute('aria-label')==='Holiday · 2014');return option?.querySelector('img')?.naturalWidth>0;});
  await p.screenshot({path:path.join(out,'popup-'+width+'.png')});
  await p.getByRole('option',{name:'Holiday · 2014',exact:true}).click();await p.locator('#similar-results').waitFor({state:'visible',timeout:80000});
  assert(await p.locator('#title-popup').isHidden());
  const cards=p.locator('#similar-movies .movie-card');const count=await cards.count();assert(count>0);
  const rows=await p.locator('#similar-movies .movie-card').evaluateAll(es=>es.map(e=>({id:e.dataset.movie,text:e.textContent})));
  assert(rows.some(r=>r.text.includes('Baby')&&r.text.includes('2015')));
  assert(rows.some(r=>r.text.includes('Rowdy Rathore')||r.text.includes('Akira')||r.text.includes('Ghajini')));
  assert(rows.some(r=>r.text.includes('Comedy')||r.text.includes('Drama')));
  assert(rows.filter(r=>r.text.includes('Same country: India')).length>=4);
  assert((await p.locator('#similar-status').textContent()).includes('all genres and years'));
  const known=p.locator('#similar-movies [data-movie="tt26584495"] [data-similar-add]');if(await known.count())assert(await known.isDisabled());
  assert.equal(await p.locator('#similar-movies [data-movie="tt2556308"]').count(),0);
  assert.equal(await cards.locator('.similar-reasons').count(),count);
  await p.locator('#similar-results-title').scrollIntoViewIfNeeded();
  const overflow=await p.evaluate(()=>document.documentElement.scrollWidth>innerWidth);
  const small=await p.locator('#similar-search button:visible,#similar-search input:visible').evaluateAll(es=>es.filter(e=>e.getBoundingClientRect().height<40).length);
  assert(!overflow);assert.equal(small,0);assert.deepEqual(errors,[]);assert.deepEqual(blocked,[]);
  await p.screenshot({path:path.join(out,'related-'+width+'.png')});
  await p.locator('#clear-similar').click();assert(await p.locator('#similar-results').isHidden());
  const after=await p.evaluate(async()=>fetch('/movie-night/api/shortlist').then(r=>r.json()));
  assert.deepEqual(after.genreSettings,before.genreSettings);assert.deepEqual(after.finalized,before.finalized);assert.deepEqual(after.disliked,before.disliked);assert.deepEqual(after.seen,before.seen);
  results.push({width,count,returned:rows.map(r=>({id:r.id,title:r.text.slice(0,100)})),overflow,smallControls:small,errors,blocked,readOnlyMetadataActions:actions.length,savedStateUnchanged:true});await p.close();
 }}finally{await browser.close();}
 fs.writeFileSync(path.join(out,'results.json'),JSON.stringify({passed:true,results},null,2));console.log('RELATED_SEARCH_LIVE_HTTPS_PASS_360_412_1280_NO_SAVED_STATE_WRITES');console.log(JSON.stringify(results));
})().catch(e=>{console.error(e);process.exitCode=1;});
