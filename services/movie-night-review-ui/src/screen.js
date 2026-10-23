'use strict';
const base = document.querySelector('meta[name="mn-base"]').content;
const csrf = document.querySelector('meta[name="mn-csrf"]').content;
const $ = id => document.getElementById(id);
let pending = null, job = null, timer = null, loadGeneration = 0;
let sourceBusy=false,downloadTimer=null;
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
async function propose(imdb) {
  try {
    if(sourceBusy)return;sourceBusy=true;
    say('Checking completed TorBox files for this movie. No download has started.');
    let result=await api('propose',{imdb});
    while(result.lookupId){await new Promise(resolve=>setTimeout(resolve,1200));result=await api('lookup/'+result.lookupId);}
    pending=result;const c=pending.choice;
    $('facts').replaceChildren();
    for(const [name,value] of [['Movie',`${c.title} (${c.year})`],['Edition',c.edition],['Provider',c.provider],
      ['Provider file',`${c.torrent_id} / ${c.file_id}: ${c.provider_name}`],['Quality / codec',`${c.quality} / ${c.codec}`],
      ['Exact size',`${c.size.toLocaleString('en-US')} bytes (${(c.size/1e9).toFixed(2)} GB)`],['Destination',c.destination],
      ['Free storage',`${pending.freeBytes.toLocaleString('en-US')} bytes`],['Required reserve',`${pending.reserveBytes.toLocaleString('en-US')} bytes`],
      ['Remaining transfer budget',`${pending.quotaRemainingBytes.toLocaleString('en-US')} bytes`],['Confirmation expires',new Date(pending.expiresEpoch*1000).toLocaleString()]]) fact(name,value);
    $('reply').value=''; $('confirm-error').textContent=''; $('confirmation').showModal(); $('confirmation').scrollTop=0; $('confirm-title').focus({preventScroll:true});
  } catch(error) { if(error.message==='No matching compact source')say('No completed 1080p file with a verified title, year, codec and size is available in your TorBox inventory. Nothing was started.');else showFailure(error); }
  finally{sourceBusy=false;}
}
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
$('back').onclick=()=>{$('confirmation').close();pending=null;};
$('cancel').onclick=async()=>{if(job)try{await api('cancel',{confirmationId:job});say('Cancellation requested. Partial files will be preserved.');await poll();}catch(e){say(e.message);}};
function sameAsFinalized(){return finalizedValid&&finalizedIds.length===selected.size&&finalizedIds.every(id=>selected.has(id));}
function selectionCount(){
  const n=selected.size, done=sameAsFinalized();
  const dots=document.createElement('span');dots.className='dots';dots.setAttribute('aria-hidden','true');
  for(let i=0;i<4;i++){const d=document.createElement('i');if(i<n)d.className='on';dots.append(d);}
  const label=done?`${n} picks finalized`:n<3?`${n} of 3–4 picked`:`${n} picked · ready to finalize`;
  $('selection-count').replaceChildren(dots,document.createTextNode(label));
  $('selection-names').textContent=n?[...selected].map(id=>titles.get(id)||'').filter(Boolean).join(' · '):'Use Pick on 3 or 4 movies.';
  $('finalize').textContent=done?'Finalized ✓':n>=3&&n<=4?`Finalize ${n} picks`:'Finalize picks';
  $('finalize').disabled=reviewBusy||done||n<3||n>4;
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
function watchButtons(movie,enabled){
  const actions=document.createElement('div');actions.className='buttons';
  if(!enabled){actions.hidden=true;return actions;}
  const download=document.createElement('button');download.textContent='Review server download';
  download.onclick=async()=>{download.disabled=true;try{await propose(movie.id);}finally{download.disabled=false;}};
  actions.append(download);return actions;
}
async function loadDownloads(){
  if(downloadTimer)clearTimeout(downloadTimer);
  try{
    const data=await api('downloads');const panel=$('downloads'),list=$('download-list');list.replaceChildren();panel.hidden=false;
    if(!data.jobs.length){const p=document.createElement('p');p.textContent='No downloads started. Finalize your picks, then review each server download.';list.append(p);}
    for(const item of data.jobs){
      const row=document.createElement('article');row.className='download-row';
      const title=document.createElement('h3');title.textContent=item.name;
      const state=document.createElement('p');state.textContent=item.state+' ? '+(item.bytesReceived/1e9).toFixed(2)+' of '+(item.size/1e9).toFixed(2)+' GB';
      const progress=document.createElement('progress');progress.max=item.size;progress.value=item.bytesReceived;progress.setAttribute('aria-label',item.name+' downloaded bytes');
      const detail=document.createElement('p');detail.className='muted';
      detail.textContent=item.downloaded?(item.indexed?'Verified file available on HP Envy. Playback has not been tested.':'Verified file preserved on HP Envy; library availability needs checking.'):(['failed','cancelled'].includes(item.state)?'Transfer stopped. Any partial file is preserved; it will not be overwritten.':'Downloading to HP Envy. This does not save a copy on your phone.');
      row.append(title,state,progress,detail);
      if(['approved','downloading'].includes(item.state)){
        const cancel=document.createElement('button');cancel.className='secondary';cancel.textContent='Cancel download';
        cancel.onclick=async()=>{cancel.disabled=true;try{await api('cancel',{confirmationId:item.id});await loadDownloads();}catch(e){showFailure(e);}finally{cancel.disabled=false;}};row.append(cancel);
      }
      if(item.indexed){
        const link=document.createElement('a');link.href=base+'/media/'+encodeURIComponent(item.imdb);link.textContent='Save a copy to this device';link.className='secondary';row.append(link);
      }
      list.append(row);
    }
    if(data.jobs.some(x=>['approved','downloading'].includes(x.state)))downloadTimer=setTimeout(loadDownloads,3000);
  }catch(error){showFailure(error);}
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
  if(movie.genres?.length){const genres=document.createElement('ul');genres.className='movie-genres';genres.setAttribute('aria-label','Genres');
    for(const g of movie.genres){const li=document.createElement('li');li.textContent=g;genres.append(li);}text.append(genres);}
  if(movie.similarToLiked&&movie.feedback!=='like'){const why=document.createElement('p');why.className='liked-note';why.textContent='Similar to movies you liked';text.append(why);}
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
        if(wasPicked&&pickCards.has(movie.id)&&selected.size<4){selected.add(movie.id);selectionCount();}
      }
    });
}
function togglePick(movie){
  if(selected.has(movie.id))selected.delete(movie.id);
  else if(selected.size>=4){toast('You already have 4 picks. Remove one first.');return;}
  else selected.add(movie.id);
  selectionCount();
}
function render(data){
  if(!initialized){selected=new Set(data.finalized?.valid?data.finalized.ids:[]);initialized=true;}
  selected=new Set([...selected].filter(id=>(data.eligibleIds||[]).includes(id)));
  $('movies').replaceChildren();$('finalized-movies').replaceChildren();$('removed-movies').replaceChildren();pickCards.clear();
  for(const movie of [...data.movies,...(data.finalized?.movies||[])])titles.set(movie.id,movie.name);
  const messages=[];
  if(!data.seenStateComplete)messages.push('Watched filtering: known exclusions only (Heretic and Companion). Complete watch-history access is not yet verified.');
  if(!data.actionsEnabled)messages.push('Downloads and stream checks are not activated.');
  if(data.shortlistFresh===false)messages.push('Weekly suggestions need refreshing. Your likes, dislikes and saved selections are retained.');
  else if(!data.movies.length)messages.push('No more reviewed suggestions match. Removed or seen movies will not be used as replacements.');
  else if(data.movies.length<5)messages.push('These are the remaining reviewed matches; no unrelated fallback was added.');
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
  $('finalized-status').textContent=f.valid?`${f.ids.length} movies finalized. No download starts until you confirm an exact file.`:f.reason==='genre-filter'?'Your saved selections are retained, but a title is ineligible under your no Comedy filter. Choose eligible replacements.':f.reason==='shortlist-stale'?'Your saved selections are retained. Refresh the weekly suggestions before confirming eligibility.':'Your saved selections are retained but need review because eligibility or feedback changed. Finalize 3–4 eligible movies again.';
  for(const movie of f.movies){const card=cardBody(movie,'h3');if(f.valid&&data.actionsEnabled)card.append(watchButtons(movie,true));$('finalized-movies').append(card);}
  const removed=[...(data.disliked||[]),...(data.seen||[]).map(m=>({...m,seenIt:true}))];$('removed').hidden=!removed.length;$('removed-count').textContent=removed.length?`(${removed.length})`:'';
  for(const movie of removed){const li=document.createElement('li'),name=document.createElement('span'),restore=document.createElement('button');name.textContent=movie.name+(movie.seenIt?' · Seen':'');restore.type='button';restore.className='secondary';restore.textContent='Restore';restore.setAttribute('aria-label','Restore '+movie.name);restore.onclick=()=>reviewWrite('feedback',{imdb:movie.id,value:'clear'});li.append(name,restore);$('removed-movies').append(li);}
  selectionCount();
}
$('request-refill').onclick=()=>reviewWrite('feedback',{action:'request-refill',requestId:crypto.randomUUID()});
$('finalize').onclick=async()=>{
  if(await reviewWrite('finalize',{ids:[...selected]})&&finalizedValid&&!$('finalized').hidden){
    toast('Picks finalized. No download starts until you confirm an exact file.');
    $('finalized').scrollIntoView({behavior:matchMedia('(prefers-reduced-motion: reduce)').matches?'auto':'smooth',block:'start'});$('finalized-title').focus({preventScroll:true});
  }
};
async function load(){
  if(reviewBusy){recoverRead();return;}
  stopRecovery();const generation=++loadGeneration;
  try{const data=await api('shortlist');if(generation===loadGeneration){recoveryAttempts=0;render(data);if(data.actionsEnabled)loadDownloads();if(uncertainWrite){uncertainWrite=false;say('Connection recovered. Saved choices reloaded; check them before repeating your last action.');}}}
  catch(error){if(generation===loadGeneration)showFailure(error);}
}
window.addEventListener('pagehide',()=>{if(timer)clearTimeout(timer);if(downloadTimer)clearTimeout(downloadTimer);if(refillTimer)clearTimeout(refillTimer);hideToast();stopRecovery();});
window.addEventListener('focus',load);
window.addEventListener('online',()=>{recoveryAttempts=0;load();});
document.addEventListener('visibilitychange',()=>{if(!document.hidden)load();});
load();
