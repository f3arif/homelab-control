// Real owner gateway/API: title autocomplete, touch/keyboard, races and read-only state.
const {chromium}=require(process.env.AFZ_PLAYWRIGHT||'/home/coolyo/afz-grocery-browser-test-tools/node_modules/playwright');
const fs=require('fs'),path=require('path'),assert=require('node:assert/strict');
const origin=process.env.AFZ_GATEWAY_QA_ORIGIN,out=process.env.AFZ_GATEWAY_QA_OUTPUT;
(async()=>{
 const browser=await chromium.launch({headless:true,executablePath:process.env.AFZ_CHROME||'/home/coolyo/afz-grocery-browser-test-tools/browsers/chromium_headless_shell-1248/chrome-headless-shell-linux64/chrome-headless-shell',args:['--no-sandbox','--disable-dev-shm-usage','--disable-gpu']});
 const results=[];
 try{for(const width of [360,412,1280]){
  const ctx=await browser.newContext({viewport:{width,height:860},hasTouch:width<600,extraHTTPHeaders:{'Tailscale-User-Login':'owner@example.test'},reducedMotion:'reduce'});
  await ctx.route('**/posters/*.img',r=>r.fulfill({status:404,body:''}));
  const p=await ctx.newPage(),errors=[],requests=[];p.on('pageerror',e=>errors.push(e.message));
  ctx.on('request',r=>{if(r.method()==='POST')requests.push(r.postDataJSON());});
  await p.goto(origin+'/movie-night/');const input=p.getByRole('combobox',{name:'Movie title'});
  await p.locator('#similar-query:not(:disabled)').waitFor();await input.fill('O');await p.waitForTimeout(450);
  assert.equal(requests.filter(r=>r.action==='search-titles').length,0);assert(await p.locator('#title-popup').isHidden());
  await input.fill('');await input.pressSequentially('Original',{delay:45});
  await p.getByRole('option',{name:'Original · 2008',exact:true}).waitFor();
  assert.equal(requests.filter(r=>r.action==='search-titles').length,1);assert.equal(await input.getAttribute('aria-expanded'),'true');
  assert.equal(await p.getByRole('option',{name:'Original · 2020',exact:true}).count(),1);
  const bounds=await p.locator('#title-popup').boundingBox();assert(bounds.x>=0&&bounds.x+bounds.width<=width+1);
  assert(bounds.y>=0&&bounds.y+bounds.height<=860);
  await p.screenshot({path:path.join(out,'popup-'+width+'.png')});
  await input.press('ArrowDown');assert.equal(await input.getAttribute('aria-activedescendant'),'movie-title-option-0');
  await input.press('ArrowDown');assert.equal(await input.getAttribute('aria-activedescendant'),'movie-title-option-1');
  await input.press('ArrowUp');await input.press('Enter');await p.locator('#similar-results').waitFor({state:'visible'});
  assert(await p.locator('#title-popup').isHidden());assert.equal(await input.inputValue(),'Original');
  const heading=await p.locator('#similar-results-title').boundingBox();assert(heading.y>=0&&heading.y<100);
  await input.focus();await p.getByRole('option',{name:'Original · 2008',exact:true}).waitFor();
  await input.press('Escape');assert(await p.locator('#title-popup').isHidden());assert.equal(await input.inputValue(),'Original');
  await input.press('ArrowDown');await p.getByRole('option',{name:'Original · 2008',exact:true}).waitFor();
  await p.locator('#similar-title').click();assert(await p.locator('#title-popup').isHidden());
  await input.focus();await p.getByRole('option',{name:'Original · 2008',exact:true}).waitFor();
  if(width<600)await p.getByRole('option',{name:'Original · 2008',exact:true}).tap();else await p.getByRole('option',{name:'Original · 2008',exact:true}).click();
  await p.locator('#similar-results').waitFor({state:'visible'});assert(await p.locator('#title-popup').isHidden());
  // New typing waits behind the old metadata job, but only the newest result can display.
  await input.fill('Slow '+width);await p.waitForTimeout(450);await input.fill('Latest '+width);
  await p.getByRole('option',{name:'Latest result · 2008',exact:true}).waitFor();assert.equal(await p.getByRole('option',{name:'Slow result · 2008',exact:true}).count(),0);
  assert.equal(requests.filter(r=>r.action==='search-titles'&&r.query==='Latest '+width).length,1);
  await input.fill('Slow clear '+width);await p.waitForTimeout(450);await p.getByRole('button',{name:'Clear search',exact:true}).click();await p.waitForTimeout(1700);
  assert(await p.locator('#title-popup').isHidden());assert.equal(await input.inputValue(),'');
  await input.fill('Nothing');await p.locator('#title-popup-status').filter({hasText:'No movie titles'}).waitFor();assert.equal(await p.getByRole('option').count(),0);
  await input.fill('Literal');await p.getByRole('option',{name:'Literal <img src=x onerror=alert(1)> · 2008',exact:true}).waitFor();assert.equal(await p.locator('#similar-titles img').count(),0);
  // Input method editors must finish composition before a provider query starts.
  const prior=requests.filter(r=>r.action==='search-titles').length;
  await input.dispatchEvent('compositionstart');await input.fill('Original');await p.waitForTimeout(500);
  assert.equal(requests.filter(r=>r.action==='search-titles').length,prior);
  await input.dispatchEvent('compositionend');await p.getByRole('option',{name:'Original · 2008',exact:true}).waitFor();
  // Provider errors leave a retry in the popup and never affect saved choices.
  await p.route('**/api/feedback',r=>r.request().postDataJSON()?.action==='search-titles'?r.fulfill({status:503,contentType:'application/json',body:'{"detail":"unavailable"}'}):r.continue());
  await input.fill('Error');await p.locator('#title-popup-retry').waitFor({state:'visible'});await p.unroute('**/api/feedback');
  await p.locator('#title-popup-retry').click();await p.getByRole('option',{name:'Original · 2008',exact:true}).waitFor();
  await input.press('Escape');await input.focus();await p.locator('#search-titles').click();await p.getByRole('option',{name:'Original · 2008',exact:true}).waitFor();
  const overflow=await p.evaluate(()=>document.documentElement.scrollWidth>innerWidth);
  const small=await p.locator('#similar-search button:visible,#similar-search input:visible').evaluateAll(es=>es.filter(e=>e.getBoundingClientRect().height<40).length);
  assert(!overflow);assert.equal(small,0);assert.deepEqual(errors,[]);
  assert(requests.every(r=>['search-titles','find-similar','similar-status'].includes(r.action)));
  results.push({width,debounced:true,keyboard:true,touch:width<600,newestQueryOnly:true,clearIgnoresLateResults:true,ime:true,retry:true,literalTextSafe:true,overflow,smallControls:small,errors});await ctx.close();
 }}finally{await browser.close();}
 fs.writeFileSync(path.join(out,'browser-results.json'),JSON.stringify({passed:true,results},null,2));console.log(JSON.stringify(results));
})().catch(e=>{console.error(e);process.exitCode=1;});
