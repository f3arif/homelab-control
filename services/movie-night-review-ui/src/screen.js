'use strict';
const base = document.querySelector('meta[name="mn-base"]').content;
const csrf = document.querySelector('meta[name="mn-csrf"]').content;
const minPicks = Number(document.querySelector('meta[name="mn-min-picks"]').content);
const maxPicks = Number(document.querySelector('meta[name="mn-max-picks"]').content);
const $ = id => document.getElementById(id);
let pending = null, job = null, timer = null, loadGeneration = 0;
let autoDownloads=false,downloadRequestedIds=new Set(),downloadGeneration=0;
let downloadDataState='loading',downloadFailures=0;
const downloadItems=new Map(),cardDownloads=new Map();
const downloadLabels={queued:'Queued',checking:'Finding a source',unavailable:'No ready source',failed:'Needs attention',cancelled:'Cancelled',approved:'Queued for transfer',downloading:'Downloading',downloaded:'Downloaded · checking availability',indexed:'Ready on server','playback-tested':'Ready on server'};
let sourceBusy=false,sourceGeneration=0,sourceMovie=null,downloadTimer=null;
let selected=new Set(), initialized=false, reviewBusy=false;let refillTimer=null, recoveryTimer=null, recoveryAttempts=0, uncertainWrite=false;
let toastTimer=null, finalizedIds=[], finalizedValid=false;const titles=new Map(), pickCards=new Map();
const deviceId=crypto.randomUUID();let generation=0, sample=null;
navigator.connection?.addEventListener('change',()=>{generation++;sample=null;$('stream-result').hidden=true;});
async function measure(){
  if(sample && performance.now()-sample.at<180000) return sample;
  const start=performance.now();
  const r=await fetch(base+'/api/probe',{method:'POST',headers:{'Content-Type':'application/json','X-Movie-Night-CSRF':csrf},body:JSON.stringify({deviceId,generation})});
  if(!r.ok){const e=await r.json();throw new Error(e.detail||'Connection check unavailable.');}
  const bytes=await r.arrayBuffer(), seconds=(performance.now()-start)/1000;
  const video=document.createElement('video'),supportedCodecs=[];
  if(video.canPlayType('video/mp4; codecs="avc1.640028"')) supportedCodecs.push('AVC','H.264');
  if(video.canPlayType('video/mp4; codecs="hvc1.1.6.L120.90"')) supportedCodecs.push('HEVC','H.265');
  if(video.canPlayType('video/mp4; codecs="av01.0.08M.08"')) supportedCodecs.push('AV1');
  sample={probeId:r.headers.get('X-Movie-Night-Probe'),deviceId,generation,bytes:bytes.byteLength,seconds,supportedCodecs,at:performance.now()};
  return sample;
}
function requestError(message,kind){const error=new Error(message);error.kind=kind;return error;}
async function api(path, data) {
  const abort=new AbortController();const deadline=setTimeout(()=>abort.abort(),8000);
  try{
    let response;
    try{response=await fetch(base+'/api/'+path,{cache:'no-store',credentials:'same-origin',signal:abort.signal,...(data===undefined?{}:{method:'POST',headers:{'Content-Type':'application/json','X-Movie-Night-CSRF':csrf},body:JSON.stringify(data)})});}
    catch(error){throw requestError(error.name==='AbortError'?'The connection timed out.':'The connection was interrupted.','connection');}
    let body={};
    try{body=JSON.parse(await response.text());}
    catch(error){if(response.status===401||response.redirected)throw requestError('Your sign-in session has expired.','session');throw requestError('The server response was interrupted.','connection');}
    if(response.status===401||body.error==='sign_in_required')throw requestError('Your sign-in session has expired.','session');
    if(response.status===403)throw requestError('This page needs refreshing before another change.','page');
    if(response.status>=500)throw requestError('Movie Night is temporarily unavailable.','connection');
    if(!response.ok)throw requestError(body.detail||'Unable to complete this request.','request');
    return body;
  }finally{clearTimeout(deadline);}
}
function stopRecovery(){if(recoveryTimer)clearTimeout(recoveryTimer);recoveryTimer=null;}
function recoverRead(){
  stopRecovery();const delays=[1000,2000,4000,8000,15000];
  if(recoveryAttempts<delays.length)recoveryTimer=setTimeout(load,delays[recoveryAttempts++]);
}
function showFailure(error,write=false){
  if(refillTimer)clearTimeout(refillTimer);
  if(error.kind==='session'||error.kind==='page'){
    stopRecovery();say(error.message+' Your displayed choices have been kept. ');
    const link=document.createElement('a');link.href=error.kind==='session'?'/login':base;
    link.textContent=error.kind==='session'?'Sign in again':'Reload Movie Night';$('notice').append(link);return;
  }
  if(error.kind==='connection'){
    if(write)uncertainWrite=true;
    say(error.message+(recoveryAttempts>=5?' Automatic retries stopped. Check your connection, then use Retry connection.':uncertainWrite?' Checking saved choices before you repeat the last action.':' Reconnecting to refresh the cards.'));
    const retry=document.createElement('button');retry.className='secondary';retry.textContent='Retry connection';retry.onclick=()=>{recoveryAttempts=0;load();};$('notice').append(retry);
    recoverRead();return;
  }
  say(error.message);
}
// Attention-worthy message (errors, recovery). Replaces any informational list.
function say(message) { const p=document.createElement('p');p.textContent=message;$('notice').replaceChildren(p); }
// Quiet informational notes shown above the cards.
function inform(messages){
  if(!messages.length){$('notice').replaceChildren();return;}
  const list=document.createElement('ul');
  for(const message of messages){const li=document.createElement('li');li.textContent=message;list.append(li);}
  $('notice').replaceChildren(list);
}
function toast(message,actionLabel,action){
  const t=$('toast');if(toastTimer)clearTimeout(toastTimer);
  const text=document.createElement('span');text.textContent=message;t.replaceChildren(text);
  if(actionLabel){const b=document.createElement('button');b.type='button';b.textContent=actionLabel;b.onclick=()=>{hideToast();action();};t.append(b);}
  t.hidden=false;toastTimer=setTimeout(hideToast,actionLabel?9000:4500);
}
function hideToast(){if(toastTimer)clearTimeout(toastTimer);toastTimer=null;$('toast').hidden=true;}
function fact(label, value) {
  const dt=document.createElement('dt'), dd=document.createElement('dd');
  dt.textContent=label; dd.textContent=String(value); $('facts').append(dt,dd);
}
function sourceView(state,title,message=''){
  const dialog=$('confirmation');dialog.dataset.state=state;
  dialog.setAttribute('aria-busy',String(state==='loading'));
  $('confirm-title').textContent=title;
  $('source-status').textContent=message;
  $('confirmation-details').hidden=state!=='ready';
  $('confirm-yes').hidden=state!=='ready';$('confirm-yes').disabled=state!=='ready';
  $('retry-source').hidden=state!=='error';$('source-reload').hidden=true;
  $('confirm-error').textContent='';
  $('back').textContent=state==='ready'?'Not now':'Close';
  dialog.scrollTop=0;if(dialog.open)$('confirm-title').focus({preventScroll:true});
}
function dismissSource(){
  ++sourceGeneration;sourceBusy=false;sourceMovie=null;pending=null;$('confirmation').close();
}
async function propose(imdb,title=titles.get(imdb)||'this movie') {
  if(sourceBusy)return;
  const request=++sourceGeneration;sourceBusy=true;sourceMovie={imdb,title};pending=null;
  $('facts').replaceChildren();$('reply').value='';
  sourceView('loading','Checking server download',`Checking completed TorBox files for ${title}. This may take up to a minute. No download has started.`);
  if(!$('confirmation').open)$('confirmation').showModal();
  $('confirm-title').focus({preventScroll:true});
  const current=()=>request===sourceGeneration&&$('confirmation').open;
  const deadline=performance.now()+60000;
  try {
    let result=await api('propose',{imdb});
    if(!current())return;
    while(result.lookupId){
      if(performance.now()>=deadline)throw requestError('The source check took too long. Try again in a minute. Nothing has been downloaded.','timeout');
      await new Promise(resolve=>setTimeout(resolve,1200));
      if(!current())return;
      result=await api('lookup/'+result.lookupId);
      if(!current())return;
    }
    pending=result;const c=pending.choice;
    $('facts').replaceChildren();
    for(const [name,value] of [['Movie',`${c.title} (${c.year})`],['Edition',c.edition],['Provider',c.provider],
      ['Provider file',`${c.torrent_id} / ${c.file_id}: ${c.provider_name}`],['Quality / codec',`${c.quality} / ${c.codec}`],
      ['Exact size',`${c.size.toLocaleString('en-US')} bytes (${(c.size/1e9).toFixed(2)} GB)`],['Destination',c.destination],
      ['Free storage',`${pending.freeBytes.toLocaleString('en-US')} bytes`],['Required reserve',`${pending.reserveBytes.toLocaleString('en-US')} bytes`],
      ['Remaining transfer budget',`${pending.quotaRemainingBytes.toLocaleString('en-US')} bytes`],['Confirmation expires',new Date(pending.expiresEpoch*1000).toLocaleString()]]) fact(name,value);
    sourceView('ready','Confirm server download','Review this exact file before confirming.');
  } catch(error) {
    if(!current())return;
    pending=null;
    const missing=error.message==='No matching compact source';
    sourceView('error',missing?'No ready file found':'Source check unavailable');
    $('confirm-error').textContent=missing
      ? `No matching completed 1080p file for ${title} is in your TorBox library. This checks files already in your account; it does not add a new movie to TorBox. Nothing was downloaded.`
      : error.message+' Your picks are saved. No download has started.';
    if(error.kind==='session'||error.kind==='page'){
      $('retry-source').hidden=true;$('source-reload').hidden=false;
    }
  } finally {if(request===sourceGeneration)sourceBusy=false;}
}
$('retry-source').onclick=()=>{if(sourceMovie)propose(sourceMovie.imdb,sourceMovie.title);};
$('confirmation').addEventListener('cancel',event=>{event.preventDefault();dismissSource();});
$('confirmation').addEventListener('close',()=>{if(!$('confirmation').open){++sourceGeneration;sourceBusy=false;sourceMovie=null;pending=null;}});

