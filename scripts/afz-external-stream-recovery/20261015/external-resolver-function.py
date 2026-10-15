def _external_resolved_url(vid,token):
    if not re.fullmatch(r'tt\d+(?::\d+:\d+)?',str(vid or '')):
        raise HTTPException(404,'Unknown video')
    if not re.fullmatch(r'[a-f0-9]{20,64}',str(token or '')):
        raise HTTPException(404,'Unknown external stream')
    key=str(vid)+'|'+str(token)
    def cached_url():
        with resolved_stream_lock:
            hit=dict(external_resolved_cache.get(key) or {})
        if (hit and time.time()-float(hit.get('ts') or 0)<RESOLVED_STREAM_TTL
                and re.match(r'^https?://',str(hit.get('url') or ''),re.I)):
            return str(hit['url'])
        return ''
    # Serialize retries for the same original link; a successful recovery is
    # shared by subsequent requests from the player's alternate engine.
    with _external_history.gate(vid,token):
        rows_fn=series_external_source_rows if parse_series_video_id(vid) else external_source_rows
        # Snapshot history before discovery can replace the cached rows.
        original=_external_history.get(vid,token)
        rows=rows_fn(vid)
        _external_history.remember(vid,rows)
        current=next((x for x in rows if str(x.get('token') or '')==str(token)),None)
        original=current or original
        is_series=bool(parse_series_video_id(vid))
        if parse_series_video_id(vid) and original is None:
            raise HTTPException(404,'Episode source does not match; refresh the stream list')
        def resolve(row_token,row):
            resolver_id=str((row or {}).get('resolverVideoId') or vid)
            qtok=requests.utils.quote(str(row_token),safe='')
            qimdb=requests.utils.quote(resolver_id,safe='')
            return h3_order_call('GET',f'/external-resolve?token={qtok}&imdb={qimdb}',4 if FAILOVER_MODE else 20)
        hit=cached_url()
        with resolved_stream_lock:
            verified=bool((external_resolved_cache.get(key) or {}).get('verifiedSource'))
        if hit and (not is_series or current or (original and verified)):
            return hit
        refreshed=False
        resolve_token=token
        if is_series and current is None:
            # A historical token must pass today's identity filters before
            # either a cached legacy URL or a bridge token can be trusted.
            fresh=rows_fn(vid,force=True)
            _external_history.remember(vid,fresh)
            replacement=_same_external_file(original,fresh)
            if replacement is None:
                raise HTTPException(404,'Episode source does not match; refresh the stream list')
            resolve_token=replacement['token']
            original=replacement
            refreshed=True
        data=resolve(resolve_token,original)
        url=str(data.get('url') or '') if isinstance(data,dict) and data.get('ok') else ''
        # A bridge restart or 30-minute token eviction must not permanently
        # invalidate catalog links. Refresh once, keeping the exact file and
        # using the normal movie/episode identity filters before matching.
        if not re.match(r'^https?://',url,re.I) and int((data or {}).get('statusCode') or 0)==404 and original and not refreshed:
            fresh=rows_fn(vid,force=True)
            _external_history.remember(vid,fresh)
            replacement=_same_external_file(original,fresh)
            if replacement:
                data=resolve(replacement['token'],replacement)
                url=str(data.get('url') or '') if isinstance(data,dict) and data.get('ok') else ''
        if not re.match(r'^https?://',url,re.I):
            status=int((data or {}).get('statusCode') or 0)
            if status in (0,409,429,500,502,503,504):
                raise HTTPException(503,'Stream source is temporarily unavailable; retry shortly')
            raise HTTPException(404,'External stream expired; refresh the Stremio stream list')
        with resolved_stream_lock:
            external_resolved_cache[key]={'ts':time.time(),'url':url,'verifiedSource':True}
        return url
