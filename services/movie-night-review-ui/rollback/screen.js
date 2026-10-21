'use strict';
const base = document.querySelector('meta[name="mn-base"]').content;
const csrf = document.querySelector('meta[name="mn-csrf"]').content;
const $ = id => document.getElementById(id);
let pending = null, job = null, timer = null, loadGeneration = 0;
let selected=new Set(), initialized=false, reviewBusy=false;let refillTimer=null, recoveryTimer=null, recoveryAttempts=0, uncertainWrite=false;
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
    const retry=document.createElement('button');retry.textContent='Retry connection';retry.onclick=()=>{recoveryAttempts=0;load();};$('notice').append(retry);
    recoverRead();return;
  }
  say(error.message);
}
function say(message) { $('notice').textContent = message; }
function fact(label, value) {
  const dt=document.createElement('dt'), dd=document.createElement('dd');
  dt.textContent=label; dd.textContent=String(value); $('facts').append(dt,dd);
}
async function propose(imdb) {
  try {
    pending=await api('propose',{imdb}); const c=pending.choice;
    $('facts').replaceChildren();
    for(const [name,value] of [['Movie',`${c.title} (${c.year})`],['Edition',c.edition],['Provider',c.provider],
      ['Provider file',`${c.torrent_id} / ${c.file_id}: ${c.provider_name}`],['Quality / codec',`${c.quality} / ${c.codec}`],
      ['Exact size',`${c.size.toLocaleString('en-US')} bytes (${(c.size/1e9).toFixed(2)} GB)`],['Destination',c.destination],
      ['Free storage',`${pending.freeBytes.toLocaleString('en-US')} bytes`],['Required reserve',`${pending.reserveBytes.toLocaleString('en-US')} bytes`],
      ['Remaining transfer budget',`${pending.quotaRemainingBytes.toLocaleString('en-US')} bytes`],['Confirmation expires',new Date(pending.expiresEpoch*1000).toLocaleString()]]) fact(name,value);
    $('reply').value=''; $('confirm-error').textContent=''; $('confirmation').showModal(); $('confirmation').scrollTop=0; $('confirm-title').focus({preventScroll:true});
  } catch(error) { say(error.message); }
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
    job=result.id; $('progress').max=pending.choice.size; $('job').hidden=false; $('confirmation').close(); await poll();
  }catch(error){$('confirm-error').textContent=error.message;}finally{$('confirm-yes').disabled=false;}
};
$('back').onclick=()=>{$('confirmation').close();pending=null;};
$('cancel').onclick=async()=>{if(job)try{await api('cancel',{confirmationId:job});say('Cancellation requested. Partial files will be preserved.');await poll();}catch(e){say(e.message);}};
function selectionCount(){
  $('selection-count').textContent=`${selected.size} selected · choose 3 or 4`;
  $('finalize').disabled=reviewBusy||selected.size<3||selected.size>4;
}
async function reviewWrite(path,data){
  if(reviewBusy)return;
  reviewBusy=true;++loadGeneration;selectionCount();
  try{render(await api(path,data));}
  catch(error){showFailure(error,true);}
  finally{reviewBusy=false;selectionCount();}
}
function watchButtons(movie,enabled){
  const actions=document.createElement('div');actions.className='buttons';
  const download=document.createElement('button');download.textContent='Download ahead';download.disabled=!enabled;download.onclick=()=>propose(movie.id);
  const stream=document.createElement('button');stream.textContent='Check stream';stream.disabled=!enabled;
  stream.onclick=async()=>{stream.disabled=true;try{const r=await api('check-stream',{imdb:movie.id,sample:await measure()});
    say(r.status==='source-validated'?'Source check passed. Playback is not yet tested.':'Connection or codec suitability is not established for this source.');
    $('stream-result').hidden=r.status!=='source-validated';
    if(r.status==='source-validated')$('stream-now').href=base+'/play/'+encodeURIComponent(r.streamLease);
  }catch(e){say(e.message);}finally{stream.disabled=!enabled;}};
  actions.append(download,stream);return actions;
}
function movieOverview(movie,heading='h2'){
  const overview=document.createElement('div');overview.className='movie-overview';
  const poster=document.createElement('figure');poster.className='movie-poster';
  const missing=document.createElement('span');missing.className='poster-fallback';missing.textContent='Poster unavailable';
  poster.append(missing);
  if(/^tt\d{5,12}$/.test(movie.id||'')){
    const image=document.createElement('img');image.src=base+'/posters/'+movie.id+'.img';
    image.alt=movie.name+' poster';image.width=80;image.height=120;image.loading='lazy';image.decoding='async';image.referrerPolicy='no-referrer';
    image.onload=()=>{missing.hidden=true;};image.onerror=()=>{image.remove();missing.hidden=false;};poster.append(image);
  }
  const text=document.createElement('div');text.className='movie-summary';
  const title=document.createElement(heading);title.textContent=movie.name;text.append(title);
  const facts=document.createElement('p');facts.className='movie-facts';
  const year=document.createElement('span');year.textContent=movie.releaseInfo||'';facts.append(year);
  const info=movie.movieInfo||{};
  if(Number.isInteger(info.runtimeMinutes)&&info.runtimeMinutes>0&&info.runtimeMinutes<=1500){const runtime=document.createElement('span');runtime.textContent=info.runtimeMinutes+' min';facts.append(runtime);}
  if(/^tt\d{5,12}$/.test(movie.id||'')){
    const imdb=document.createElement('a');imdb.className='imdb-link';imdb.href='https://www.imdb.com/title/'+movie.id+'/';imdb.target='_blank';imdb.rel='noopener noreferrer';
    imdb.textContent=Number.isFinite(info.imdbRating)&&info.imdbRating>=0&&info.imdbRating<=10?'IMDb '+info.imdbRating.toFixed(1):'IMDb';
    imdb.setAttribute('aria-label','Open '+movie.name+' on IMDb in a new tab');
    imdb.title=Number.isFinite(info.imdbRating)?'IMDb rating supplied by Cinemeta; not a live IMDb lookup.':'View movie information on IMDb';facts.append(imdb);
  }
  text.append(facts);
  if(movie.genres?.length){const genres=document.createElement('p');genres.className='movie-genres';genres.textContent=movie.genres.join(' · ');text.append(genres);}
  overview.append(poster,text);return overview;
}
function fullSummary(movie){
  const p=document.createElement('p');p.className='synopsis synopsis-full';p.textContent=movie.movieInfo?.summary||movie.synopsis||movie.description||'Description unavailable.';return p;
}
function trailerLink(movie){
  const link=document.createElement('a');link.className='trailer trailer-visible';link.target='_blank';link.rel='noopener noreferrer';
  if(movie.trailer){link.href=movie.trailer.url;link.textContent='Watch official trailer · '+movie.trailer.publisher;}
  else if(movie.movieInfo?.metadataTrailer){link.href=movie.movieInfo.metadataTrailer.url;link.textContent='Watch trailer on YouTube';link.title='Trailer listed by Cinemeta; official publisher not independently verified.';}
  else{link.href='https://www.youtube.com/results?search_query='+encodeURIComponent(movie.name+' '+(movie.releaseInfo||'')+' official trailer');link.textContent='Find trailer on YouTube';link.title='YouTube search results; a direct trailer has not been verified.';}
  return link;
}
function movieDetails(movie){
  const details=document.createElement('details');details.className='movie-details';
  const summary=document.createElement('summary');summary.textContent='Movie details';details.append(summary);
  const info=movie.movieInfo||{};
  for(const [label,names] of [['Director',info.director],['Cast',info.cast]])if(Array.isArray(names)&&names.length){const p=document.createElement('p');p.textContent=label+': '+names.join(', ');details.append(p);}
  if(movie.intensityGuide){const p=document.createElement('p');p.className='intensity-guide';p.textContent='Intensity guide ('+(movie.screening||'editorial')+'): '+movie.intensityGuide;details.append(p);}
  if(info.provider==='Cinemeta'){
    const credit=document.createElement('p');credit.className='metadata-credit';
    credit.textContent='Movie details and any IMDb rating supplied by Cinemeta. ';
    if(Number.isInteger(info.fetchedEpoch))credit.append(document.createTextNode('Checked '+new Date(info.fetchedEpoch*1000).toLocaleDateString()+'. '));
    const source=document.createElement('a');source.href='https://v3-cinemeta.strem.io/meta/movie/'+movie.id+'.json';source.target='_blank';source.rel='noopener noreferrer';source.textContent='Metadata source';credit.append(source);details.append(credit);
  }else{const credit=document.createElement('p');credit.className='metadata-credit';credit.textContent='Additional metadata unavailable. Open IMDb for more movie information.';details.append(credit);}
  return details;
}
function render(data){
  if(!initialized){selected=new Set(data.finalized?.valid?data.finalized.ids:[]);initialized=true;}
  selected=new Set([...selected].filter(id=>(data.eligibleIds||[]).includes(id)));
  $('movies').replaceChildren();$('finalized-movies').replaceChildren();$('removed-movies').replaceChildren();
  const messages=['Filters: no Drama or Comedy, including mixed genres.'];
  if(!data.seenStateComplete)messages.push('Watched filtering: known exclusions only (Heretic and Companion). Complete watch-history access is not yet verified.');
  if(!data.actionsEnabled)messages.push('Downloads and stream checks are not activated.');
  if(data.shortlistFresh===false)messages.push('Weekly suggestions need refreshing. Your likes, dislikes and saved selections are retained.');
  else if(!data.movies.length)messages.push('No more reviewed suggestions match. Removed or seen movies will not be used as replacements.');
  else if(data.movies.length<5)messages.push('These are the remaining reviewed matches; no unrelated fallback was added.');
  say(messages.join(' '));
  for(const movie of data.movies){
    const card=document.createElement('article');card.className='movie-card';
    card.dataset.movie=movie.id;card.append(movieOverview(movie),fullSummary(movie),trailerLink(movie),movieDetails(movie));
    if(movie.similarToLiked&&movie.feedback!=='like'){const why=document.createElement('p');why.className='muted';why.textContent='Shares reviewed themes with movies you liked.';card.append(why);}
    if(data.reviewEnabled){
      const controls=document.createElement('div');controls.className='card-controls';
      const actions=document.createElement('div');actions.className='buttons';
      const like=document.createElement('button');like.textContent='Like';like.setAttribute('aria-pressed',String(movie.feedback==='like'));
      like.onclick=()=>reviewWrite('feedback',{imdb:movie.id,value:movie.feedback==='like'?'clear':'like'});
      const dislike=document.createElement('button');dislike.textContent='Dislike';dislike.onclick=()=>reviewWrite('feedback',{imdb:movie.id,value:'dislike'});
      actions.append(like,dislike);controls.append(actions);
      const label=document.createElement('label');label.className='pick';const check=document.createElement('input');check.type='checkbox';check.checked=selected.has(movie.id);check.setAttribute('aria-label','Select '+movie.name);
      check.onchange=()=>{if(check.checked&&selected.size>=4){check.checked=false;say('Choose at most 4 movies.');return;}if(check.checked)selected.add(movie.id);else selected.delete(movie.id);selectionCount();};
      label.append(check,document.createTextNode('Select'));controls.append(label);card.append(controls);
    }else card.append(watchButtons(movie,data.actionsEnabled));
    $('movies').append(card);
  }
  $('refill').hidden=!data.reviewEnabled;
  const refill=data.refillRequest||{};
  $('reserve-status').textContent=refill.discoveryEnabled ? `${data.reserveCount||0} replacements ready. Fresh metadata is searched when saved supplies run out; matches are not guaranteed.` : `${data.reserveCount||0} reviewed replacements ready. This is a finite reviewed pool; new movies are added after review, not discovered automatically.`;
  $('request-refill').disabled=refill.running || refill.retryAfter>0 || (!refill.discoveryEnabled && refill.pending && !refill.available);
  const outcomes={
    searching:'Finding new movies and checking your filters. This may take about 20 seconds. Downloads stay disabled.',
    'provider-unavailable':'The metadata provider is unavailable. Your choices are safe. Try Request more again in a minute.',
    'no-match':'No new eligible matches in this search batch. Your filters are unchanged. Try the next batch in a minute.',
    'state-changed':'Your shortlist changed during the search. Refresh, then request more again.',
    interrupted:'The last search was interrupted. Request more to retry.',
    refilled:`Added ${refill.added||0} matching movies. Downloads stay disabled.`
  };
  $('refill-status').textContent=refill.discoveryEnabled ? (outcomes[refill.outcome]||`${refill.available||0} saved replacements available. Request more also searches for new matches when needed.`) : refill.available ? `${refill.available} unused reviewed titles available. Request more adds up to five; this is a finite supply, not automatic discovery.` : refill.pending ? 'Refill requested. The reviewed supply is exhausted or unavailable; a fresh reviewed update is needed. Nothing is queued for download.' : 'Reviewed update loaded. No unused reviewed titles remain; another request will wait for a fresh reviewed update. Downloads stay disabled.';
  if(refillTimer)clearTimeout(refillTimer);
  if(refill.running||refill.retryAfter>0)refillTimer=setTimeout(load,refill.running?1200:Math.min(5000,refill.retryAfter*1000+100));
  $('selection').hidden=!data.reviewEnabled;
  const f=data.finalized||{ids:[],valid:false,movies:[]};$('finalized').hidden=!f.ids.length;
  $('finalized-status').textContent=f.valid?`${f.ids.length} movies finalized. Nothing has been queued.`:f.reason==='genre-filter'?'Your saved selections are retained, but a title is ineligible under your no Drama or Comedy filter. Choose eligible replacements.':f.reason==='shortlist-stale'?'Your saved selections are retained. Refresh the weekly suggestions before confirming eligibility.':'Your saved selections are retained but need review because eligibility or feedback changed. Finalize 3–4 eligible movies again.';
  for(const movie of f.movies){const card=document.createElement('article');card.className='movie-card';card.append(movieOverview(movie,'h3'),fullSummary(movie),trailerLink(movie),movieDetails(movie));if(f.valid)card.append(watchButtons(movie,data.actionsEnabled));$('finalized-movies').append(card);}
  $('removed').hidden=!(data.disliked||[]).length;
  for(const movie of data.disliked||[]){const p=document.createElement('p'),restore=document.createElement('button');p.append(document.createTextNode(movie.name+' '));restore.textContent='Restore suggestion';restore.onclick=()=>reviewWrite('feedback',{imdb:movie.id,value:'clear'});p.append(restore);$('removed-movies').append(p);}
  selectionCount();
}
$('request-refill').onclick=()=>reviewWrite('feedback',{action:'request-refill',requestId:crypto.randomUUID()});
$('finalize').onclick=()=>reviewWrite('finalize',{ids:[...selected]});
async function load(){
  if(reviewBusy){recoverRead();return;}
  stopRecovery();const generation=++loadGeneration;
  try{const data=await api('shortlist');if(generation===loadGeneration){recoveryAttempts=0;render(data);if(uncertainWrite){uncertainWrite=false;say('Connection recovered. Saved choices reloaded; check them before repeating your last action.');}}}
  catch(error){if(generation===loadGeneration)showFailure(error);}
}
window.addEventListener('pagehide',()=>{if(timer)clearTimeout(timer);if(refillTimer)clearTimeout(refillTimer);stopRecovery();});
window.addEventListener('focus',load);
window.addEventListener('online',()=>{recoveryAttempts=0;load();});
document.addEventListener('visibilitychange',()=>{if(!document.hidden)load();});
load();