async function poll() {
  if (!job) return;
  try {
    const s=await api('status/'+encodeURIComponent(job));
    $('job-status').textContent=`${s.state} · ${(s.bytesReceived||0).toLocaleString('en-US')} bytes received`;
    $('progress').value=s.bytesReceived||0;
    $('completion').textContent=`Downloaded: ${s.downloaded?'yes':'no'} · Indexed: ${s.indexed?'yes':'no'} · Playback tested: ${s.playbackTested?'yes':'no'}`;
    const cancellable=['approved','downloading'].includes(s.state), active=cancellable||s.processing; $('cancel').disabled=!cancellable;
    if(s.downloaded&&!s.indexed&&!active) say('File downloaded and preserved. Index visibility could not be verified.');
    if(active) timer=setTimeout(poll,1500);
  } catch(error) { say(error.message); }
}
$('confirm-yes').onclick=async()=>{
  if(!pending) return;
  if($('reply').value.trim().toLowerCase()!=='yes'){ $('confirm-error').textContent='Type yes to confirm this exact file.'; return; }
  $('confirm-yes').disabled=true;
  try{
    const result=await api('approve',{confirmationId:pending.confirmationId,binding:pending.binding,reply:$('reply').value});
    job=result.id; $('progress').max=pending.choice.size; $('job').hidden=false; $('confirmation').close(); await poll();await loadDownloads();
  }catch(error){$('confirm-error').textContent=error.message;}finally{$('confirm-yes').disabled=false;}
};
$('back').onclick=dismissSource;
$('cancel').onclick=async()=>{if(job)try{await api('cancel',{confirmationId:job});say('Cancellation requested. Partial files will be preserved.');await poll();}catch(e){say(e.message);}};
function sameAsFinalized(){return finalizedValid&&finalizedIds.length===selected.size&&finalizedIds.every(id=>selected.has(id));}
function selectionCount(){
  const n=selected.size, done=sameAsFinalized()&&(!autoDownloads||[...selected].every(id=>downloadRequestedIds.has(id)));
  const ready=downloadDataState==='current'?[...selected].filter(id=>serverReady(downloadItems.get(id))).length:0;
  const dots=document.createElement('span');dots.className='dots';dots.setAttribute('aria-hidden','true');
  for(let i=0;i<maxPicks;i++){const d=document.createElement('i');if(i<n)d.className='on';dots.append(d);}
  const label=done?(autoDownloads&&ready?`${ready} of ${n} ready`:`${n} picks ${autoDownloads?'sent to downloads':'finalized'}`):n<minPicks?`${n} of ${minPicks}–${maxPicks} picked`:`${n} of ${maxPicks} picked · ready to finalize`;
  $('selection-count').replaceChildren(dots,document.createTextNode(label));
  $('selection-names').textContent=n?[...selected].map(id=>titles.get(id)||'').filter(Boolean).join(' · '):`Use Pick on ${minPicks}–${maxPicks} movies.`;
  $('finalize').textContent=autoDownloads?(done?(n>0&&ready===n?'All ready ✓':'Downloads requested ✓'):`Finalize & download${n>=minPicks?' '+n:''}`):(done?'Finalized ✓':n>=minPicks&&n<=maxPicks?`Finalize ${n} picks`:'Finalize picks');
  $('finalize').disabled=reviewBusy||done||n<minPicks||n>maxPicks;
  for(const [id,ui] of pickCards)paintPick(id,ui);
}
function paintPick(id,ui){
  const on=selected.has(id);ui.card.classList.toggle('is-picked',on);
  ui.button.setAttribute('aria-pressed',String(on));ui.button.replaceChildren(icon(on?'✓':'+'),document.createTextNode(on?'Picked':'Pick'));
  ui.badge.hidden=!on;ui.button.disabled=reviewBusy;
  for(const button of ui.card.querySelectorAll('.card-controls button'))button.disabled=reviewBusy;
}
function icon(symbol){const s=document.createElement('span');s.className='icon';s.setAttribute('aria-hidden','true');s.textContent=symbol;return s;}
async function reviewWrite(path,data){
  if(reviewBusy)return false;
  reviewBusy=true;++loadGeneration;selectionCount();
  try{render(await api(path,data));return true;}
  catch(error){showFailure(error,true);return false;}
  finally{reviewBusy=false;selectionCount();}
}
// Your ranking: order picks (and the Ready on Server catalog) by priority; never starts or deletes downloads.
function rankControls(movie,ids){
  const i=ids.indexOf(movie.id),row=document.createElement('div');row.className='rank-controls';
  const label=document.createElement('span');label.className='rank-badge';label.textContent='#'+(i+1);row.append(label);
  for(const [text,step] of [['↑ Higher',-1],['↓ Lower',1]]){
    const b=document.createElement('button');b.type='button';b.className='secondary';b.textContent=text;
    b.setAttribute('aria-label',`Move ${movie.name} ${step<0?'higher':'lower'} in your ranking`);
    b.disabled=i+step<0||i+step>=ids.length;
    b.onclick=async()=>{const next=[...ids];[next[i],next[i+step]]=[next[i+step],next[i]];if(await reviewWrite('rank',{ids:next}))toast(`${movie.name} is now #${i+step+1}.`);};
    row.append(b);
  }
  return row;
}
function watchButtons(movie,enabled){
  const actions=document.createElement('div');actions.className='buttons';
  if(!enabled){actions.hidden=true;return actions;}
  if(autoDownloads){
    const group=document.createElement('div');group.className='card-download';
    const status=document.createElement('p');status.className='card-download-status';status.setAttribute('role','status');
    const detail=document.createElement('p');detail.className='muted card-download-detail';
    const progress=document.createElement('progress');progress.setAttribute('aria-label',movie.name+' downloaded bytes');
    const save=document.createElement('a');save.className='server-file';save.href=base+'/media/'+encodeURIComponent(movie.id);save.textContent='Save a copy to this device';
    const view=document.createElement('button');view.className='secondary';
    view.onclick=async()=>{
      if(downloadDataState!=='current'){await loadDownloads();return;}
      const target=[...$('download-list').children].find(row=>row.dataset.imdb===movie.id)||$('downloads-title');
      target.setAttribute('tabindex','-1');target.scrollIntoView({block:'center'});target.focus({preventScroll:true});
    };
    actions.append(save,view);group.append(status,detail,progress,actions);
    const ui={group,status,detail,progress,save,view};
    if(!cardDownloads.has(movie.id))cardDownloads.set(movie.id,[]);cardDownloads.get(movie.id).push(ui);
    paintCardDownload(movie.id,ui);return group;
  }
  const download=document.createElement('button');download.textContent='Review server download';
  download.onclick=()=>propose(movie.id,movie.name);
  actions.append(download);return actions;
}
function serverReady(item){return !!(item?.downloaded&&item.indexed);}
function paintCardDownload(id,ui){
  const item=downloadItems.get(id),current=downloadDataState==='current',ready=current&&serverReady(item);
  ui.group.dataset.state=!current?downloadDataState:ready?'ready':item?.state||'not-requested';
  ui.status.textContent=!current?(downloadDataState==='loading'?'Checking server status…':'Status unavailable'):ready?'✓ Ready on server':downloadLabels[item?.state]||'Not requested';
  ui.detail.textContent=!current?(downloadDataState==='loading'?'Checking the 8 TB drive download list.':'Could not refresh download status. Check again or reload Movie Night.'):
    ready?`Verified file on the 8 TB drive${item.size?' · '+(item.size/1e9).toFixed(2)+' GB':''}.`:
    item?.state==='downloading'?`${((item.bytesReceived||0)/1e9).toFixed(2)} of ${(item.size/1e9).toFixed(2)} GB · saving to the 8 TB drive.`:
    item?.state==='downloaded'?'The file is downloaded; server availability is still being checked.':item?.message|| (item?'Saved request. See download details for progress.':'Use Finalize & download to request this movie.');
  ui.progress.hidden=!(current&&item?.state==='downloading'&&item.size>0);
  if(!ui.progress.hidden){ui.progress.max=item.size;ui.progress.value=item.bytesReceived||0;}
  ui.save.hidden=!ready;ui.view.textContent=current?'View download details':'Check status';
}
function updateCardDownloads(){
  for(const [id,uis] of cardDownloads)for(const ui of uis)paintCardDownload(id,ui);
  if(autoDownloads&&finalizedValid){
    const ready=finalizedIds.filter(id=>serverReady(downloadItems.get(id))).length;
    $('finalized-status').textContent=downloadDataState==='current'?`${finalizedIds.length} movies finalized · ${ready} of ${finalizedIds.length} ready on server.`:`${finalizedIds.length} movies finalized. ${downloadDataState==='loading'?'Checking server status…':'Server status could not be refreshed.'}`;
  }
  selectionCount();
}
async function loadDownloads(){
  if(downloadTimer)clearTimeout(downloadTimer);
  const generation=++downloadGeneration;
  try{
    const data=await api('downloads');if(generation!==downloadGeneration)return;
    const panel=$('downloads'),list=$('download-list');list.replaceChildren();panel.hidden=false;
    const requests=data.requests||[],jobs=new Map(data.jobs.map(j=>[j.id,j]));
    const linked=new Set(requests.map(r=>r.jobId).filter(Boolean));
    downloadRequestedIds=new Set(requests.map(r=>r.imdb));
    const items=[...requests.map(r=>({...r,...(jobs.get(r.jobId)||{}),requestId:r.id})),...data.jobs.filter(j=>!linked.has(j.id))];
    for(const item of items)if(item.state==='linked'){item.state='checking';item.message='Refreshing transfer status.';}
    downloadItems.clear();
    // Requests refer to the current attempt; an older verified file remains usable.
    for(const item of items)if(!downloadItems.has(item.imdb)||serverReady(item))downloadItems.set(item.imdb,item);
    downloadDataState='current';downloadFailures=0;updateCardDownloads();
    const priority={downloading:0,approved:1,checking:2,queued:3,indexed:4,'playback-tested':4,downloaded:4,unavailable:6,failed:6,cancelled:7};
    items.sort((a,b)=>(priority[a.state]??5)-(priority[b.state]??5));
    if(!items.length){const p=document.createElement('p');p.textContent=autoDownloads?'No downloads requested yet. Finalize & download sends your selected movies to the 8 TB drive.':'No downloads started. Finalize your picks, then review each server download.';list.append(p);}
    const labels=downloadLabels;
    for(const item of items){
      const row=document.createElement('article');row.className='download-row';row.dataset.imdb=item.imdb;row.dataset.state=item.state;
      const title=document.createElement('h3');title.textContent=item.name;
      const state=document.createElement('p');state.setAttribute('role','status');
      state.textContent=(autoDownloads?(labels[item.state]||item.state):item.state)+(item.size?' · '+((item.bytesReceived||0)/1e9).toFixed(2)+' of '+(item.size/1e9).toFixed(2)+' GB':'');
      row.append(title,state);
      if(item.size){const progress=document.createElement('progress');progress.max=item.size;progress.value=item.bytesReceived||0;progress.setAttribute('aria-label',item.name+' downloaded bytes');row.append(progress);}
      const detail=document.createElement('p');detail.className='muted';
      detail.textContent=item.downloaded?(item.indexed?'Verified file available on the 8 TB drive. Playback has not been tested.':'Verified file preserved on the 8 TB drive; library availability needs checking.'):
        item.jobId||item.size?(['failed','cancelled'].includes(item.state)?'Transfer stopped. Any partial file is preserved; it will not be overwritten.':'Saving to the 8 TB drive. You can close this page and return to check progress.'):
        item.message||'Waiting for the server.';
      row.append(detail);
      if(['queued','checking','approved','downloading'].includes(item.state)){
        const cancel=document.createElement('button');cancel.className='secondary';cancel.textContent='Cancel download';
        cancel.onclick=async()=>{cancel.disabled=true;try{await api('cancel',item.requestId?{requestId:item.requestId}:{confirmationId:item.id});toast('Cancellation requested.');await loadDownloads();}catch(e){showFailure(e);}finally{cancel.disabled=false;}};row.append(cancel);
      }
      if(item.canRetry&&finalizedValid&&finalizedIds.includes(item.imdb)){
        const retry=document.createElement('button');retry.className='secondary';retry.textContent='Retry download';
        retry.onclick=async()=>{retry.disabled=true;if(await reviewWrite('finalize',{ids:finalizedIds,startDownloads:true,requestId:crypto.randomUUID(),retryDownloads:[item.imdb]})){toast('Download requested again.');await loadDownloads();}else retry.disabled=false;};row.append(retry);
      }
      if(item.indexed){const link=document.createElement('a');link.href=base+'/media/'+encodeURIComponent(item.imdb);link.textContent='Save a copy to this device';link.className='secondary';row.append(link);}
      list.append(row);
    }
    if(items.some(x=>['queued','checking','approved','downloading','downloaded'].includes(x.state)))downloadTimer=setTimeout(loadDownloads,3000);
  }catch(error){if(generation===downloadGeneration){
    downloadDataState='unavailable';updateCardDownloads();showFailure(error);
    if(error.kind==='connection'&&downloadFailures<5)downloadTimer=setTimeout(loadDownloads,[3000,6000,12000,20000,30000][downloadFailures++]);
  }}
}
function movieOverview(movie,heading='h2'){
  const overview=document.createElement('div');overview.className='movie-overview';
  const poster=document.createElement('figure');poster.className='movie-poster';
  const missing=document.createElement('span');missing.className='poster-fallback';missing.textContent='Poster unavailable';
  const badge=document.createElement('span');badge.className='pick-badge';badge.textContent='PICK';badge.hidden=true;
  poster.append(missing,badge);
  if(/^tt\d{5,12}$/.test(movie.id||'')){
    const image=document.createElement('img');image.src=base+'/posters/'+movie.id+'.img';
    image.alt=movie.name+' poster';image.width=128;image.height=192;image.loading='lazy';image.decoding='async';image.referrerPolicy='no-referrer';
    image.onload=()=>{missing.hidden=true;};image.onerror=()=>{image.remove();missing.hidden=false;};poster.append(image);
  }
  const text=document.createElement('div');text.className='movie-summary';
  const title=document.createElement(heading);title.textContent=movie.name;text.append(title);
  const facts=document.createElement('p');facts.className='movie-facts';
  const info=movie.movieInfo||{};
  if(movie.releaseInfo){const year=document.createElement('span');year.textContent=movie.releaseInfo;facts.append(year);}
  if(Number.isInteger(info.runtimeMinutes)&&info.runtimeMinutes>0&&info.runtimeMinutes<=1500){const runtime=document.createElement('span');const h=Math.floor(info.runtimeMinutes/60),m=info.runtimeMinutes%60;runtime.textContent=h?`${h}h ${m}m`:`${m} min`;runtime.title=info.runtimeMinutes+' minutes';facts.append(runtime);}
  if(/^tt\d{5,12}$/.test(movie.id||'')){
    const imdb=document.createElement('a');imdb.className='imdb-link';imdb.href='https://www.imdb.com/title/'+movie.id+'/';imdb.target='_blank';imdb.rel='noopener noreferrer';
    imdb.textContent=Number.isFinite(info.imdbRating)&&info.imdbRating>=0&&info.imdbRating<=10?'IMDb '+info.imdbRating.toFixed(1):'IMDb';
    imdb.setAttribute('aria-label','Open '+movie.name+' on IMDb in a new tab');
    imdb.title=Number.isFinite(info.imdbRating)?'IMDb rating supplied by Cinemeta; not a live IMDb lookup.':'View movie information on IMDb';facts.append(imdb);
  }
  text.append(facts);
  if(movie.manualSuggestion){const note=document.createElement('p');note.className='muted';note.textContent='Added from your search';text.append(note);}
  if(movie.genres?.length){const genres=document.createElement('ul');genres.className='movie-genres';genres.setAttribute('aria-label','Genres');
    for(const g of movie.genres){const li=document.createElement('li');li.textContent=g;genres.append(li);}text.append(genres);}
  overview.append(poster,text);overview.pickBadge=badge;return overview;
}
function fullSummary(movie){
  const p=document.createElement('p');p.className='synopsis synopsis-full';p.textContent=movie.movieInfo?.summary||movie.synopsis||movie.description||'Description unavailable.';return p;
}
function trailerLink(movie){
  const link=document.createElement('a');link.className='trailer trailer-visible';link.target='_blank';link.rel='noopener noreferrer';
  if(movie.trailer){link.href=movie.trailer.url;link.textContent='Official trailer · '+movie.trailer.publisher;}
  else if(movie.movieInfo?.metadataTrailer){link.href=movie.movieInfo.metadataTrailer.url;link.textContent='Watch trailer on YouTube';link.title='Trailer listed by Cinemeta; official publisher not independently verified.';}
  else{link.href='https://www.youtube.com/results?search_query='+encodeURIComponent(movie.name+' '+(movie.releaseInfo||'')+' official trailer');link.textContent='Find trailer on YouTube';link.title='YouTube search results; a direct trailer has not been verified.';}
  return link;
}
function movieDetails(movie){
  const details=document.createElement('details');details.className='movie-details';
  const summary=document.createElement('summary');const info=movie.movieInfo||{};
  summary.textContent=movie.intensityGuide?'Cast, crew & intensity guide':'Cast & crew';details.append(summary);
  for(const [label,names] of [['Director',info.director],['Cast',info.cast]])if(Array.isArray(names)&&names.length){const p=document.createElement('p');const b=document.createElement('strong');b.textContent=label+': ';p.append(b,document.createTextNode(names.join(', ')));details.append(p);}
  if(movie.intensityGuide){const p=document.createElement('p');p.className='intensity-guide';p.textContent='Intensity guide ('+(movie.screening||'editorial')+'): '+movie.intensityGuide;details.append(p);}
  if(info.provider==='Cinemeta'){
    const credit=document.createElement('p');credit.className='metadata-credit';
    credit.textContent='Movie details and any IMDb rating supplied by Cinemeta. ';
    if(Number.isInteger(info.fetchedEpoch))credit.append(document.createTextNode('Checked '+new Date(info.fetchedEpoch*1000).toLocaleDateString()+'. '));
    const source=document.createElement('a');source.href='https://v3-cinemeta.strem.io/meta/movie/'+movie.id+'.json';source.target='_blank';source.rel='noopener noreferrer';source.textContent='Metadata source';credit.append(source);details.append(credit);
  }else{const credit=document.createElement('p');credit.className='metadata-credit';credit.textContent='Additional metadata unavailable. Open IMDb for more movie information.';details.append(credit);}
  return details;
}
function cardBody(movie,heading){
  const card=document.createElement('article');card.className='movie-card';card.dataset.movie=movie.id;
  const overview=movieOverview(movie,heading);
  const links=document.createElement('div');links.className='card-links';links.append(trailerLink(movie));
  card.append(overview,fullSummary(movie),links,movieDetails(movie));card.pickBadge=overview.pickBadge;return card;
}
async function dislike(movie,value='dislike'){
  const previous=movie.feedback==='like'?'like':'clear', wasPicked=selected.has(movie.id);
  if(await reviewWrite('feedback',{imdb:movie.id,value}))
    toast(value==='seen'?`Marked “${movie.name}” as seen. It won’t be suggested again.`:`Removed “${movie.name}”`,'Undo',async()=>{
      if(await reviewWrite('feedback',{imdb:movie.id,value:previous})){
        if(wasPicked&&pickCards.has(movie.id)&&selected.size<maxPicks){selected.add(movie.id);selectionCount();}
      }
    });
}
function togglePick(movie){
  if(selected.has(movie.id))selected.delete(movie.id);
  else if(selected.size>=maxPicks){toast(`You already have ${maxPicks} picks. Remove one first.`);return;}
  else selected.add(movie.id);
  selectionCount();
}
let savedGenres=null,genreDraft=null,genreSaving=false;
function renderGenreSummary(data){
  const settings=data.genreSettings;
  if(settings){
    savedGenres={included:[...settings.included],excluded:[...settings.excluded],revision:settings.revision,options:[...settings.options]};
    if($('genre-editor').open&&genreDraft&&genreDraft.revision!==settings.revision&&!genreSaving){
      $('genre-status').textContent='Saved settings changed on another device. Reload them before saving.';$('reload-genres').hidden=false;
    }
  }
  const included=settings?.included||[];
  $('genre-summary').textContent=settings?(included.length?'Include: '+included.join(', '):'Include: any genre'):'Genre settings are unavailable. Refresh Movie Night.';
  const chips=['2016 onward',...(settings?.excluded||data.excludedGenres||[]).map(g=>'No '+g)];
  if(settings&&!settings.excluded.length)chips.push('No genre exclusions');
  $('genre-chips').replaceChildren(...chips.map(label=>{const li=document.createElement('li');li.textContent=label;return li;}));
  $('edit-genres').disabled=!settings||!data.reviewEnabled||genreSaving;
}
function fillGenreDraft(){
  for(const [key,prefix,empty] of [['included','include','Any genre'],['excluded','exclude','No genres excluded']]){
    const container=$(key+'-tags');container.replaceChildren();
    for(const genre of genreDraft[key]){
      const button=document.createElement('button');button.type='button';button.textContent=genre+' ×';
      button.setAttribute('aria-label','Remove '+genre+' from '+key+' genres');button.disabled=genreSaving;
      button.onclick=()=>{genreDraft[key]=genreDraft[key].filter(g=>g!==genre);fillGenreDraft();$(prefix+'-add').focus();};container.append(button);
    }
    if(!genreDraft[key].length){const note=document.createElement('span');note.className='empty';note.textContent=empty;container.append(note);}
    const select=$(prefix+'-add');select.replaceChildren();
    const placeholder=document.createElement('option');placeholder.value='';placeholder.textContent='Choose a genre to add…';select.append(placeholder);
    for(const genre of savedGenres.options.filter(g=>!genreDraft[key].includes(g))){const option=document.createElement('option');option.value=genre;option.textContent=genre;select.append(option);}
    select.disabled=genreSaving;$(prefix+'-clear').disabled=genreSaving||!genreDraft[key].length;
  }
  $('save-genres').disabled=genreSaving;$('cancel-genres').disabled=genreSaving;$('reload-genres').disabled=genreSaving;
}
function newGenreDraft(){
  genreDraft={included:[...savedGenres.included],excluded:[...savedGenres.excluded],revision:savedGenres.revision};
  $('genre-status').textContent='';$('reload-genres').hidden=true;fillGenreDraft();
}
$('edit-genres').onclick=()=>{if(!savedGenres||genreSaving)return;newGenreDraft();$('genre-editor').showModal();$('genre-title').focus();};
for(const [key,prefix,other] of [['included','include','excluded'],['excluded','exclude','included']]){
  $(prefix+'-add').onchange=event=>{
    const genre=event.target.value;if(!genre||genreSaving)return;
    const moved=genreDraft[other].includes(genre);genreDraft[other]=genreDraft[other].filter(g=>g!==genre);
    genreDraft[key].push(genre);fillGenreDraft();$(prefix+'-add').focus();
    $('genre-status').textContent=moved?genre+' moved from '+other+' to '+key+'.':'';
  };
  $(prefix+'-clear').onclick=()=>{genreDraft[key]=[];fillGenreDraft();$(prefix+'-add').focus();};
}
$('cancel-genres').onclick=()=>{$('genre-editor').close();genreDraft=null;};
$('genre-editor').addEventListener('cancel',event=>{if(genreSaving)event.preventDefault();else genreDraft=null;});
$('reload-genres').onclick=async()=>{
  if(genreSaving)return;genreSaving=true;fillGenreDraft();
  try{const data=await api('shortlist');render(data);newGenreDraft();$('genre-status').textContent='Loaded saved settings.';}
  catch(error){$('genre-status').textContent=error.message+' Your draft has been kept.';}
  finally{genreSaving=false;fillGenreDraft();}
};
$('save-genres').onclick=async()=>{
  if(genreSaving||reviewBusy)return;
  genreSaving=true;reviewBusy=true;++loadGeneration;fillGenreDraft();selectionCount();$('genre-status').textContent='Saving…';
  try{
    const data=await api('feedback',{action:'set-genre-settings',settings:genreDraft});
    $('genre-editor').close();genreDraft=null;render(data);toast('Genres saved. Suggestions updated.');
  }catch(error){
    $('genre-status').textContent=error.message+(error.kind==='connection'?' Reload saved settings to check whether the save completed.':'');
    $('reload-genres').hidden=false;if(error.kind==='session'||error.kind==='page')showFailure(error);
  }finally{genreSaving=false;reviewBusy=false;if(genreDraft)fillGenreDraft();$('edit-genres').disabled=!savedGenres;selectionCount();}
};
let similarGeneration=0,similarBusy=false,similarEnabled=false,similarRevision=null;
let titleTimer=null,titleWorking=false,titlePending=null,titleVersion=0,titleResponse=null,titleActive=-1,titleWantsPopup=false,titleComposing=false;
let previewObserver=null,previewTimer=null,previewWorking=false,previewPending=[];
const titlePreviews=new Map();
function searchControls(){
  $('search-titles').disabled=!similarEnabled||similarBusy;
  $('similar-query').disabled=!similarEnabled;
  $('similar-search').setAttribute('aria-busy',String(similarBusy||titleWorking));
}
function clearSimilar(message=''){
  invalidateTitles();
  ++similarGeneration;similarBusy=false;similarRevision=null;
  $('similar-titles').replaceChildren();$('similar-movies').replaceChildren();$('similar-results').hidden=true;
  $('similar-status').textContent=message;$('clear-similar').hidden=!message;searchControls();
}
function syncSimilar(data){
  similarEnabled=!!data.similarSearchEnabled;
  const seen=new Set((data.seen||[]).map(r=>r.id)),disliked=new Set((data.disliked||[]).map(r=>r.id));
  for(const b of $('similar-movies').querySelectorAll('[data-similar-add]')){
    b.dataset.feedbackBlocked=seen.has(b.dataset.similarAdd)?'seen':disliked.has(b.dataset.similarAdd)?'dislike':'';
    similarButtonState(b);
  }
  searchControls();
}
function similarButtonState(button){
  const block=button.dataset.historyBlocked||button.dataset.feedbackBlocked;
  button.disabled=!!block;
  button.textContent=block?(block==='dislike'?'Not for me — cannot add':'Watched — cannot add'):
    pickCards.has(button.dataset.similarAdd)?'Show in shortlist':'Add to shortlist';
}
async function searchJob(data,generation,finishStale=false){
  let result=await api('feedback',data);const deadline=performance.now()+75000;
  while(result.state==='searching'){
    if(!finishStale&&generation!==similarGeneration)return null;
    if(performance.now()>deadline)throw new Error('This search is taking too long. Please try again shortly.');
    await new Promise(resolve=>setTimeout(resolve,750));
    if(!finishStale&&generation!==similarGeneration)return null;
    result=await api('feedback',{action:'similar-status',jobId:result.jobId});
  }
  return finishStale||generation===similarGeneration?result:null;
}
function similarError(error){
  $('similar-status').textContent=error.message+' Your picks have been kept.';
  if(error.kind==='session'||error.kind==='page')showFailure(error);
}
async function findSimilar(title,titleJob){
  if(similarBusy)return;
  const generation=++similarGeneration;similarBusy=true;similarRevision=savedGenres?.revision??null;searchControls();
  $('similar-movies').replaceChildren();$('similar-results').hidden=true;
  $('similar-status').textContent=`Finding movies related to ${title.name}${title.releaseInfo?' ('+title.releaseInfo+')':''}… This can take about a minute.`;
  try{
    const result=await searchJob({action:'find-similar',jobId:titleJob,imdb:title.id},generation);
    if(!result)return;
    const name=result.reference.name+(result.reference.releaseInfo?' ('+result.reference.releaseInfo+')':'');
    $('similar-results-title').textContent='Movies related to '+name;
    $('similar-status').textContent=result.movies.length?`${result.movies.length} related movies · all genres and years.${result.partial?' Some metadata was unavailable; these are the verified matches.':''}`:
      'No verified related movies were found. Try another title or search again.';
    $('similar-results').hidden=!result.movies.length;
    for(const movie of result.movies){
      const card=cardBody(movie,'h4'),reasons=document.createElement('ul');reasons.className='similar-reasons';
      for(const text of movie.similarReasons||[]){const li=document.createElement('li');li.textContent=text;reasons.append(li);}
      const add=document.createElement('button');add.type='button';add.dataset.similarAdd=movie.id;
      add.dataset.historyBlocked=movie.selectionBlock==='known-seen'?'known-seen':'';
      add.dataset.feedbackBlocked=['seen','dislike'].includes(movie.selectionBlock)?movie.selectionBlock:'';
      similarButtonState(add);
      add.onclick=async()=>{
        if(reviewBusy)return;
        if(!pickCards.has(movie.id)){
          reviewBusy=true;++loadGeneration;add.disabled=true;selectionCount();
          try{
            render(await api('feedback',{action:'add-similar',jobId:result.jobId,imdb:movie.id}));
            toast('Added “'+movie.name+'” to your shortlist. Use Pick to select it.');
          }catch(error){similarError(error);if(error.kind==='connection')load();return;}
          finally{reviewBusy=false;similarButtonState(add);selectionCount();}
        }
        const target=pickCards.get(movie.id)?.card;
        if(target){target.tabIndex=-1;target.scrollIntoView({block:'center'});target.focus({preventScroll:true});}
      };
      card.append(reasons,add);$('similar-movies').append(card);
    }
    if(result.movies.length){$('similar-results-title').scrollIntoView({block:'start'});$('similar-results-title').focus({preventScroll:true});}
  }catch(error){if(generation===similarGeneration)similarError(error);}
  finally{if(generation===similarGeneration){similarBusy=false;searchControls();}}
}
// One debounced title lookup at a time; newer typing replaces pending work.
function titleQuery(){return $('similar-query').value.trim().replace(/\s+/g,' ');}
function titleViewBounds(){
  const view=window.visualViewport,top=view?.offsetTop||0;
  let bottom=top+(view?.height||innerHeight);
  if(!$('selection').hidden){const tray=$('selection').getBoundingClientRect();if(tray.height&&tray.top>top)bottom=Math.min(bottom,tray.top);}
  return {top,bottom};
}
function keepTitleVisible(){
  if(document.activeElement!==$('similar-query'))return;
  const rect=$('similar-query').getBoundingClientRect(),{top,bottom}=titleViewBounds();
  if(rect.bottom>bottom-12||rect.top<top+12)
    window.scrollBy({top:rect.top-(top+Math.max(12,(bottom-top-rect.height)/2)),behavior:'instant'});
}
function positionTitlePopup(){
  if($('title-popup').hidden)return;
  const rect=$('similar-query').getBoundingClientRect(),{top,bottom}=titleViewBounds();
  const below=bottom-rect.bottom-12,above=rect.top-top-12,useAbove=below<280&&above>below;
  $('title-popup').style.width=$('similar-form').querySelector('.similar-input').clientWidth+'px';
  $('title-popup').classList.toggle('above',useAbove);
  $('title-popup').style.maxHeight=Math.max(80,Math.min(480,useAbove?above:below))+'px';
}
function closeTitlePopup(){
  stopTitlePreviews();
  titleWantsPopup=false;$('title-popup').hidden=true;$('similar-query').setAttribute('aria-expanded','false');
  setTitleActive(-1);
}
function showTitlePopup(message,retry=false){
  $('title-popup-status').textContent=message;$('title-popup-retry').hidden=!retry;
  if(!titleWantsPopup||!$('title-picker').contains(document.activeElement))return;
  $('title-popup').hidden=false;$('similar-query').setAttribute('aria-expanded','true');positionTitlePopup();
}
function setTitleActive(index){
  const options=[...$('similar-titles').querySelectorAll('[role="option"]')];
  titleActive=index>=0&&index<options.length?index:-1;
  options.forEach((option,i)=>option.setAttribute('aria-selected',String(i===titleActive)));
  if(titleActive<0)$('similar-query').removeAttribute('aria-activedescendant');
  else{$('similar-query').setAttribute('aria-activedescendant',options[titleActive].id);options[titleActive].scrollIntoView({block:'nearest'});}
}
function invalidateTitles(){
  if(titleTimer)clearTimeout(titleTimer);titleTimer=null;titlePending=null;++titleVersion;
  titleResponse=null;$('similar-titles').replaceChildren();closeTitlePopup();
}
function chooseTitle(title,jobId){
  if(similarBusy)return;
  if(titleTimer)clearTimeout(titleTimer);titleTimer=null;titlePending=null;++titleVersion;
  $('similar-query').value=title.name;closeTitlePopup();$('similar-query').blur();
  findSimilar(title,jobId);
}
function stopTitlePreviews(){
  previewObserver?.disconnect();previewObserver=null;previewPending=[];
  if(previewTimer)clearTimeout(previewTimer);previewTimer=null;
}
function previewVisible(button){
  if(!button.isConnected||$('title-popup').hidden)return false;
  const row=button.getBoundingClientRect(),popup=$('title-popup').getBoundingClientRect();
  return row.bottom>popup.top&&row.top<popup.bottom;
}
function fillTitlePreview(button,title){
  const detail=button.querySelector('.title-option-detail'),info=title.movieInfo||{};
  detail.replaceChildren();
  const line=(text,cls)=>{if(!text)return;const span=document.createElement('span');span.className=cls;span.textContent=text;detail.append(span);};
  const facts=[...(title.genres||[]).slice(0,3)];
  if(Number.isInteger(info.runtimeMinutes)&&info.runtimeMinutes>0){const h=Math.floor(info.runtimeMinutes/60),m=info.runtimeMinutes%60;facts.push(h?`${h}h ${m}m`:`${m} min`);}
  if(Number.isFinite(info.imdbRating))facts.push('IMDb '+info.imdbRating.toFixed(1));
  line(facts.join(' · '),'title-option-facts');
  if(detail.querySelector('.title-option-facts'))detail.querySelector('.title-option-facts').title='Movie details supplied by Cinemeta';
  if(info.cast?.length)line('Cast: '+info.cast.join(', '),'title-option-people');
  if(info.director?.length)line('Director: '+info.director.join(', '),'title-option-director');
  line(info.summary||'Synopsis unavailable.','title-option-story');
  button.dataset.preview='ready';
}
async function drainTitlePreviews(){
  if(previewWorking)return;
  previewWorking=true;
  try{
    while(previewPending.length){
      const request=previewPending.shift(),{button,title,jobId,version}=request;
      if(version!==titleVersion||!titleWantsPopup||!previewVisible(button)){if(button.dataset.preview==='queued')button.dataset.preview='idle';continue;}
      button.dataset.preview='loading';
      try{
        // Complete stale reads silently, keeping at most one preview active.
        // The other server worker remains available for new title typing.
        const result=await searchJob({action:'title-preview',jobId,imdb:title.id},null,true);
        if(result.title?.id!==title.id)throw new Error('Movie details unavailable.');
        titlePreviews.delete(title.id);titlePreviews.set(title.id,{title:result.title,receivedAt:Date.now()});
        while(titlePreviews.size>80)titlePreviews.delete(titlePreviews.keys().next().value);
        if(version===titleVersion&&button.isConnected)fillTitlePreview(button,result.title);
      }catch(error){
        if(version===titleVersion&&button.isConnected){
          button.dataset.preview='failed';button.querySelector('.title-option-detail').textContent='Details unavailable. Search again to retry.';
        }
      }
    }
  }finally{previewWorking=false;}
}
function watchTitlePreviews(result){
  const version=titleVersion;
  previewObserver=new IntersectionObserver(entries=>{
    for(const entry of entries){
      const button=entry.target;
      if(!entry.isIntersecting||version!==titleVersion||!titleWantsPopup)continue;
      const poster=button.querySelector('img[data-src]');if(poster){poster.src=poster.dataset.src;delete poster.dataset.src;}
      if(result.previewsEnabled&&button.dataset.preview==='idle'){
        button.dataset.preview='queued';previewPending.push({button,title:result.titles[Number(button.dataset.titleIndex)],jobId:result.jobId,version});
      }
    }
    if(previewPending.length&&!previewTimer)previewTimer=setTimeout(()=>{previewTimer=null;drainTitlePreviews();},180);
  },{root:$('title-popup'),threshold:0});
  for(const button of $('similar-titles').querySelectorAll('[role="option"]'))previewObserver.observe(button);
}
function renderTitles(result){
  stopTitlePreviews();
  $('similar-titles').replaceChildren();setTitleActive(-1);
  for(const [index,title] of result.titles.entries()){
    const li=document.createElement('li'),button=document.createElement('button');li.setAttribute('role','presentation');
    button.type='button';button.tabIndex=-1;button.id='movie-title-option-'+index;button.setAttribute('role','option');button.setAttribute('aria-selected','false');
    const label=title.name+' · '+(title.releaseInfo||'Year unavailable');
    button.setAttribute('aria-label',label);button.dataset.titleIndex=index;button.dataset.preview='idle';
    const poster=document.createElement('span');poster.className='title-option-poster';poster.setAttribute('aria-hidden','true');
    const fallback=document.createElement('span');fallback.textContent='No poster';poster.append(fallback);
    if(/^tt\d{5,12}$/.test(title.id||'')){
      const img=document.createElement('img');img.alt='';img.width=64;img.height=96;img.decoding='async';img.referrerPolicy='no-referrer';img.dataset.src=base+'/posters/'+title.id+'.img';
      img.onload=()=>{fallback.hidden=true;};img.onerror=()=>{img.remove();fallback.hidden=false;};poster.append(img);
    }
    const copy=document.createElement('span');copy.className='title-option-copy';
    const name=document.createElement('span');name.className='title-option-name';name.textContent=label;
    const detail=document.createElement('span');detail.className='title-option-detail';detail.id='movie-title-detail-'+index;
    detail.textContent=result.previewsEnabled?'Loading details…':'Movie details unavailable.';
    button.setAttribute('aria-describedby',detail.id);copy.append(name,detail);button.append(poster,copy);
    const cached=titlePreviews.get(title.id);if(cached&&Date.now()-cached.receivedAt<600000)fillTitlePreview(button,cached.title);
    button.onpointerdown=event=>{if(event.pointerType==='mouse')event.preventDefault();};
    button.onclick=()=>chooseTitle(title,result.jobId);li.append(button);$('similar-titles').append(li);
  }
  const message=result.titles.length?`${result.titles.length} matches. Tap a movie, or use ↑ ↓ and Enter.`:'No movie titles found. Check the spelling or try a shorter title.';
  showTitlePopup(message);$('similar-status').textContent=result.titles.length?'Choose a movie from the popup to find related suggestions.':message;
  watchTitlePreviews(result);
}
async function drainTitleLookups(){
  if(titleWorking)return;
  titleWorking=true;searchControls();
  try{
    while(titlePending){
      const request=titlePending;titlePending=null;
      try{
        // Finish an older read silently so fast typing cannot flood the server's job queue.
        const result=await searchJob({action:'search-titles',query:request.query},null,true);
        if(request.version!==titleVersion||request.query!==titleQuery())continue;
        titleResponse={...result,query:request.query,receivedAt:Date.now()};renderTitles(titleResponse);
      }catch(error){
        if(request.version!==titleVersion)continue;
        showTitlePopup(error.message+' Try again.',true);similarError(error);
      }
    }
  }finally{titleWorking=false;searchControls();}
}
function requestTitles(immediate=false){
  stopTitlePreviews();
  if(titleTimer)clearTimeout(titleTimer);titleTimer=null;titlePending=null;
  const query=titleQuery(),version=++titleVersion;
  $('similar-titles').replaceChildren();setTitleActive(-1);
  if(!similarEnabled||query.length<2||query.length>120||titleComposing){closeTitlePopup();return;}
  titleWantsPopup=true;$('clear-similar').hidden=false;titleResponse=null;
  showTitlePopup('Looking up movie titles…');
  const launch=()=>{titleTimer=null;titlePending={query,version};drainTitleLookups();};
  if(immediate)launch();else titleTimer=setTimeout(launch,350);
}
function titleEdited(){
  ++similarGeneration;similarBusy=false;similarRevision=null;
  $('similar-movies').replaceChildren();$('similar-results').hidden=true;$('similar-status').textContent='';
  $('clear-similar').hidden=!$('similar-query').value;
  requestTitles();searchControls();
}
$('similar-query').addEventListener('input',titleEdited);
$('similar-query').addEventListener('compositionstart',()=>{titleComposing=true;invalidateTitles();});
$('similar-query').addEventListener('compositionend',()=>{titleComposing=false;titleEdited();});
$('similar-query').addEventListener('focus',()=>{
  keepTitleVisible();
  if(titleComposing||titleQuery().length<2||similarBusy)return;
  titleWantsPopup=true;
  if(titleResponse?.query===titleQuery()&&Date.now()-titleResponse.receivedAt<600000)renderTitles(titleResponse);
  else requestTitles();
});
$('similar-query').addEventListener('keydown',event=>{
  if(event.isComposing||titleComposing)return;
  if(event.key==='Escape'){
    event.preventDefault();if(titleTimer)clearTimeout(titleTimer);titleTimer=null;titlePending=null;++titleVersion;closeTitlePopup();return;
  }
  if(event.key==='ArrowDown'||event.key==='ArrowUp'){
    event.preventDefault();
    if($('title-popup').hidden){
      titleWantsPopup=true;
      if(titleResponse?.query===titleQuery()&&Date.now()-titleResponse.receivedAt<600000)renderTitles(titleResponse);
      else{requestTitles(true);return;}
    }
    const count=$('similar-titles').children.length;
    if(count)setTitleActive(titleActive<0?(event.key==='ArrowDown'?0:count-1):(titleActive+(event.key==='ArrowDown'?1:-1)+count)%count);
  }else if(event.key==='Enter'&&!$('title-popup').hidden&&titleActive>=0){
    event.preventDefault();$('similar-titles').querySelectorAll('[role="option"]')[titleActive].click();
  }
});
$('title-picker').addEventListener('focusout',event=>{if(!$('title-picker').contains(event.relatedTarget))closeTitlePopup();});
document.addEventListener('pointerdown',event=>{if(!$('title-picker').contains(event.target))closeTitlePopup();});
const resizeTitlePopup=()=>{keepTitleVisible();positionTitlePopup();};
window.addEventListener('resize',resizeTitlePopup);
window.addEventListener('scroll',positionTitlePopup,true);
window.visualViewport?.addEventListener('resize',resizeTitlePopup);
window.visualViewport?.addEventListener('scroll',positionTitlePopup);
$('similar-form').onsubmit=event=>{
  event.preventDefault();if(!similarEnabled||titleComposing)return;
  $('similar-query').focus();requestTitles(true);
};
$('title-popup-retry').onclick=()=>{$('similar-query').focus();requestTitles(true);};
$('clear-similar').onclick=()=>{clearSimilar();$('similar-query').value='';$('similar-query').focus();};


