// Rich title previews through the real owner gateway/API; disposable metadata only.
const {chromium}=require(process.env.AFZ_PLAYWRIGHT||'/home/coolyo/afz-grocery-browser-test-tools/node_modules/playwright');
const fs=require('fs'),path=require('path'),assert=require('node:assert/strict');
const origin=process.env.AFZ_GATEWAY_QA_ORIGIN,out=process.env.AFZ_GATEWAY_QA_OUTPUT;
const pixel=Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a6l8AAAAASUVORK5CYII=','base64');
(async()=>{
 const browser=await chromium.launch({headless:true,executablePath:process.env.AFZ_CHROME||'/home/coolyo/afz-grocery-browser-test-tools/browsers/chromium_headless_shell-1248/chrome-headless-shell-linux64/chrome-headless-shell',args:['--no-sandbox','--disable-dev-shm-usage','--disable-gpu']});
 const results=[];
 try{for(const width of [360,412,1280]){
  const ctx=await browser.newContext({viewport:{width,height:860},hasTouch:width<600,extraHTTPHeaders:{'Tailscale-User-Login':'owner@example.test'},reducedMotion:'reduce'});
  await ctx.route('**/posters/*.img',r=>r.request().url().includes('tt0030241')?r.fulfill({status:404,body:''}):r.fulfill({status:200,contentType:'image/png',body:pixel}));
  const p=await ctx.newPage(),errors=[],actions=[];p.on('pageerror',e=>errors.push(e.message));
  ctx.on('request',r=>{if(r.method()==='POST')actions.push(r.postDataJSON());});
  await p.goto(origin+'/movie-night/');const input=p.getByRole('combobox',{name:'Movie title'});
  await p.locator('#similar-query:not(:disabled)').waitFor();await input.fill('Holiday');
  const holiday=p.getByRole('option',{name:'Holiday · 2014',exact:true});await holiday.waitFor();
  await holiday.locator('.title-option-people').waitFor();
  assert((await holiday.textContent()).includes('Akshay Kumar'));assert((await holiday.textContent()).includes('A.R. Murugadoss'));
  assert((await holiday.textContent()).includes('2h 50m'));assert((await holiday.textContent()).includes('IMDb 7.2'));
  assert((await holiday.textContent()).includes('sleeper cells'));assert((await holiday.textContent()).includes('Action'));
  await p.waitForFunction(()=>document.querySelector('#movie-title-option-0 img')?.naturalWidth>0);
  assert(await holiday.getAttribute('aria-describedby'));
  const older=p.getByRole('option',{name:'Holiday · 1938',exact:true});await older.scrollIntoViewIfNeeded();
  await older.locator('.title-option-people').waitFor();assert((await older.textContent()).includes('Cary Grant'));
  assert((await older.textContent()).includes('1h 35m'));assert.equal(await older.locator('img').count(),0);
  assert(await older.locator('.title-option-poster span').isVisible());
  assert(actions.filter(a=>a.action==='title-preview').length<8,'off-screen options should not all fetch');
  await holiday.scrollIntoViewIfNeeded();await p.screenshot({path:path.join(out,'details-'+width+'.png')});
  // Reopening uses the same bounded client preview cache.
  const before=actions.filter(a=>a.action==='title-preview'&&a.imdb==='tt2556308').length;
  await input.press('Escape');await input.press('ArrowDown');await holiday.waitFor();await p.waitForTimeout(300);
  assert.equal(actions.filter(a=>a.action==='title-preview'&&a.imdb==='tt2556308').length,before);
  // A late preview cannot repaint the new query or reopen a cleared popup.
  await input.fill('SlowDetails');await p.waitForFunction(()=>document.querySelector('[data-preview="loading"]'));
  await input.fill('LatestDetails');const latest=p.getByRole('option',{name:'Latest details movie · 2008',exact:true});
  await latest.locator('.title-option-people').waitFor();assert((await latest.textContent()).includes('Current Actor'));
  assert(!(await p.locator('#similar-titles').textContent()).includes('Old Actor'));
  await input.fill('LiteralDetails');const literal=p.getByRole('option',{name:'Literal details movie · 2008',exact:true});
  await literal.locator('.title-option-story').waitFor();assert((await literal.textContent()).includes('<script>'));
  assert.equal(await literal.locator('.title-option-detail img,.title-option-detail script').count(),0);
  await input.fill('SparseDetails');const sparse=p.getByRole('option',{name:'Sparse details movie · 2008',exact:true});
  await sparse.locator('.title-option-story').waitFor();assert((await sparse.textContent()).includes('Synopsis unavailable'));
  assert.equal(await sparse.locator('.title-option-facts,.title-option-people,.title-option-director').count(),0);
  // Failed optional details leave title selection available and can be retried.
  await p.route('**/api/feedback',r=>r.request().postDataJSON()?.action==='title-preview'?r.fulfill({status:503,contentType:'application/json',body:'{"detail":"unavailable"}'}):r.continue());
  await input.fill('FailDetails');const failed=p.getByRole('option',{name:'Failed details movie · 2008',exact:true});
  await failed.locator('.title-option-detail').filter({hasText:'Details unavailable'}).waitFor();assert(await failed.isEnabled());
  await p.unroute('**/api/feedback');await p.locator('#search-titles').click();await failed.locator('.title-option-people').waitFor();
  await input.fill('Holiday 2014');await holiday.locator('.title-option-people').waitFor();
  const popup=await p.locator('#title-popup').boundingBox(),tray=await p.locator('#selection').boundingBox();
  assert(popup.x>=0&&popup.x+popup.width<=width+1&&popup.y>=0&&popup.y+popup.height<=tray.y+1);
  if(width<600)await holiday.tap();else{await input.press('ArrowDown');await input.press('Enter');}
  await p.locator('#similar-results').waitFor({state:'visible'});assert(await p.locator('#title-popup').isHidden());
  assert(actions.some(a=>a.action==='find-similar'&&a.imdb==='tt2556308'));
  const overflow=await p.evaluate(()=>document.documentElement.scrollWidth>innerWidth);
  assert(!overflow);assert.deepEqual(errors,[]);assert(actions.every(a=>['search-titles','title-preview','similar-status','find-similar'].includes(a.action)));
  results.push({width,details:true,poster:true,missingPoster:true,cache:true,stalePreviewIgnored:true,literalTextSafe:true,retry:true,correctSelection:true,overflow,errors});await ctx.close();
 }}finally{await browser.close();}
 fs.writeFileSync(path.join(out,'browser-results.json'),JSON.stringify({passed:true,results},null,2));console.log(JSON.stringify(results));
})().catch(e=>{console.error(e);process.exitCode=1;});
