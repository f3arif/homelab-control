"""Genre preference must not become a requirement to repeat liked stories/themes."""
import unittest
from feedback import rank_reviewed
from movie_night import shortlist


def row(i, genres=('Thriller',), tags=()):
    return {'id':'tt'+str(12345+i),'name':'Fixture '+str(i),'year':2024,
            'genres':list(genres),'fitTags':list(tags),'scareLevel':'low',
            'intensityReviewed':True,'intenseSupernatural':False}


class GenreVariety(unittest.TestCase):
    def setUp(self):
        self.ratings={'tt99999':{'value':'like','metadata':{'genres':['Thriller','Crime','Drama'],'fitTags':['obsession','relationship tension','twists','suspense']}}}

    def ids(self, rows):
        return [r['id'] for r in rank_reviewed(rows,self.ratings,limit=len(rows))]

    def test_same_genre_without_theme_overlap_keeps_reviewed_priority(self):
        fresh=row(0,tags=[])
        similar=row(1,tags=['obsession','relationship tension','twists','suspense'])
        self.assertEqual([fresh['id'],similar['id']],self.ids([fresh,similar]))

    def test_extra_matching_genres_do_not_crowd_out_other_stories(self):
        one=row(0,['Thriller'])
        many=row(1,['Thriller','Crime','Drama'])
        self.assertEqual([one['id'],many['id']],self.ids([one,many]))

    def test_theme_changes_do_not_change_order(self):
        rows=[row(0),row(1,['Crime']),row(2,['Action'])]
        before=self.ids(rows)
        rows[1]['fitTags']=['obsession','relationship tension']
        self.ratings['tt99999']['metadata']['fitTags']=['relationship tension']
        self.assertEqual(before,self.ids(rows))

    def test_likes_and_core_genres_still_guide_without_excluding_others(self):
        other,match,liked=row(0,['Horror']),row(1),row(2,['Action'])
        self.ratings[liked['id']]={'value':'like','metadata':liked}
        self.assertEqual([liked['id'],match['id'],other['id']],self.ids([other,match,liked]))

    def test_incidental_drama_tag_does_not_become_a_preferred_core_genre(self):
        self.assertEqual(['tt12346','tt12345'],self.ids([row(0,['Drama','Horror']),row(1,['Crime'])]))

    def test_seen_disliked_and_limits_still_apply(self):
        rows=[row(i) for i in range(12)]
        self.ratings[rows[0]['id']]={'value':'seen','metadata':rows[0]}
        self.ratings[rows[1]['id']]={'value':'dislike','metadata':rows[1]}
        result=rank_reviewed(rows,self.ratings,limit=4)
        self.assertEqual([r['id'] for r in rows[2:6]],[r['id'] for r in result])
        self.assertTrue(all(r['similarToLiked'] is False for r in result))

    def test_genre_qualified_editorial_movie_needs_no_theme_tags(self):
        result=shortlist({'generatedEpoch':100,'movies':[row(0)]},100)
        self.assertEqual(1,len(result))
        self.assertIn('Matches your preferred genres: Thriller',result[0]['description'])

    def test_genre_match_does_not_bypass_existing_screening(self):
        for change in ({'genres':['Thriller','Comedy']},{'scareLevel':'high'},
                       {'intensityReviewed':False},{'intenseSupernatural':True},
                       {'seen':True},{'year':2015}):
            with self.subTest(change=change):
                candidate=dict(row(0),**change)
                self.assertEqual([],shortlist({'generatedEpoch':100,'movies':[candidate]},100))

    def test_no_genre_or_theme_match_is_not_newly_admitted(self):
        self.assertEqual([],shortlist({'generatedEpoch':100,'movies':[row(0,['Romance'])]},100))

    def test_legacy_editorial_theme_only_rows_are_preserved(self):
        candidate=row(0,genres=[],tags=['suspense'])
        self.assertEqual(1,len(shortlist({'generatedEpoch':100,'movies':[candidate]},100)))


if __name__=='__main__':unittest.main()