function render(data){
  renderGenreSummary(data);
  autoDownloads=!!data.autoDownloads;downloadRequestedIds=new Set(data.downloadRequestedIds||[]);
  $('download-step').textContent=autoDownloads?'Finalize & download saves your picks and starts their server downloads automatically.':'Review server download on a finalized movie. Confirm its exact file to start.';
  $('download-rule').textContent=autoDownloads?'The server chooses a suitable cached 1080p file. Downloads keep running after you close the page. Likes and Pick alone do not start downloads.':'Likes and finalized picks never start a download.';
  $('finalized-help').textContent=autoDownloads?'Server status updates on each card. Ready files are saved on the 8 TB drive; Save a copy downloads a separate copy to this device. View download details for retry or cancellation.':'Next, review each exact file, quality, codec, size, available storage and 8 TB drive destination before confirming its download.';
  if(!initialized){selected=new Set(data.finalized?.ids||[]);initialized=true;}
  selected=new Set([...selected].filter(id=>(data.eligibleIds||[]).includes(id)));
  $('movies').replaceChildren();$('finalized-movies').replaceChildren();$('removed-movies').replaceChildren();pickCards.clear();cardDownloads.clear();
  for(const movie of [...data.movies,...(data.finalized?.movies||[])])titles.set(movie.id,movie.name);
  const messages=[];
  if(!data.seenStateComplete)messages.push('Watched filtering: known exclusions only (Heretic and Companion). Complete watch-history access is not yet verified.');
  if(!data.actionsEnabled)messages.push('Downloads and stream checks are not activated.');
  if(data.shortlistFresh===false)messages.push('Weekly suggestions need refreshing. Your likes, dislikes and saved selections are retained.');
  else if(!data.movies.length)messages.push('No more reviewed suggestions match. Removed or seen movies will not be used as replacements.');
  else if(data.movies.length<(data.selectionLimits?.visible||maxPicks))messages.push('These are the remaining reviewed matches; no unrelated fallback was added.');
  inform(messages);
  for(const movie of data.movies){
    const card=cardBody(movie,'h2');
    if(data.reviewEnabled){
      const controls=document.createElement('div');controls.className='card-controls';
      const liked=movie.feedback==='like';
      const like=document.createElement('button');like.type='button';like.append(icon(liked?'♥':'♡'),document.createTextNode(liked?'Liked':'Like'));like.setAttribute('aria-pressed',String(liked));
      like.setAttribute('aria-label',(liked?'Liked: ':'Like ')+movie.name);
      like.onclick=()=>reviewWrite('feedback',{imdb:movie.id,value:liked?'clear':'like'});
      const nope=document.createElement('button');nope.type='button';nope.append(icon('✕'),document.createTextNode('Not for me'));nope.setAttribute('aria-label','Not for me: remove and replace '+movie.name);
      nope.onclick=()=>dislike(movie);
      const seen=document.createElement('button');seen.type='button';seen.className='seen-toggle';seen.append(icon('👁'),document.createTextNode('Seen'));seen.setAttribute('aria-label','Seen it: never suggest '+movie.name+' again');seen.title='Already watched. Stop suggesting this movie.';seen.onclick=()=>dislike(movie,'seen');
      const pick=document.createElement('button');pick.type='button';pick.className='pick-toggle';pick.setAttribute('aria-label','Pick '+movie.name+' for movie night');
      pick.onclick=()=>togglePick(movie);
      controls.append(like,seen,nope,pick);card.append(controls);
      pickCards.set(movie.id,{card,button:pick,badge:card.pickBadge});
    }else card.append(watchButtons(movie,data.actionsEnabled));
    $('movies').append(card);
  }
  $('refill').hidden=!data.reviewEnabled;
  const refill=data.refillRequest||{};
  $('reserve-status').textContent=refill.discoveryEnabled ? `${(data.reserveCount||0)+(refill.available||0)} more movies ready. New ones are fetched automatically when this runs low.` : `${data.reserveCount||0} reviewed replacements ready. This is a finite reviewed pool; new movies are added after review, not discovered automatically.`;
  $('request-refill').disabled=refill.running || refill.retryAfter>0 || (!refill.discoveryEnabled && refill.pending && !refill.available);
  const outcomes={
    searching:'Finding new movies and checking your filters. This can take up to a minute. This search does not start downloads.',
    'provider-unavailable':'The metadata provider is unavailable. Your choices are safe. Try Request more again in a minute.',
    'no-match':'No new eligible matches in this search batch. Your filters are unchanged. Try the next batch in a minute.',
    'settings-changed':'Genre settings changed during the search. Finding matches for your saved settings.',
    'state-changed':'Your shortlist changed during the search. Refresh, then request more again.',
    interrupted:'The last search was interrupted. Request more to retry.',
    refilled:`Added ${refill.added||0} matching movies. This search does not start downloads.`
  };
  $('refill-status').textContent=refill.discoveryEnabled ? (outcomes[refill.outcome]||`${refill.available||0} saved replacements available. Request more also searches for new matches when needed.`) : refill.available ? `${refill.available} unused reviewed titles available. Request more adds up to five; this is a finite supply, not automatic discovery.` : refill.pending ? 'Refill requested. The reviewed supply is exhausted or unavailable; a fresh reviewed update is needed. Nothing is queued for download.' : 'Reviewed update loaded. No unused reviewed titles remain; another request will wait for a fresh reviewed update. This search does not start downloads.';
  if(refillTimer)clearTimeout(refillTimer);
  if(refill.running||refill.retryAfter>0)refillTimer=setTimeout(load,refill.running?1200:Math.min(5000,refill.retryAfter*1000+100));
  $('selection').hidden=!data.reviewEnabled;
  const f=data.finalized||{ids:[],valid:false,movies:[]};$('finalized').hidden=!f.ids.length;
  finalizedIds=f.ids||[];finalizedValid=!!f.valid;
  $('finalized-status').textContent=f.valid?`${f.ids.length} movies finalized. ${autoDownloads?(f.ids.every(id=>downloadRequestedIds.has(id))?'Their server download requests are listed below.':'Press Finalize & download to start their server downloads.'):'No download starts until you confirm an exact file.'}`:f.reason==='genre-filter'?'Some saved picks are outside your current genre filters. Review the remaining picks and finalize again. Existing server files are kept.':f.reason==='shortlist-stale'?'Your saved selections are retained. Refresh the weekly suggestions before confirming eligibility.':`Your saved selections are retained but need review because eligibility or feedback changed. Finalize ${minPicks}–${maxPicks} eligible movies again.`;
  const excluded=new Set(f.excludedIds||[]);
  for(const movie of f.movies){
    if(excluded.has(movie.id)){const note=document.createElement('p');note.className='genre-excluded muted';note.textContent=movie.name+' — outside your current filters. Any existing server file remains in downloads.';$('finalized-movies').append(note);continue;}
    const card=cardBody(movie,'h3');if(data.reviewEnabled&&f.ids.length>1)card.prepend(rankControls(movie,f.ids));if(data.actionsEnabled&&(f.valid||autoDownloads))card.append(watchButtons(movie,true));$('finalized-movies').append(card);
  }
  const ready=data.ready||[];$('ready-rank').hidden=!(data.reviewEnabled&&ready.length);$('ready-rank-list').replaceChildren();
  const readyIds=ready.map(m=>m.id);
  for(const movie of ready){const li=document.createElement('li'),name=document.createElement('span');name.className='ready-rank-name';name.textContent=movie.name+(movie.releaseInfo?` (${movie.releaseInfo})`:'');li.append(name);if(ready.length>1)li.prepend(rankControls(movie,readyIds));$('ready-rank-list').append(li);}
  const removed=[...(data.disliked||[]),...(data.seen||[]).map(m=>({...m,seenIt:true}))];$('removed').hidden=!removed.length;$('removed-count').textContent=removed.length?`(${removed.length})`:'';
  for(const movie of removed){const li=document.createElement('li'),name=document.createElement('span'),restore=document.createElement('button');name.textContent=movie.name+(movie.seenIt?' · Seen':'');restore.type='button';restore.className='secondary';restore.textContent='Restore';restore.setAttribute('aria-label','Restore '+movie.name);restore.onclick=()=>reviewWrite('feedback',{imdb:movie.id,value:'clear'});li.append(name,restore);$('removed-movies').append(li);}
  syncSimilar(data);
  updateCardDownloads();
}
$('request-refill').onclick=()=>reviewWrite('feedback',{action:'request-refill',requestId:crypto.randomUUID()});
$('finalize').onclick=async()=>{
  if(await reviewWrite('finalize',{ids:[...selected],...(autoDownloads?{startDownloads:true,requestId:crypto.randomUUID()}:{})})&&finalizedValid&&!$('finalized').hidden){
    toast(autoDownloads?'Picks finalized. 8 TB drive downloads requested.':'Picks finalized. No download starts until you confirm an exact file.');
    if(autoDownloads)await loadDownloads();
    $(autoDownloads?'downloads':'finalized').scrollIntoView({behavior:matchMedia('(prefers-reduced-motion: reduce)').matches?'auto':'smooth',block:'start'});$(autoDownloads?'downloads-title':'finalized-title').focus({preventScroll:true});
  }
};
async function load(){
  if(reviewBusy){recoverRead();return;}
  stopRecovery();const generation=++loadGeneration;
  try{const data=await api('shortlist');if(generation===loadGeneration){recoveryAttempts=0;render(data);if(data.actionsEnabled)loadDownloads();if(uncertainWrite){uncertainWrite=false;say('Connection recovered. Saved choices reloaded; check them before repeating your last action.');}}}
  catch(error){if(generation===loadGeneration)showFailure(error);}
}
window.addEventListener('pagehide',()=>{invalidateTitles();++similarGeneration;if(timer)clearTimeout(timer);if(downloadTimer)clearTimeout(downloadTimer);if(refillTimer)clearTimeout(refillTimer);hideToast();stopRecovery();});
window.addEventListener('focus',load);
window.addEventListener('online',()=>{recoveryAttempts=0;load();});
document.addEventListener('visibilitychange',()=>{if(!document.hidden)load();});
load();

