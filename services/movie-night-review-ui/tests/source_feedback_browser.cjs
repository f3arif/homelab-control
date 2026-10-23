const http=require('http'),fs=require('fs'),path=require('path'),assert=require('node:assert/strict');
const puppeteer=require('/home/coolyo/afz-website-review-tools-20261010/node_modules/puppeteer');
const root=path.resolve(__dirname,'..'),out=path.join(root,'qa/source-feedback');
fs.mkdirSync(out,{recursive:true});
const movies=[1,2,3].map((n)=>({id:'tt'+(12344+n),name:'Fixture '+n,releaseInfo:'2024',genres:['Thriller'],movieInfo:{runtimeMinutes:98,summary:'Disposable source-review fixture.'}}));
const data={movies,eligibleIds:movies.map(m=>m.id),reviewEnabled:true,actionsEnabled:true,shortlistFresh:true,seenStateComplete:true,selectionLimits:{min:3,max:10,visible:10},finalized:{ids:movies.map(m=>m.id),valid:true,movies},refillRequest:{},reserveCount:0,disliked:[],seen:[]};
const plan=(title='Fixture 1')=>({confirmationId:'fixture-confirmation',binding:'fixture-binding',expiresEpoch:Math.floor(Date.now()/1000)+900,freeBytes:200e9,reserveBytes:50e9,quotaRemainingBytes:100e9,choice:{title,year:2024,edition:'Theatrical',provider:'Fixture',torrent_id:12,file_id:3,provider_name:'Fixture.2024.1080p.x264.mkv',quality:'1080p',codec:'AVC',size:4e9,destination:'/fixture/Movies/fixture.mkv'}});
let mode='missing',held=[],proposals=0,lookups=0,approvals=0;
const send=(res,status,body)=>{res.writeHead(status,{'Content-Type':'application/json','Cache-Control':'no-store'});res.end(JSON.stringify(body));};
const server=http.createServer((req,res)=>{
 const url=new URL(req.url,'http://localhost'),route=url.pathname;
 if(req.method==='POST'&&route.endsWith('/api/approve')){approvals++;send(res,403,{detail:'No transfers permitted in source-feedback tests'});return;}
 if(req.method==='POST'&&route.endsWith('/api/propose')){
  proposals++;req.resume();
  if(mode==='hold'){held.push(res);return;}
  if(mode==='unavailable'){send(res,503,{detail:'Fixture provider unavailable'});return;}
  if(mode==='refresh'){send(res,403,{detail:'Confirmation session mismatch'});return;}
  if(mode==='success'){send(res,200,plan());return;}
  send(res,200,{lookupId:'fixture-lookup',state:'checking-sources'});return;
 }
 if(route.includes('/api/lookup/')){lookups++;if(mode==='timeout')send(res,200,{lookupId:'fixture-lookup'});else send(res,409,{detail:'No matching compact source'});return;}
 if(route.endsWith('/api/shortlist')){send(res,200,data);return;}
 if(route.endsWith('/api/downloads')){send(res,200,{jobs:[]});return;}
 if(route==='/movie-night/'||route==='/movie-night'){
  let html=fs.readFileSync(path.join(root,'src/screen.html'),'utf8').replaceAll('__BASE__','/movie-night').replaceAll('__CSRF__','fixture-token').replaceAll('__MIN_PICKS__','3').replaceAll('__MAX_PICKS__','10');
  res.writeHead(200,{'Content-Type':'text/html'});res.end(html);return;
 }
 const name=route.endsWith('/screen.js')?'screen.js':route.endsWith('/screen.css')?'screen.css':null;
 if(name){res.writeHead(200,{'Content-Type':name.endsWith('.js')?'application/javascript':'text/css'});res.end(fs.readFileSync(path.join(root,'src',name)));return;}
 res.writeHead(404);res.end();
});
const until=async check=>{const deadline=Date.now()+5000;while(!check()){if(Date.now()>deadline)throw Error('Fixture request not received');await new Promise(r=>setTimeout(r,10));}};
(async()=>{
 await new Promise(r=>server.listen(0,'127.0.0.1',r));
 const origin='http://127.0.0.1:'+server.address().port;
 const browser=await puppeteer.launch({headless:true,executablePath:'/home/coolyo/afz-website-review-tools-20261010/browser-with-zip/chrome/linux-155.0.8059.39/chrome-linux64/chrome',args:['--no-sandbox','--disable-dev-shm-usage']});
 const results=[];
 try{
  for(const width of [360,412,1280]){
   const p=await browser.newPage(),errors=[];p.on('pageerror',e=>errors.push(e.message));
   await p.setViewport({width,height:860});await p.emulateMediaFeatures([{name:'prefers-reduced-motion',value:'reduce'}]);
   await p.goto(origin+'/movie-night/',{waitUntil:'networkidle0'});await p.waitForSelector('#finalized-movies .buttons button');
   // A pending network response must still show immediate feedback at the clicked card.
   mode='hold';const prior=proposals;
   await p.click('#finalized-movies .buttons button');await until(()=>held.length===1);
   await p.waitForFunction(()=>document.querySelector('#confirmation').open&&document.querySelector('#confirmation').dataset.state==='loading');
   assert.equal(await p.$eval('#confirm-yes',b=>b.hidden),true);
   assert.equal(await p.$eval('#reply',b=>b.value),'');
   assert((await p.$eval('#source-status',n=>n.textContent)).includes('No download has started'));
   await p.evaluate(()=>propose('tt12345','Fixture 1'));assert.equal(proposals,prior+1);
   await p.screenshot({path:out+'/loading-'+width+'.png'});
   mode='missing';send(held.shift(),200,{lookupId:'fixture-lookup'});
   await p.waitForFunction(()=>document.querySelector('#confirmation').dataset.state==='error');
   const error=await p.$eval('#confirm-error',n=>({text:n.textContent,top:n.getBoundingClientRect().top,bottom:n.getBoundingClientRect().bottom}));
   assert(error.text.includes('TorBox library'));assert(error.top>=0&&error.bottom<=860);
   assert.equal(await p.$eval('#confirm-yes',b=>b.hidden),true);
   await p.screenshot({path:out+'/missing-'+width+'.png'});
   // Retry replaces the error with the exact-file confirmation; it does not approve.
   mode='success';await p.click('#retry-source');
   await p.waitForFunction(()=>document.querySelector('#confirmation').dataset.state==='ready');
   assert((await p.$eval('#facts',n=>n.textContent)).includes('4,000,000,000 bytes'));
   assert.equal(await p.$eval('#confirm-yes',b=>b.hidden),false);assert.equal(approvals,0);
   await p.click('#back');await p.waitForFunction(()=>!document.querySelector('#confirmation').open);
   // Closing during a request prevents its late response from reopening a dialog.
   mode='hold';const beforeLookups=lookups;await p.click('#finalized-movies .buttons button');await until(()=>held.length===1);
   await p.click('#back');send(held.shift(),200,plan('Late fixture'));
   await p.waitForFunction(()=>!sourceBusy);
   assert.equal(await p.$eval('#confirmation',d=>d.open),false);
   assert.equal(await p.evaluate(()=>pending),null);assert.equal(lookups,beforeLookups);
   // A new request must not be overwritten by a previous closed request.
   mode='hold';await p.click('#finalized-movies .buttons button');await until(()=>held.length===1);
   const old=held.shift();await p.click('#back');
   await p.click('#finalized-movies .buttons button');await until(()=>held.length===1);
   send(old,200,plan('Stale fixture'));send(held.shift(),200,plan('Current fixture'));
   await p.waitForFunction(()=>document.querySelector('#confirmation').dataset.state==='ready');
   assert((await p.$eval('#facts',n=>n.textContent)).includes('Current fixture'));
   assert(!(await p.$eval('#facts',n=>n.textContent)).includes('Stale fixture'));
   await p.click('#back');
   mode='unavailable';await p.click('#finalized-movies .buttons button');
   await p.waitForFunction(()=>document.querySelector('#confirmation').dataset.state==='error');
   assert((await p.$eval('#confirm-error',n=>n.textContent)).includes('temporarily unavailable'));
   assert.equal(await p.$eval('#retry-source',b=>b.hidden),false);await p.click('#back');
   mode='refresh';await p.click('#finalized-movies .buttons button');
   await p.waitForFunction(()=>document.querySelector('#confirmation').dataset.state==='error');
   assert.equal(await p.$eval('#source-reload',a=>a.hidden),false);assert.equal(await p.$eval('#retry-source',b=>b.hidden),true);
   assert((await p.$eval('#source-reload',a=>a.href)).endsWith('/movie-night/'));
   await p.keyboard.press('Escape');await p.waitForFunction(()=>!document.querySelector('#confirmation').open);
   mode='hold';await p.click('#finalized-movies .buttons button');await until(()=>held.length===1);
   await p.evaluate(()=>{window.originalPerformanceNow=performance.now.bind(performance);Object.defineProperty(performance,'now',{configurable:true,value:()=>window.originalPerformanceNow()+70000});});
   mode='timeout';send(held.shift(),200,{lookupId:'fixture-lookup'});
   await p.waitForFunction(()=>document.querySelector('#confirmation').dataset.state==='error');
   assert((await p.$eval('#confirm-error',n=>n.textContent)).includes('took too long'));
   const layout=await p.evaluate(()=>({overflow:document.documentElement.scrollWidth>innerWidth,dialogOverflow:document.querySelector('#confirmation').scrollWidth>document.querySelector('#confirmation').clientWidth,smallButtons:[...document.querySelectorAll('#confirmation button,#confirmation a')].filter(b=>b.getClientRects().length&&b.getBoundingClientRect().height<40).length}));
   assert(!layout.overflow);assert(!layout.dialogOverflow);assert.equal(layout.smallButtons,0);
   assert.deepEqual(errors,[]);results.push({width,passed:true,...layout,errors});await p.close();
  }
  assert.equal(approvals,0);
  const result={passed:true,results,scenarios:['immediate-loading','no-match-visible','retry-ready','close-late-response','stale-request-isolation','provider-failure','refresh-required','escape','bounded-timeout'],approvals};
  fs.writeFileSync(out+'/browser-results.json',JSON.stringify(result,null,2));fs.writeFileSync(out+'/tested-source.json',JSON.stringify(Object.fromEntries(['screen.js','screen.html','screen.css'].map(name=>[name,require('crypto').createHash('sha256').update(fs.readFileSync(path.join(root,'src',name))).digest('hex')]))));console.log('SOURCE_FEEDBACK_BROWSER_PASS_360_412_1280_NO_APPROVALS');
 }finally{for(const r of held)send(r,503,{detail:'Fixture closing'});await browser.close();await new Promise(r=>server.close(r));}
})().catch(e=>{console.error(e);process.exitCode=1;server.close();});
