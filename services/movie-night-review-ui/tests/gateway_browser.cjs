const puppeteer=require('/home/coolyo/afz-website-review-tools-20261010/node_modules/puppeteer');
const fs=require('fs'),assert=require('node:assert/strict');
(async()=>{
 const origin=process.env.AFZ_GATEWAY_QA_ORIGIN,results=[];
 const browser=await puppeteer.launch({headless:true,executablePath:'/home/coolyo/afz-website-review-tools-20261010/browser-with-zip/chrome/linux-155.0.8059.39/chrome-linux64/chrome',args:['--no-sandbox','--disable-dev-shm-usage']});
 try{
  for(const width of [360,412,1280]){
   const p=await browser.newPage();await p.setViewport({width,height:860});
   await p.setCookie({name:'afz_owner',value:process.env.AFZ_GATEWAY_QA_COOKIE,url:origin,httpOnly:true,sameSite:'Strict'});
   const errors=[];p.on('pageerror',e=>errors.push(e.message));
   await p.goto(origin+'/movie-night',{waitUntil:'networkidle0',timeout:40000});
   await p.waitForSelector('#movies .movie-card',{timeout:15000});
   if(width===360){
    await p.$$eval('#movies .pick-toggle',buttons=>buttons.forEach(b=>b.click()));
    await p.click('#finalize');
    await p.waitForFunction(()=>!document.querySelector('#finalized').hidden);
    await p.click('#finalized-movies .buttons button');
    await p.waitForFunction(()=>document.querySelector('#confirmation').open);
    const facts=await p.$eval('#facts',el=>el.textContent);
    assert(facts.includes('Fixture One'));assert(facts.includes('1080p / AVC'));assert(facts.includes('/home/coolyo/afz-curated-media/Movies/'));
    await p.type('#reply','yes');await p.click('#confirm-yes');
    await p.waitForFunction(()=>document.querySelector('#download-list').textContent.includes('indexed'),{timeout:20000});
    const downloaded=await p.$eval('#download-list a',async a=>{const r=await fetch(a.href, {headers:{Range:'bytes=0-31'}});return {status:r.status,bytes:(await r.arrayBuffer()).byteLength};});
    assert.equal(downloaded.status,206);assert.equal(downloaded.bytes,32);
    await p.reload({waitUntil:'networkidle0'});
    await p.waitForFunction(()=>document.querySelector('#download-list').textContent.includes('indexed'));
   }
   const state=await p.evaluate(()=>({background:getComputedStyle(document.documentElement).backgroundColor,overflow:document.documentElement.scrollWidth>innerWidth,cards:document.querySelectorAll('#movies .movie-card').length,selectionVisible:!document.querySelector('#selection').hidden,
    finalizedVisible:!document.querySelector('#finalized').hidden,jobRestored:document.querySelector('#download-list').textContent.includes('indexed'),
    smallButtons:[...document.querySelectorAll('button')].filter(b=>b.getClientRects().length&&b.getBoundingClientRect().height<40).map(b=>b.textContent)}));
   assert.equal(state.background,'rgb(11, 18, 32)');assert(!state.overflow);assert(state.cards>0);assert(state.selectionVisible);assert(state.finalizedVisible);assert(state.jobRestored);
   assert.deepEqual(state.smallButtons,[]);assert.deepEqual(errors,[]);
   await p.screenshot({path:process.env.AFZ_GATEWAY_QA_OUTPUT+'/download-'+width+'.png',fullPage:true});
   results.push({width,...state,errors});await p.close();
  }
  fs.writeFileSync(process.env.AFZ_GATEWAY_QA_OUTPUT+'/browser-results.json',JSON.stringify({passed:true,results},null,2));
  console.log('DISPOSABLE_GATEWAY_BROWSER_DOWNLOAD_PASS');
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
