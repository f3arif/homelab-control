// Native genre editing against the disposable server and the real owner gateway.
const {chromium}=require(process.env.AFZ_PLAYWRIGHT||'/home/coolyo/afz-grocery-browser-test-tools/node_modules/playwright');
const fs=require('fs'),path=require('path'),assert=require('node:assert/strict');
const origin=process.env.AFZ_GATEWAY_QA_ORIGIN,out=process.env.AFZ_GATEWAY_QA_OUTPUT;
(async()=>{
 const browser=await chromium.launch({headless:true,executablePath:process.env.AFZ_CHROME||'/home/coolyo/afz-grocery-browser-test-tools/browsers/chromium_headless_shell-1248/chrome-headless-shell-linux64/chrome-headless-shell',args:['--no-sandbox','--disable-dev-shm-usage','--disable-gpu']});
 const results=[];
 const state=p=>p.evaluate(async()=>{const r=await fetch('/movie-night/api/shortlist');if(!r.ok)throw Error('Fixture shortlist unavailable');return r.json();});
 const open=async p=>{await p.locator('#edit-genres').click();await p.locator('#genre-editor').waitFor({state:'visible'});};
 const save=async p=>{await p.locator('#save-genres').click();await p.locator('#genre-editor').waitFor({state:'hidden'});};
 try{for(const width of [360,412,1280]){
  const context=await browser.newContext({viewport:{width,height:860},extraHTTPHeaders:{'Tailscale-User-Login':'owner@example.test'},reducedMotion:'reduce'});
  await context.route('**/posters/*.img',r=>r.fulfill({status:404,body:''}));
  const p=await context.newPage(),errors=[],writes=[];p.on('pageerror',e=>errors.push(e.message));
  context.on('request',r=>{if(r.method()==='POST')writes.push({path:new URL(r.url()).pathname,body:r.postDataJSON()});});
  await p.goto(origin+'/movie-night/');await p.locator('#edit-genres:not(:disabled)').waitFor();
  const initial=(await state(p)).genreSettings;
  await open(p);await p.locator('#include-add').selectOption('Animation');
  assert.equal(await p.getByRole('button',{name:'Remove Animation from excluded genres',exact:true}).count(),0);
  await p.locator('#cancel-genres').click();assert.equal((await state(p)).genreSettings.revision,initial.revision);
  await open(p);await p.locator('#include-add').selectOption('Animation');
  await p.locator('#genre-editor').evaluate(e=>e.scrollTop=0);await p.screenshot({path:path.join(out,'editor-'+width+'.png')});
  await save(p);await p.locator('#movies').getByRole('heading',{name:'Fixture Animation',exact:true}).waitFor();
  await p.reload();await p.locator('#edit-genres:not(:disabled)').waitFor();
  assert((await state(p)).genreSettings.included.includes('Animation'));
  await open(p);await p.locator('#exclude-add').selectOption('Action');await save(p);
  assert.equal(await p.locator('#finalized-movies .genre-excluded').count(),3);
  assert.equal(await p.locator('#movies .movie-card[data-movie="tt12345"]').count(),0);
  const other=await context.newPage();other.on('pageerror',e=>errors.push(e.message));
  await other.goto(origin+'/movie-night/');await other.locator('#edit-genres:not(:disabled)').waitFor();
  await open(other);await open(p);await p.locator('#include-add').selectOption('Drama');await save(p);
  await other.locator('#exclude-add').selectOption('Horror');await other.locator('#save-genres').click();
  await other.waitForFunction(()=>document.querySelector('#genre-status').textContent.includes('another device'));
  assert(await other.locator('#genre-editor').isVisible());assert((await state(other)).genreSettings.included.includes('Drama'));
  await other.locator('#reload-genres').click();await other.waitForFunction(()=>document.querySelector('#genre-status').textContent==='Loaded saved settings.');
  await other.locator('#include-clear').click();await other.locator('#exclude-clear').click();await save(other);
  assert.equal(await other.locator('#movies .movie-card').count(),7);
  await open(other);await other.locator('#exclude-add').selectOption('Romance');await save(other);
  assert.equal(await other.locator('#movies .movie-card').count(),6);
  await other.reload();await other.locator('#edit-genres:not(:disabled)').waitFor();
  assert.deepEqual((await state(other)).genreSettings.excluded,['Romance']);
  await open(other);await other.locator('#include-add').selectOption('Drama');
  await other.route('**/api/feedback',r=>r.abort());await other.locator('#save-genres').click();
  await other.waitForFunction(()=>document.querySelector('#genre-status').textContent.includes('interrupted'));
  assert(await other.locator('#genre-editor').isVisible());await other.unroute('**/api/feedback');
  await other.locator('#reload-genres').click();await other.waitForFunction(()=>document.querySelector('#genre-status').textContent==='Loaded saved settings.');
  assert.equal(await other.getByRole('button',{name:'Remove Drama from included genres',exact:true}).count(),0);
  const overflow=await other.evaluate(()=>document.documentElement.scrollWidth>innerWidth);assert(!overflow);
  const small=await other.locator('#genre-editor button:visible, #genre-editor select:visible').evaluateAll(es=>es.filter(e=>e.getBoundingClientRect().height<40).length);assert.equal(small,0);
  await other.screenshot({path:path.join(out,'saved-'+width+'.png')});
  await other.locator('#cancel-genres').click();
  // Restore only fixture preferences so each width starts from the same policy.
  await other.evaluate(async baseline=>{
   const latest=await (await fetch('/movie-night/api/shortlist')).json();
   const r=await fetch('/movie-night/api/feedback',{method:'POST',headers:{'Content-Type':'application/json','X-Movie-Night-CSRF':document.querySelector('meta[name="mn-csrf"]').content},body:JSON.stringify({action:'set-genre-settings',settings:{included:baseline.included,excluded:baseline.excluded,revision:latest.genreSettings.revision}})});
   if(!r.ok)throw Error('Fixture reset failed');
  },initial);
  assert(writes.length>=7&&writes.every(w=>w.path==='/movie-night/api/feedback'&&w.body.action==='set-genre-settings'));
  assert.deepEqual(errors,[]);results.push({width,persisted:true,conflictProtected:true,connectionFailureKeptDraft:true,overflow,smallControls:small,settingsWrites:writes.length,errors});await context.close();
 }}finally{await browser.close();}
 fs.writeFileSync(path.join(out,'browser-results.json'),JSON.stringify({passed:true,results},null,2));console.log(JSON.stringify(results));
})().catch(e=>{console.error(e);process.exitCode=1;});
