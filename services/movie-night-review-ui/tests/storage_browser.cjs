const {chromium}=require(process.env.AFZ_PLAYWRIGHT||'/home/coolyo/afz-grocery-browser-test-tools/node_modules/playwright');
const fs=require('fs'),assert=require('node:assert/strict');
(async()=>{
 const origin=process.env.AFZ_GATEWAY_QA_ORIGIN,results=[];
 const browser=await chromium.launch({headless:true,timeout:60000,executablePath:process.env.AFZ_CHROME||'/home/coolyo/afz-grocery-browser-test-tools/browsers/chromium_headless_shell-1248/chrome-headless-shell-linux64/chrome-headless-shell',args:['--no-sandbox','--disable-dev-shm-usage','--disable-gpu']});
 try{
  for(const width of [360,412,1280]){
   const p=await browser.newPage();await p.setViewportSize({width,height:860});
   await p.emulateMedia({reducedMotion:'reduce'});
   await p.setExtraHTTPHeaders({'Tailscale-User-Login':'owner@example.test'});
   const errors=[],writes=[];p.on('pageerror',e=>errors.push(e.message));
   p.on('request',r=>{if(r.method()==='POST')writes.push(r.url());});
   await p.goto(origin+'/movie-night/',{waitUntil:'networkidle'});
   await p.waitForSelector('#movies .movie-card');
   if(width===360){
    assert.equal(await p.$eval('#download-list',x=>x.querySelectorAll('article').length),0);
    await p.$$eval('#movies .pick-toggle',buttons=>buttons.slice(0,5).forEach(b=>b.click()));
    assert.equal(await p.$eval('#finalize',b=>b.textContent),'Finalize & download 5');
    await p.$$eval('#movies .pick-toggle',buttons=>buttons.slice(5).forEach(b=>b.click()));
    assert.equal(await p.$eval('#finalize',b=>b.textContent),'Finalize & download 10');
    const [finalizeResponse]=await Promise.all([p.waitForResponse(r=>r.url().endsWith('/api/finalize')&&r.request().method()==='POST'),p.click('#finalize')]);
    assert.equal(finalizeResponse.status(),200,await finalizeResponse.text());
    try{await p.waitForSelector('#download-list [data-state="indexed"]',{timeout:25000});}catch(e){console.error('FIXTURE_PAGE',await p.$eval('body',x=>x.innerText));throw e;}
    await p.waitForFunction(()=>document.querySelectorAll('#download-list [data-state="unavailable"]').length===9);
    assert(!await p.$eval('#confirmation',d=>d.open));
    assert(!writes.some(x=>/\/(approve|propose)$/.test(x)));
    assert.equal(await p.$eval('#download-list',x=>x.querySelectorAll('article').length),10);
    assert.equal(await p.$eval('#download-list article',x=>x.dataset.state),'indexed');
    const file=await p.$eval('#download-list a',async a=>{const r=await fetch(a.href,{headers:{Range:'bytes=0-31'}});return {status:r.status,bytes:(await r.arrayBuffer()).byteLength};});
    assert.deepEqual(file,{status:206,bytes:32});
    await p.click('#download-list [data-state="unavailable"] button');
    await p.waitForFunction(()=>document.querySelectorAll('#download-list [data-state="unavailable"]').length===9);
    await p.reload({waitUntil:'networkidle'});await p.waitForSelector('#download-list [data-state="indexed"]');
   }
   await p.waitForSelector('#download-list [data-state="indexed"]');
   const state=await p.evaluate(()=>({overflow:document.documentElement.scrollWidth>innerWidth,cards:document.querySelectorAll('#movies .movie-card').length,
    jobs:document.querySelectorAll('#download-list article').length,button:document.querySelector('#finalize').textContent,buttonDisabled:document.querySelector('#finalize').disabled,
    smallButtons:[...document.querySelectorAll('button')].filter(b=>b.getClientRects().length&&b.getBoundingClientRect().height<40).map(b=>b.textContent)}));
   assert(!state.overflow);assert.equal(state.cards,10);assert.equal(state.jobs,10);assert.equal(state.button,'Downloads requested ✓');assert(state.buttonDisabled);
   assert.deepEqual(state.smallButtons,[]);assert.deepEqual(errors,[]);
   await p.screenshot({path:process.env.AFZ_GATEWAY_QA_OUTPUT+'/auto-'+width+'.png',fullPage:true});if(width===360){await p.screenshot({path:process.env.AFZ_GATEWAY_QA_OUTPUT+'/auto-phone-top.png'});await p.$eval('#downloads',x=>x.scrollIntoView());await p.screenshot({path:process.env.AFZ_GATEWAY_QA_OUTPUT+'/auto-phone-downloads.png'});}
   results.push({width,...state,errors});await p.close();
  }
  fs.writeFileSync(process.env.AFZ_GATEWAY_QA_OUTPUT+'/browser-results.json',JSON.stringify({passed:true,results},null,2));
  console.log('AUTO_DOWNLOAD_BROWSER_PASS');
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
