"""Conservative metadata screening, explicitly distinct from editorial intensity review."""
import re,time
from datetime import datetime,timezone
BASE='https://v3-cinemeta.strem.io'
BLOCK=re.compile(r'\b(?:comed(?:y|ies)|dramed(?:y|ies))\b',re.I)
# Owner choice 2026-10-21: thrillers, horror, creature/monster adventure, crime, action, sci-fi; Drama tag allowed; no Comedy.
CORE_GENRES={'Thriller','Mystery','Mystery & Thriller','Crime','Action','Sci-Fi','Science Fiction','Adventure','Horror'}
SCARY=re.compile(r'\b(?:horror|supernatural|paranormal|demon\w*|ghosts?|haunt\w*|possess\w*|exorcis\w*|zombies?|vampires?|monsters?|gore|gory|tortur\w*|sadist\w*|serial killer|ritual\w*|fright\w*|terrify\w*|nightmar\w*|slasher|occult|cannibal\w*)\b',re.I)
# Independent evidence overrides incomplete provider labels. Never relabel a conflict.
VETO={
 'tt31195136':'https://en.wikipedia.org/wiki/Normal_(2025_film)',
 'tt27165187':'https://www.rottentomatoes.com/m/the_end_of_oak_street',
 # Previously researched mixed-genre exclusions must not be rediscovered.
 **{i:'https://www.imdb.com/title/'+i+'/' for i in (
 'tt14060094','tt8356942','tt6146586','tt7737528','tt7181546','tt7556122',
 'tt1634106','tt4693358','tt4196776','tt3640424','tt7456310','tt10183816',
 'tt8080204','tt1590193','tt1458169','tt11827628','tt5761544')}
}
ALLOWED_GENRES={'Drama','Horror','Fantasy','Action','Adventure','Animation','Biography','Crime','Documentary','Family','History','Music','Musical','Mystery','Mystery & Thriller','Romance','Sci-Fi','Science Fiction','Sport','Thriller','War','Western'}
GUIDE='Automatically screened metadata only. Intensity is not reviewed: horror, creature attacks and strong violence may occur.'
def clean_text(value,maximum):
    return isinstance(value,str) and 1<=len(value)<=maximum and not any(ord(c)<32 for c in value)
def normalize(meta,now=None):
    now=int(time.time()) if now is None else int(now)
    if not isinstance(meta,dict):return None
    imdb=meta.get('id');year=meta.get('releaseInfo',meta.get('year'));genres=meta.get('genres');description=meta.get('description')
    if not isinstance(imdb,str) or not re.fullmatch(r'tt\d{5,12}',imdb) or imdb in VETO or meta.get('type')!='movie':return None
    if meta.get('imdb_id',imdb)!=imdb or not re.fullmatch(r'\d{4}',str(year)):return None
    if 'year' in meta and str(meta['year'])!=str(year):return None
    if meta.get('intenseSupernatural') is True or meta.get('scareLevel') in ('high','extreme'):return None
    year=int(year)
    if not 2016<=year<=datetime.fromtimestamp(now,timezone.utc).year:return None
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
    if any(not clean_text(g,40) or BLOCK.search(g) or g not in ALLOWED_GENRES for g in all_genres):return None
    genres=list(dict.fromkeys(all_genres))
    if len(genres)>10 or not set(genres)&CORE_GENRES:return None
    if not clean_text(meta.get('name'),160) or not clean_text(description,3000):return None # horror themes allowed by owner
    try:
        released=datetime.fromisoformat(meta['released'].replace('Z','+00:00'))
        if released.tzinfo is None or released.year<2016 or released.timestamp()>now:return None
    except (KeyError,TypeError,ValueError,AttributeError):return None # e.g. released: null
    tags=['suspense']
    if set(genres)&{'Mystery','Mystery & Thriller'}:tags.append('twists')
    if re.search(r'\b(couple|wife|husband|marriage|partner|relationship|affair|lover)\b',description,re.I):tags.append('relationship tension')
    if re.search(r'\b(obsess\w*|stalk\w*)\b',description,re.I):tags.append('obsession')
    # Preserve the provider's synopsis, clipping only at sentence/word boundaries.
    synopsis=description if len(description)<=450 else description[:447].rsplit(' ',1)[0]+'…'
    evidence={'provider':'Cinemeta','fetchedEpoch':now,'id':imdb,'type':'movie','name':meta['name'],'releaseInfo':str(year),'released':meta['released'],'genres':genres,'description':description}
    return dict(id=imdb,name=meta['name'],year=year,genres=genres,synopsis=synopsis,fitTags=tags,
                scareLevel='unknown',intensityReviewed=False,intenseSupernatural=None,intensityGuide=GUIDE,
                sources=[BASE+'/meta/movie/'+imdb+'.json'],trailer=None,discoveryEvidence=evidence)
def screened(row,now=None):
    e=row.get('discoveryEvidence')
    if not isinstance(e,dict) or e.get('provider')!='Cinemeta':return False
    now=int(time.time()) if now is None else int(now);fetched=e.get('fetchedEpoch')
    if type(fetched) is not int or not 0<=now-fetched<=30*86400:return False
    expected=normalize(e,fetched)
    # The guide text changed on 2026-10-21; older rows keep their stored guide.
    return bool(expected and all(row.get(k)==v for k,v in expected.items() if k!='intensityGuide'))
