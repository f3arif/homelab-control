// Read-only acceptance through actual HTTPS/Serve identity. Never clicks choices.
const puppeteer=require('/home/coolyo/afz-website-review-tools-20261010/node_modules/puppeteer');
const assert=require('node:assert/strict'), fs=require('fs');
(async()=>{
 const origin='https://hpenvy.tailc9bb62.ts.net:8453', out=process.env.AFZ_ACCESS_LIVE_OUTPUT;
 assert(out);fs.mkdirSync(out,{recursive:true});
 const browser=await puppeteer.launch({headless:true,executablePath:'/home/coolyo/afz-website-review-tools-20261010/browser-with-zip/chrome/linux-155.0.8059.39/chrome-linux64/chrome',args:['--no-sandbox','--disable-dev-shm-usage','--host-resolver-rules=MAP hpenvy.tailc9bb62.ts.net 100.71.26.69']});
 const results=[];
 try{
  for(const width of [360,412,1280]){
   const p=await browser.newPage();await p.setViewport({width,height:860});
   const errors=[], failed=[];p.on('pageerror',e=>errors.push(e.message));
   p.on('requestfailed',r=>failed.push({path:new URL(r.url()).pathname,type:r.resourceType(),error:r.failure()?.errorText}));
   const response=await p.goto(origin+'/movie-night/',{waitUntil:'networkidle0',timeout:45000});
   assert.equal(response.status(),200);await p.waitForSelector('#movies .movie-card',{timeout:15000});
   const state=await p.evaluate(()=>({background:getComputedStyle(document.documentElement).backgroundColor,overflow:document.documentElement.scrollWidth>innerWidth,cards:document.querySelectorAll('#movies .movie-card').length,smallButtons:[...document.querySelectorAll('button')].filter(b=>b.getClientRects().length&&b.getBoundingClientRect().height<40).length,hasBillingForm:!!document.querySelector('input[type=password]')}));
   assert.equal(state.background,'rgb(11, 18, 32)');assert(!state.overflow);assert.equal(state.cards,10);assert.equal(state.smallButtons,0);assert(!state.hasBillingForm);assert.deepEqual(errors,[]);
   assert(!failed.some(x=>['script','stylesheet','fetch'].includes(x.type)));
   await p.screenshot({path:out+'/live-'+width+'.png',fullPage:true});
   results.push({width,status:response.status(),...state,errors,failed});await p.close();
  }
  fs.writeFileSync(out+'/live-browser-results.json',JSON.stringify({passed:true,results},null,2));
  console.log('LIVE_HTTPS_IDENTITY_MOBILE_DESKTOP_PASS');
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
