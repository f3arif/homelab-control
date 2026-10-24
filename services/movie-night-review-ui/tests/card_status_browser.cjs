// Read-only fixture: every card state, live transition, failure recovery and matching row.
const {chromium}=require(process.env.AFZ_PLAYWRIGHT||'/home/coolyo/afz-grocery-browser-test-tools/node_modules/playwright');
const fs=require('fs'),path=require('path'),assert=require('node:assert/strict'),crypto=require('crypto');
const root=path.resolve(__dirname,'..'),out=path.join(root,'qa/card-status');fs.mkdirSync(out,{recursive:true});
const states=['queued','checking','approved','downloading','downloaded','indexed','playback-tested','unavailable','failed','cancelled'];
const labels=['Queued','Finding a source','Queued for transfer','Downloading','Downloaded · checking availability','✓ Ready on server','✓ Ready on server','No ready source','Needs attention','Cancelled'];
const movies=states.map((_,i)=>({id:'tt'+(12345+i),name:'Fixture Movie '+(i+1),releaseInfo:'2024',genres:['Thriller'],similarToLiked:true,synopsis:'A fixture synopsis.',movieInfo:{runtimeMinutes:110,cast:['Fixture actor']}}));
const ids=movies.map(m=>m.id);
const shortlist={movies,reviewEnabled:true,actionsEnabled:true,autoDownloads:true,downloadRequestedIds:ids,eligibleIds:ids,seenStateComplete:true,shortlistFresh:true,finalized:{valid:true,ids,movies},refillRequest:{},selectionLimits:{min:3,max:10,visible:10}};
function item(i,state){return {id:'job-'+i,imdb:ids[i],name:movies[i].name,state,size:6000000000,bytesReceived:['downloaded','indexed','playback-tested'].includes(state)?6000000000:state==='downloading'?3000000000:0,downloaded:['downloaded','indexed','playback-tested'].includes(state),indexed:['indexed','playback-tested'].includes(state)};}
(async()=>{
 const browser=await chromium.launch({headless:true,executablePath:process.env.AFZ_CHROME||'/home/coolyo/afz-grocery-browser-test-tools/browsers/chromium_headless_shell-1248/chrome-headless-shell-linux64/chrome-headless-shell',args:['--no-sandbox','--disable-dev-shm-usage','--disable-gpu']});
 const results=[];
 try{for(const width of [360,412,1280]){
  const p=await browser.newPage({viewport:{width,height:860},reducedMotion:'reduce'}),errors=[],writes=[];
  p.on('pageerror',e=>errors.push(e.message));p.on('request',r=>{if(!['GET','HEAD'].includes(r.method()))writes.push(r.method());});
  let jobs=states.map((s,i)=>item(i,s)),fail=false;
  const requests=ids.map((imdb,i)=>({id:'request-'+i,jobId:'job-'+i,imdb,name:movies[i].name,state:'linked'}));
  await p.route('**/*',async route=>{
   const u=new URL(route.request().url());let body='',type='text/plain',status=200;
   if(u.pathname.endsWith('/api/shortlist')){body=JSON.stringify(shortlist);type='application/json';}
   else if(u.pathname.endsWith('/api/downloads')){body=JSON.stringify(fail?{error:'fixture unavailable'}:{requests,jobs});type='application/json';status=fail?503:200;}
   else if(u.pathname.endsWith('/screen.js')){body=fs.readFileSync(path.join(root,'src/screen.js'),'utf8');type='application/javascript';}
   else if(u.pathname.endsWith('/screen.css')){body=fs.readFileSync(path.join(root,'src/screen.css'),'utf8');type='text/css';}
   else if(u.pathname==='/movie-night/'){body=fs.readFileSync(path.join(root,'src/screen.html'),'utf8').replaceAll('__BASE__','/movie-night').replaceAll('__CSRF__','fixture').replaceAll('__MIN_PICKS__','3').replaceAll('__MAX_PICKS__','10');type='text/html';}
   else status=204;
   await route.fulfill({status,contentType:type,body});
  });
  await p.goto('http://localhost/movie-night/',{waitUntil:'networkidle'});
  const cards=p.locator('#finalized-movies .movie-card');await cards.nth(0).locator('.card-download[data-state="queued"]').waitFor();
  assert.deepEqual(await cards.locator('.card-download-status').allTextContents(),labels);
  assert.equal(await p.locator('.liked-note').count(),0);
  assert.match(await p.locator('#genre-guidance').textContent(),/genres; stories, themes and styles can vary/);
  assert.equal(await cards.locator('.server-file:visible').count(),2);
  assert.equal(await cards.nth(3).locator('progress').getAttribute('value'),'3000000000');
  assert.match(await cards.nth(3).locator('.card-download-detail').innerText(),/3.00 of 6.00 GB/);
  assert.equal(await cards.nth(5).locator('.server-file').getAttribute('href'),'/movie-night/media/'+ids[5]);
  await cards.nth(8).getByRole('button',{name:'View download details'}).click();
  assert.equal(await p.evaluate(()=>document.activeElement.dataset.imdb),ids[8]);
  // Downloaded is not yet indexed: polling must continue until it is available.
  jobs=jobs.map(j=>['queued','checking','approved','downloading'].includes(j.state)?item(ids.indexOf(j.imdb),'unavailable'):j);
  await p.evaluate(()=>loadDownloads());
  await cards.nth(4).locator('summary').click();await cards.nth(4).getByRole('button').focus();
  jobs[4]=item(4,'indexed');
  await p.waitForFunction(id=>document.querySelector(`#finalized-movies [data-movie="${id}"] .card-download`).dataset.state==='ready',ids[4],{timeout:8000});
  assert(await cards.nth(4).locator('details').evaluate(x=>x.open));
  assert(await cards.nth(4).getByRole('button').evaluate(x=>x===document.activeElement));
  assert.equal(await cards.locator('.server-file:visible').count(),3);
  // An unresolved linked request is checking, never ready.
  jobs=jobs.filter(j=>j.id!=='job-0');await p.evaluate(()=>loadDownloads());
  assert.equal(await cards.nth(0).locator('.card-download-status').innerText(),'Finding a source');
  // A previous verified copy remains available even when the latest attempt failed.
  jobs.push({...item(8,'indexed'),id:'older-indexed'});await p.evaluate(()=>loadDownloads());
  assert.equal(await cards.nth(8).locator('.server-file:visible').count(),1);
  // Error must clear the ready claim, links and ready count until a successful read.
  fail=true;await p.evaluate(()=>loadDownloads());
  assert.equal(await cards.locator('.server-file:visible').count(),0);
  assert((await cards.locator('.card-download-status').allTextContents()).every(s=>s==='Status unavailable'));
  assert(!(await p.locator('#finalized-status').innerText()).includes('ready on server'));
  fail=false;jobs=states.map((_,i)=>item(i,'indexed'));
  await cards.nth(0).getByRole('button',{name:'Check status',exact:true}).click();
  await p.waitForFunction(()=>document.querySelectorAll('#finalized-movies .server-file:not([hidden])').length===10);
  assert.equal(await p.locator('#finalize').innerText(),'All ready ✓');
  assert.match(await p.locator('#finalized-status').innerText(),/10 of 10 ready on server/);
  await p.reload({waitUntil:'networkidle'});await p.waitForFunction(()=>document.querySelectorAll('#finalized-movies .server-file:not([hidden])').length===10);
  const layout=await p.evaluate(()=>({overflow:document.documentElement.scrollWidth>innerWidth,smallControls:[...document.querySelectorAll('button,.server-file')].filter(x=>x.getClientRects().length&&x.getBoundingClientRect().height<40).length}));
  assert(!layout.overflow);assert.equal(layout.smallControls,0);assert.deepEqual(errors,[]);assert.deepEqual(writes,[]);
  await p.locator('#finalized').scrollIntoViewIfNeeded();await p.screenshot({path:path.join(out,'cards-'+width+'.png')});
  results.push({width,...layout,ready:10,errors,writes});await p.close();
 }}finally{await browser.close();}
 fs.writeFileSync(path.join(out,'results.json'),JSON.stringify({passed:true,results},null,2));
 fs.writeFileSync(path.join(out,'tested-source.json'),JSON.stringify(Object.fromEntries(['screen.js','screen.css','screen.html'].map(n=>[n,crypto.createHash('sha256').update(fs.readFileSync(path.join(root,'src',n))).digest('hex')])),null,2));
 console.log('CARD_STATUS_BROWSER_PASS_360_412_1280_NO_WRITES');
})().catch(e=>{console.error(e);process.exitCode=1;});
