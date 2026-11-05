"""'Find movies like' must follow the kind of movie, not one genre, a stray word or country."""
import unittest
from metadata_discovery import CinemetaDiscovery
from similar_movies import CinemetaSimilar,related_score,words
from test_similar_movies import movie

SEED=movie(0,name='Deep Water',releaseInfo='2026',genres=['Action','Drama','Horror'],country='Spain, New Zealand, United States, China',
 director=['Renny Harlin'],cast=['Aaron Eckhart','Ben Kingsley'],
 description='A group of international passengers en route from Los Angeles to Shanghai are forced to make an emergency landing in shark-infested waters. Now they must work together in hopes to overcome the frenzy of sharks drawn to the wreckage.')
SHARK=movie(1,name='Open Water',genres=['Drama','Horror'],country='United States',director=['Chris Kentis'],cast=['Blanchard Ryan'],
 description='Two divers are left out at sea without a boat, in shark-infested waters.')
TITLED=movie(2,name='Shark Bait',genres=['Horror'],country='United Kingdom',director=['James Nunn'],cast=['Holly Earl'],
 description='Friends steal a jet ski and are stranded far out in open water.')
NOISE=[movie(10,name='Heretic',genres=['Horror'],country='United States',director=['Scott Beck'],cast=['Hugh Grant'],description='Two young missionaries are drawn into a game of cat-and-mouse.'),
 movie(11,name='Good Luck',genres=['Action'],country='United States',director=['Gore Verbinski'],cast=['Sam Rockwell'],description='A man from the future recruits a diner in Los Angeles.'),
 movie(12,name='The Batman',genres=['Action'],country='United States',director=['Matt Reeves'],cast=['Robert Pattinson'],description='Batman is forced to investigate corruption.'),
 movie(13,name='Top Gun: Maverick',genres=['Action','Drama'],country='United States',director=['Joseph Kosinski'],cast=['Tom Cruise'],description='Maverick trains a group of graduates for a mission.')]
FILLER=[movie(100+i,name='Filler %d'%i,genres=['Action'],director=['D%d'%i],cast=['C%d'%i],description='A detective chases criminals through the city at night number %d.'%i) for i in range(40)]

def source(searches=None):
 searches=searches or {}
 def transport(path):
  if path.startswith('/meta/movie/'):
   return {'meta':next((m for m in [SEED,SHARK,TITLED]+NOISE+FILLER if m['id'] in path),None)}
  if '/search=' in path:
   for word,rows in searches.items():
    if '/search='+word+'.json' in path:return {'metas':rows}
   return {'metas':[]}
  return {'metas':[SHARK]+NOISE+FILLER}
 return CinemetaSimilar(CinemetaDiscovery(transport))

class SimilarRelevanceTests(unittest.TestCase):
 def test_single_genre_stray_word_or_country_never_carries_a_match(self):
  for noise in NOISE[:3]:
   with self.subTest(noise=noise['name']):self.assertEqual((0,[]),related_score(SEED,noise,{},60))
  # Most genres in common is only a labelled, last-place fallback.
  score,reasons=related_score(SEED,NOISE[3],{},60)
  self.assertIn('Genre match only',reasons[-1]);self.assertLess(score,1)
  self.assertGreater(related_score(SEED,SHARK,{},60)[0],3)
 def test_place_names_and_plot_verbs_are_not_story_words(self):
  found=words(SEED)
  for w in ['angele','angeles','shanghai','forced','drawn','group']:self.assertNotIn(w,found)
  self.assertIn('shark',found);self.assertIn('wreckage',found)
 def test_deep_water_returns_shark_survival_before_noise(self):
  thin=dict(id=TITLED['id'],name=TITLED['name'],type='movie',releaseInfo='2022')
  result=source({'shark':[thin]}).find(SEED['id'])
  names=[r['name'] for r in result['rows']]
  self.assertEqual('Open Water',names[0]);self.assertIn('Shark Bait',names)
  for noise in NOISE[:3]:self.assertNotIn(noise['name'],names)
  self.assertLess(names.index('Shark Bait'),names.index('Top Gun: Maverick') if 'Top Gun: Maverick' in names else 99)
  self.assertTrue(any('shark' in r for r in result['reasons'][SHARK['id']]))
 def test_story_word_search_uses_seed_concepts(self):
  calls=[]
  base=source()
  orig=base.metadata.transport
  def spy(path):calls.append(path);return orig(path)
  base.metadata.transport=spy
  base.find(SEED['id'])
  self.assertIn('/catalog/movie/top/search=shark.json',calls)
  self.assertFalse(any('/search=angele' in c or '/search=forced' in c for c in calls))

if __name__=='__main__':unittest.main()
