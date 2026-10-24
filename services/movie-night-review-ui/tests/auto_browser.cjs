const puppeteer=require('/home/coolyo/afz-website-review-tools-20261010/node_modules/puppeteer');
const fs=require('fs'),assert=require('node:assert/strict');
(async()=>{
 const origin=process.env.AFZ_GATEWAY_QA_ORIGIN,results=[];
 const browser=await puppeteer.launch({headless:true,executablePath:'/home/coolyo/afz-website-review-tools-20261010/browser-with-zip/chrome/linux-155.0.8059.39/chrome-linux64/chrome',args:['--no-sandbox','--disable-dev-shm-usage']});
 try{
  for(const width of [360,412,1280]){
   const p=await browser.newPage();await p.setViewport({width,height:860});
   await p.emulateMediaFeatures([{name:'prefers-reduced-motion',value:'reduce'}]);
   await p.setExtraHTTPHeaders({'Tailscale-User-Login':'owner@example.test'});
   const errors=[],writes=[];p.on('pageerror',e=>errors.push(e.message));
   p.on('request',r=>{if(r.method()==='POST')writes.push(r.url());});
   await p.goto(origin+'/movie-night/',{waitUntil:'networkidle0'});
   await p.waitForSelector('#movies .movie-card');
   if(width===360){
    assert.equal(await p.$eval('#download-list',x=>x.querySelectorAll('article').length),0);
    await p.$$eval('#movies .pick-toggle',buttons=>buttons.slice(0,5).forEach(b=>b.click()));
    assert.equal(await p.$eval('#finalize',b=>b.textContent),'Finalize & download 5');
    await p.$$eval('#movies .pick-toggle',buttons=>buttons.slice(5).forEach(b=>b.click()));
    assert.equal(await p.$eval('#finalize',b=>b.textContent),'Finalize & download 10');
    await p.click('#finalize');
    await p.waitForSelector('#download-list [data-state="indexed"]',{timeout:25000});
    await p.waitForFunction(()=>document.querySelectorAll('#download-list [data-state="unavailable"]').length===9);
    assert(!await p.$eval('#confirmation',d=>d.open));
    assert(!writes.some(x=>/\/(approve|propose)$/.test(x)));
    assert.equal(await p.$eval('#download-list',x=>x.querySelectorAll('article').length),10);
    const file=await p.$eval('#download-list a',async a=>{const r=await fetch(a.href,{headers:{Range:'bytes=0-31'}});return {status:r.status,bytes:(await r.arrayBuffer()).byteLength};});
    assert.deepEqual(file,{status:206,bytes:32});
    await p.click('#download-list [data-state="unavailable"] button');
    await p.waitForFunction(()=>document.querySelectorAll('#download-list [data-state="unavailable"]').length===9);
    await p.reload({waitUntil:'networkidle0'});await p.waitForSelector('#download-list [data-state="indexed"]');
   }
   await p.waitForSelector('#download-list [data-state="indexed"]');
   const state=await p.evaluate(()=>({overflow:document.documentElement.scrollWidth>innerWidth,cards:document.querySelectorAll('#movies .movie-card').length,
    jobs:document.querySelectorAll('#download-list article').length,button:document.querySelector('#finalize').textContent,buttonDisabled:document.querySelector('#finalize').disabled,
    smallButtons:[...document.querySelectorAll('button')].filter(b=>b.getClientRects().length&&b.getBoundingClientRect().height<40).map(b=>b.textContent)}));
   assert(!state.overflow);assert.equal(state.cards,10);assert.equal(state.jobs,10);assert.equal(state.button,'Downloads requested ✓');assert(state.buttonDisabled);
   assert.deepEqual(state.smallButtons,[]);assert.deepEqual(errors,[]);
   await p.screenshot({path:process.env.AFZ_GATEWAY_QA_OUTPUT+'/auto-'+width+'.png',fullPage:true});results.push({width,...state,errors});await p.close();
  }
  fs.writeFileSync(process.env.AFZ_GATEWAY_QA_OUTPUT+'/browser-results.json',JSON.stringify({passed:true,results},null,2));
  console.log('AUTO_DOWNLOAD_BROWSER_PASS');
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
