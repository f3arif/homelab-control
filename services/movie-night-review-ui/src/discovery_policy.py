"""Conservative metadata screening, explicitly distinct from editorial intensity review."""
import re,time
from datetime import datetime,timezone
BASE='https://v3-cinemeta.strem.io'
from genre_settings import GENRES, DEFAULT_EXCLUDED, DEFAULT_INCLUDED, defaults, excluded_genres, genre_match, genres_of
# Compatibility names describe initial choices only; all runtime callers pass saved settings.
EXCLUDED_GENRES=DEFAULT_EXCLUDED
CORE_GENRES=set(DEFAULT_INCLUDED)|{'Mystery & Thriller','Science Fiction'}
ALLOWED_GENRES=set(GENRES)|{'Mystery & Thriller','Science Fiction','Animated','Anime','Cartoon','Sports'}
GUIDE='Automatically screened metadata only. Intensity is not reviewed: horror, creature attacks and strong violence may occur.'
def clean_text(value,maximum):
    return isinstance(value,str) and 1<=len(value)<=maximum and not any(ord(c)<32 for c in value)
def normalize(meta,now=None,genre_settings=None,*,unrestricted=False):
    now=int(time.time()) if now is None else int(now)
    if not isinstance(meta,dict):return None
    imdb=meta.get('id');year=meta.get('releaseInfo',meta.get('year'));genres=meta.get('genres');description=meta.get('description')
    if not isinstance(imdb,str) or not re.fullmatch(r'tt\d{5,12}',imdb) or meta.get('type')!='movie':return None
    if meta.get('imdb_id',imdb)!=imdb or not re.fullmatch(r'\d{4}',str(year)):return None
    if 'year' in meta and str(meta['year'])!=str(year):return None
    if not unrestricted and (meta.get('intenseSupernatural') is True or meta.get('scareLevel') in ('high','extreme')):return None
    year=int(year)
    minimum=1888 if unrestricted else 2016
    if not minimum<=year<=datetime.fromtimestamp(now,timezone.utc).year:return None
    if not isinstance(genres,list) or not 1<=len(genres)<=10 or any(not clean_text(g,40) for g in genres):return None
    # Keep every label, including provider aliases and genre links, to catch mixed genres.
    all_genres=list(genres)
    aliases=meta.get('genre',[])
    if not isinstance(aliases,list) or any(not clean_text(g,40) for g in aliases):return None
    all_genres+=aliases
    links=meta.get('links',[])
    if not isinstance(links,list):return None
    for link in links:
        if isinstance(link,dict) and str(link.get('category','')).lower()=='genres':all_genres.append(link.get('name',''))
    if any(not clean_text(g,40) or not genres_of({'genres':[g]}) for g in all_genres):return None
    genres=list(dict.fromkeys(all_genres))
    if len(genres)>10 or (not unrestricted and not genre_match(dict(meta,genres=genres),genre_settings)):return None
    if not clean_text(meta.get('name'),160) or not clean_text(description,3000):return None # horror themes allowed by owner
    try:
        released=datetime.fromisoformat(meta['released'].replace('Z','+00:00'))
        if released.tzinfo is None or released.year<minimum or released.timestamp()>now:return None
    except (KeyError,TypeError,ValueError,AttributeError):return None # e.g. released: null
    tags=['suspense']
    if set(genres)&{'Mystery','Mystery & Thriller'}:tags.append('twists')
    if re.search(r'\b(couple|wife|husband|marriage|partner|relationship|affair|lover)\b',description,re.I):tags.append('relationship tension')
    if re.search(r'\b(obsess\w*|stalk\w*)\b',description,re.I):tags.append('obsession')
    # Preserve the provider's synopsis, clipping only at sentence/word boundaries.
    synopsis=description if len(description)<=450 else description[:447].rsplit(' ',1)[0]+'…'
    evidence={'provider':'Cinemeta','fetchedEpoch':now,'id':imdb,'type':'movie','name':meta['name'],'releaseInfo':str(year),'released':meta['released'],'genres':genres,'description':description}
    if unrestricted:
        evidence['searchMode']='unfiltered'
        # Keep known content notes even though this explicit search does not filter them.
        if meta.get('scareLevel') in ('low','moderate','high','extreme','unknown'):evidence['scareLevel']=meta['scareLevel']
        if type(meta.get('intenseSupernatural')) is bool:evidence['intenseSupernatural']=meta['intenseSupernatural']
    return dict(id=imdb,name=meta['name'],year=year,genres=genres,synopsis=synopsis,fitTags=tags,
                scareLevel=evidence.get('scareLevel','unknown'),intensityReviewed=False,intenseSupernatural=evidence.get('intenseSupernatural'),intensityGuide=GUIDE,
                sources=[BASE+'/meta/movie/'+imdb+'.json'],trailer=None,discoveryEvidence=evidence)
def screened(row,now=None,genre_settings=None,*,unrestricted=False):
    e=row.get('discoveryEvidence')
    if not isinstance(e,dict) or e.get('provider')!='Cinemeta':return False
    now=int(time.time()) if now is None else int(now);fetched=e.get('fetchedEpoch')
    if type(fetched) is not int or not 0<=now-fetched<=30*86400:return False
    expected=normalize(e,fetched,genre_settings,unrestricted=unrestricted)
    # The guide text changed on 2026-10-21; older rows keep their stored guide.
    return bool(expected and all(row.get(k)==v for k,v in expected.items() if k!='intensityGuide'))
