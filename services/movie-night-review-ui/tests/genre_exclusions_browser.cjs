// Filtered saved picks are history notes; eligible picks and completed files survive.
const {chromium}=require(process.env.AFZ_PLAYWRIGHT||'/home/coolyo/afz-grocery-browser-test-tools/node_modules/playwright');
const fs=require('fs'),path=require('path'),assert=require('node:assert/strict'),crypto=require('crypto');
const root=path.resolve(__dirname,'..'),out=path.join(root,'qa/genre-exclusions');fs.mkdirSync(out,{recursive:true});
(async()=>{
 const browser=await chromium.launch({headless:true,executablePath:process.env.AFZ_CHROME||'/home/coolyo/afz-grocery-browser-test-tools/browsers/chromium_headless_shell-1248/chrome-headless-shell-linux64/chrome-headless-shell',args:['--no-sandbox','--disable-dev-shm-usage','--disable-gpu']});
 const results=[];
 try{for(const width of [360,412,1280]){
  const movies=Array.from({length:6},(_,i)=>({id:'tt'+(22345+i),name:'Fixture '+i,genres:[i===4?'Drama':i===5?'Animation':'Thriller'],releaseInfo:'2024',synopsis:'Fixture synopsis.'}));
  const ids=movies.map(m=>m.id),eligible=ids.slice(0,4),excluded=ids.slice(4);
  const data={movies:movies.slice(0,4),reviewEnabled:true,actionsEnabled:true,autoDownloads:true,downloadRequestedIds:ids,eligibleIds:eligible,seenStateComplete:true,shortlistFresh:true,excludedGenres:['Animation','Drama','Comedy'],selectionLimits:{min:3,max:10,visible:10},finalized:{ids,valid:false,reason:'genre-filter',excludedIds:excluded,movies}};
  const jobs=movies.map((m,i)=>({id:'job-'+i,imdb:m.id,name:m.name,state:'indexed',size:6000000000,bytesReceived:6000000000,downloaded:true,indexed:true}));
  const p=await browser.newPage({viewport:{width,height:860}}),errors=[],writes=[];
  p.on('pageerror',e=>errors.push(e.message));
  await p.route('**/*',async route=>{
   if(!['GET','HEAD'].includes(route.request().method())){writes.push(route.request().method());return route.abort();}
   const u=new URL(route.request().url());let body='',type='text/plain',status=200;
   if(u.pathname.endsWith('/api/shortlist')){body=JSON.stringify(data);type='application/json';}
   else if(u.pathname.endsWith('/api/downloads')){body=JSON.stringify({requests:[],jobs});type='application/json';}
   else if(u.pathname.endsWith('/screen.js')){body=fs.readFileSync(path.join(root,'src/screen.js'),'utf8');type='application/javascript';}
   else if(u.pathname.endsWith('/screen.css')){body=fs.readFileSync(path.join(root,'src/screen.css'),'utf8');type='text/css';}
   else if(u.pathname==='/movie-night/'){body=fs.readFileSync(path.join(root,'src/screen.html'),'utf8').replaceAll('__BASE__','/movie-night').replaceAll('__CSRF__','fixture').replaceAll('__MIN_PICKS__','3').replaceAll('__MAX_PICKS__','10');type='text/html';}
   else status=204;
   await route.fulfill({status,contentType:type,body});
  });
  await p.goto('http://localhost/movie-night/',{waitUntil:'networkidle'});
  await p.waitForFunction(()=>document.querySelectorAll('#download-list a').length===6);
  assert.deepEqual(await p.locator('.chips li').allTextContents(),['2016 onward','No Animation','No Drama','No Comedy']);
  assert.equal(await p.locator('#movies .movie-card').count(),4);
  assert.equal(await p.locator('#finalized-movies .movie-card').count(),4);
  assert.equal(await p.locator('.genre-excluded').count(),2);
  for(const id of excluded)assert.equal(await p.locator('.movie-card[data-movie="'+id+'"]').count(),0);
  assert.equal(await p.locator('#movies .pick-toggle[aria-pressed="true"]').count(),4);
  assert.equal(await p.locator('#finalized-movies .server-file:visible').count(),4);
  assert.match(await p.locator('#finalized-status').innerText(),/Animation, Drama and Comedy filters/);
  assert.equal(await p.locator('#finalize').innerText(),'Finalize & download 4');
  assert.equal(await p.locator('#finalize').isDisabled(),false);
  const overflow=await p.evaluate(()=>document.documentElement.scrollWidth>innerWidth);assert(!overflow);
  assert.deepEqual(errors,[]);assert.deepEqual(writes,[]);
  await p.locator('#finalized').scrollIntoViewIfNeeded();await p.screenshot({path:path.join(out,'filters-'+width+'.png')});
  results.push({width,eligible:4,excludedNotes:2,readyFiles:6,overflow,errors,writes});await p.close();
 }}finally{await browser.close();}
 fs.writeFileSync(path.join(out,'results.json'),JSON.stringify({passed:true,results},null,2));
 fs.writeFileSync(path.join(out,'tested-source.json'),JSON.stringify(Object.fromEntries(['screen.js','screen.html','screen.css'].map(n=>[n,crypto.createHash('sha256').update(fs.readFileSync(path.join(root,'src',n))).digest('hex')]))));
 console.log('GENRE_EXCLUSIONS_BROWSER_PASS_360_412_1280_NO_WRITES');
})().catch(e=>{console.error(e);process.exitCode=1;});
