"""Accept explicitly reviewed official trailers; never construct video URLs."""
from urllib.parse import urlsplit, parse_qs
import re
HOSTS={'www.infinitychamber.com','www.miramax.com','www.apple.com','www.netflix.com','mubi.com','www.officialsecrets.movie','www.youtube.com','skydance.com','protege.movie','app.powster.com','www.lionsgate.com','www.bleeckerstreetmedia.com'}
def reviewed_trailer(value, imdb):
    if not isinstance(value,dict) or value.get('verifiedOfficial') is not True or value.get('movieId')!=imdb:return None
    url=value.get('url');publisher=value.get('publisher')
    if not isinstance(url,str) or not isinstance(publisher,str) or not 1<=len(publisher)<=80:return None
    try:
        u=urlsplit(url)
        if u.scheme!='https' or u.hostname not in HOSTS or u.username or u.password or u.port or u.fragment or any(ord(c)<33 for c in url):return None
        if u.hostname=='www.youtube.com' and (u.path!='/watch' or not re.fullmatch(r'[A-Za-z0-9_-]{11}',parse_qs(u.query).get('v',[''])[0]) or set(parse_qs(u.query))!={'v'}):return None
        return {'url':url,'publisher':publisher}
    except ValueError:return None
