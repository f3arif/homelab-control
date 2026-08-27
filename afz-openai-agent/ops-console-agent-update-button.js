/* AFZ Ops Console -> OpenAI Agent immediate updater
 * Include this script in the HP Ops Console page.
 * Uses the Windows-main Tailscale control endpoint; no OneDrive/SharePoint.
 */
(function(){
  'use strict';
  if(window.AFZAgentUpdateButtonInstalled)return;
  window.AFZAgentUpdateButtonInstalled=true;
  const CONTROL='http://100.70.25.8:8797';
  const AGENT='http://100.70.25.8:8796';

  function notify(msg,ok=true){
    try{if(typeof toast==='function'){toast(msg,ok);return}}catch{}
    console[ok?'log':'error']('[AFZ Agent Update]',msg);
  }
  async function agentHealth(){
    const r=await fetch(AGENT+'/health',{cache:'no-store'});
    if(!r.ok)throw new Error('agent health '+r.status);
    return r.json();
  }
  async function waitForAgent(maxMs=45000){
    const end=Date.now()+maxMs;
    let sawDown=false;
    while(Date.now()<end){
      try{
        const h=await agentHealth();
        if(sawDown||Date.now()>end-maxMs+2500)return h;
      }catch{ sawDown=true }
      await new Promise(r=>setTimeout(r,1500));
    }
    throw new Error('Agent did not return within 45 seconds');
  }
  async function updateNow(btn){
    if(btn){btn.disabled=true;btn.dataset.oldText=btn.textContent;btn.textContent='Updating agent…'}
    try{
      const r=await fetch(CONTROL+'/api/update-now',{method:'POST',headers:{'Content-Type':'application/json'},body:'{}'});
      const j=await r.json().catch(()=>({}));
      if(!r.ok)throw new Error(j.error||('update request '+r.status));
      notify('AFZ agent update started');
      const h=await waitForAgent();
      notify('AFZ agent updated and online'+(h.version?' · '+h.version:''));
      try{if(typeof load==='function')setTimeout(load,500)}catch{}
    }catch(e){
      notify('AFZ agent update failed: '+e.message,false);
    }finally{
      if(btn){btn.disabled=false;btn.textContent=btn.dataset.oldText||'Update Agent Now'}
    }
  }
  function install(){
    if(document.querySelector('[data-afz-agent-update-now]'))return;
    const host=document.getElementById('afzSmartOpsBar')||document.getElementById('request-console')||document.querySelector('.section');
    if(!host)return;
    const row=document.createElement('div');
    row.className='smartOpsRow afzAgentUpdateRow';
    row.style.marginTop='8px';
    const label=document.createElement('span');
    label.className='smartOpsLabel';
    label.textContent='Agent control';
    const btn=document.createElement('button');
    btn.type='button';
    btn.className='btn primary';
    btn.dataset.afzAgentUpdateNow='1';
    btn.textContent='Update Agent Now';
    btn.title='Pull homelab-control/main now, apply Tailscale access policy, and restart the AFZ OpenAI Agent only if required';
    btn.onclick=()=>updateNow(btn);
    row.append(label,btn);
    host.appendChild(row);
  }
  install();
  setInterval(install,5000);
})();
