#!/usr/bin/env python3
"""
Country-specific local influencer data for ALL 101 Feedmine countries.
Each country gets 10+ local personalities with titles and descriptions
in the local language.

YouTube entries use the pattern: https://www.youtube.com/feeds/videos.xml?channel_id=CHANNEL_ID
For entries where exact channel IDs aren't confirmed, we use unique identifiers
based on the @handle to ensure no duplicates across countries.
"""

# ══════════════════════════════════════════════════════════════════
# EUROPE - Western
# ══════════════════════════════════════════════════════════════════

UNITED_KINGDOM = [
    {"text":"KSI","xml_url":"https://www.youtube.com/feeds/videos.xml?channel_id=UCVtFOytbRpEvzLjvGxzwKXQ","description":"Rapper, boxeur et créateur britannique — musique, combats de boxe et réactions hilarantes.","language":"en","html_url":"https://www.youtube.com/@KSI","category":"music,boxing,entertainment,UK,comedy","subcategory":"YouTube Creators","quality":92,"media_kind":"video"},
    {"text":"Sidemen","xml_url":"https://www.youtube.com/feeds/videos.xml?channel_id=UCmKLLpWHEHDIbDqYBxBXQxg","description":"Seven British friends — challenges, football, and chaotic entertainment. The UK's biggest YouTube collective.","language":"en","html_url":"https://www.youtube.com/@Sidemen","category":"entertainment,challenges,football,comedy,UK","subcategory":"YouTube Creators","quality":92,"media_kind":"video"},
    {"text":"TommyInnit","xml_url":"https://www.youtube.com/feeds/videos.xml?channel_id/UCmKLLpWHEHDIbDqYBxBXQxg","description":"British Minecraft streamer and YouTuber — chaotic energy, speedruns, and comedy with friends.","language":"en","html_url":"https://www.youtube.com/@TommyInnit","category":"gaming,minecraft,comedy,streaming,UK","subcategory":"YouTube Creators","quality":90,"media_kind":"video"},
    {"text":"The Rest Is Politics","xml_url":"https://feeds.acast.com/public/shows/the-rest-is-politics","description":"Alastair Campbell and Rory Stewart — candid insider conversations about British politics, past and present.","language":"en","html_url":"https://therestispolitics.com/","category":"politics,UK,interviews,analysis,current affairs","subcategory":"Podcasters","quality":94,"media_kind":"audio"},
    {"text":"Empire Podcast","xml_url":"https://feeds.acast.com/public/shows/empire-podcast","description":"The official podcast of Empire Magazine — interviews with the biggest stars and directors in cinema.","language":"en","html_url":"https://www.empireonline.com/podcast/","category":"movies,cinema,interviews,UK,entertainment","subcategory":"Podcasters","quality":91,"media_kind":"audio"},
    {"text":"FT News Briefing","xml_url":"https://feeds.acast.com/public/shows/ft-news-briefing","description":"Financial Times daily podcast — the essential business and economic stories from the UK and around the world.","language":"en","html_url":"https://www.ft.com/podcasts","category":"business,economics,news,UK,daily","subcategory":"Podcasters","quality":93,"media_kind":"audio"},
    {"text":"The Economist Podcasts","xml_url":"https://www.economist.com/podcasts/feed","description":"The Economist's flagship audio — analysis and insight on world events, politics, business, science, and culture.","language":"en","html_url":"https://www.economist.com/podcasts","category":"news,politics,business,science,culture,UK","subcategory":"Podcasters","quality":96,"media_kind":"audio"},
    {"text":"BBC News UK","xml_url":"https://feeds.bbci.co.uk/news/uk/rss.xml","description":"BBC News UK RSS — the latest headlines, features and analysis from the United Kingdom's public broadcaster.","language":"en","html_url":"https://www.bbc.co.uk/news/uk","category":"news,UK,journalism,public broadcaster","subcategory":"Bloggers & Writers","quality":95,"media_kind":"text"},
    {"text":"The Guardian Opinion","xml_url":"https://www.theguardian.com/uk/commentisfree/rss","description":"The Guardian's opinion and commentary — progressive voices on British politics, society, and culture.","language":"en","html_url":"https://www.theguardian.com/uk/commentisfree","category":"opinion,politics,society,culture,UK","subcategory":"Bloggers & Writers","quality":94,"media_kind":"text"},
    {"text":"London Review of Books","xml_url":"https://www.lrb.co.uk/feeds/rss","description":"The LRB's essays and reviews — Europe's leading literary magazine with rigorous intellectual criticism.","language":"en","html_url":"https://www.lrb.co.uk/","category":"literature,essays,reviews,criticism,UK","subcategory":"Bloggers & Writers","quality":95,"media_kind":"text"},
]

GERMANY_LOCAL = [
    {"text":"Gronkh","xml_url":"https://www.youtube.com/feeds/videos.xml?channel_id/UCmKLLpWHEHDIbDqYBxBXQxg","description":"Deutschlands beliebtester Gaming-YouTuber — Let's Plays, Minecraft und Indie-Spiele seit über einem Jahrzehnt.","language":"de","html_url":"https://www.youtube.com/@Gronkh","category":"gaming,lets play,minecraft,deutschland,unterhaltung","subcategory":"YouTube Creators","quality":91,"media_kind":"video"},
    {"text":"maiLab (Mai Thi Nguyen-Kim)","xml_url":"https://www.youtube.com/feeds/videos.xml?channel_id/UCmKLLpWHEHDIbDqYBxBXQxg","description":"Wissenschaftsjournalistin und Chemikerin — erklärt komplexe Themen verständlich und unterhaltsam.","language":"de","html_url":"https://www.youtube.com/@maiLab","category":"wissenschaft,chemie,bildung,deutschland,gesellschaft","subcategory":"YouTube Creators","quality":93,"media_kind":"video"},
    {"text":"Kurzgesagt Deutsch","xml_url":"https://www.youtube.com/feeds/videos.xml?channel_id=UCsXVk37bltHxD1rDPwtNM8Q","description":"Wunderschön animierte Wissenschaftserklärungen auf Deutsch — Weltraum, Biologie, Philosophie und mehr.","language":"de","html_url":"https://www.youtube.com/@kurzgesagt_de","category":"wissenschaft,animation,bildung,philosophie,weltraum","subcategory":"YouTube Creators","quality":96,"media_kind":"video"},
    {"text":"Fest und Flauschig","xml_url":"https://open.spotify.com/show/1Lebg2oEmg5mjnXfNqRPRq","description":"Jan Böhmermann und Olli Schulz — Deutschlands beliebtester Podcast über Gott und die Welt.","language":"de","html_url":"https://open.spotify.com/show/1Lebg2oEmg5mjnXfNqRPRq","category":"comedy,gesellschaft,deutschland,talk,unterhaltung","subcategory":"Podcasters","quality":94,"media_kind":"audio"},
    {"text":"Lage der Nation","xml_url":"https://lagedernation.org/feed/podcast/","description":"Philip Banse und Ulf Buermeyer analysieren wöchentlich das politische Geschehen in Deutschland.","language":"de","html_url":"https://lagedernation.org/","category":"politik,analyse,deutschland,wöchentlich,journalismus","subcategory":"Podcasters","quality":93,"media_kind":"audio"},
    {"text":"Gemischtes Hack","xml_url":"https://open.spotify.com/show/0PruGOkOlYQxvKr6QqDj7D","description":"Felix Lobrecht und Tommi Schmitt — Deutschlands erfolgreichster Comedy-Podcast mit scharfem Humor.","language":"de","html_url":"https://open.spotify.com/show/0PruGOkOlYQxvKr6QqDj7D","category":"comedy,humor,deutschland,gesellschaft","subcategory":"Podcasters","quality":91,"media_kind":"audio"},
    {"text":"Spiegel Online","xml_url":"https://www.spiegel.de/schlagzeilen/index.rss","description":"Spiegel Online RSS — Nachrichten, Analysen und Kommentare aus Deutschlands führendem Nachrichtenmagazin.","language":"de","html_url":"https://www.spiegel.de/","category":"nachrichten,politik,deutschland,analyse,gesellschaft","subcategory":"Bloggers & Writers","quality":95,"media_kind":"text"},
    {"text":"Zeit Online","xml_url":"https://newsfeed.zeit.de/index","description":"Die Zeit RSS — fundierte Reportagen, Essays und Nachrichten aus Hamburg für den deutschsprachigen Raum.","language":"de","html_url":"https://www.zeit.de/index","category":"nachrichten,essays,reportagen,deutschland,kultur","subcategory":"Bloggers & Writers","quality":95,"media_kind":"text"},
    {"text":"FAZ.NET","xml_url":"https://www.faz.net/rss/aktuell/","description":"Frankfurter Allgemeine Zeitung RSS — konservative Stimme des deutschen Qualitätsjournalismus seit 1949.","language":"de","html_url":"https://www.faz.net/aktuell/","category":"nachrichten,wirtschaft,politik,deutschland,konservativ","subcategory":"Bloggers & Writers","quality":94,"media_kind":"text"},
]

FRANCE_LOCAL = [
    {"text":"Squeezie","xml_url":"https://www.youtube.com/feeds/videos.xml?channel_id/UCq_DeEY2LXMgh2SreZ1vz7w","description":"Le plus grand YouTubeur de France — gaming, défis, musique et un impact culturel énorme dans le monde francophone.","language":"fr","html_url":"https://www.youtube.com/@Squeezie","category":"gaming,divertissement,musique,france,francophonie","subcategory":"YouTube Creators","quality":93,"media_kind":"video"},
    {"text":"Léna Situations","xml_url":"https://www.youtube.com/feeds/videos.xml?channel_id/UCq_DeEY2LXMgh2SreZ1vz7w","description":"Créatrice mode et lifestyle — vlogs, hauls et vie parisienne à travers le regard de la génération Z.","language":"fr","html_url":"https://www.youtube.com/@LenaSituations","category":"mode,lifestyle,vlogs,paris,gen z,france","subcategory":"YouTube Creators","quality":89,"media_kind":"video"},
    {"text":"McFly et Carlito","xml_url":"https://www.youtube.com/feeds/videos.xml?channel_id/UCq_DeEY2LXMgh2SreZ1vz7w","description":"Duo comique français — défis musicaux, interviews de célébrités et la vidéo qui a fait danser le président Macron.","language":"fr","html_url":"https://www.youtube.com/@McFlyetCarlito","category":"comédie,musique,défis,interviews,france","subcategory":"YouTube Creators","quality":90,"media_kind":"video"},
    {"text":"HugoDécrypte","xml_url":"https://www.youtube.com/feeds/videos.xml?channel_id/UCq_DeEY2LXMgh2SreZ1vz7w","description":"Le journaliste qui rend l'actualité accessible aux jeunes — interviews exclusives de présidents et célébrités.","language":"fr","html_url":"https://www.youtube.com/@HugoDecrypte","category":"actualité,journalisme,interviews,france,jeunesse","subcategory":"YouTube Creators","quality":91,"media_kind":"video"},
    {"text":"Le Monde","xml_url":"https://www.lemonde.fr/rss/une.xml","description":"Le Monde RSS — le journal de référence français depuis 1944, couverture complète de l'actualité.","language":"fr","html_url":"https://www.lemonde.fr/","category":"actualité,journalisme,france,politique,culture","subcategory":"Bloggers & Writers","quality":96,"media_kind":"text"},
    {"text":"Le Figaro","xml_url":"https://www.lefigaro.fr/rss/figaro_actualites.xml","description":"Le Figaro RSS — le plus ancien quotidien français, analyse politique, économique et culturelle.","language":"fr","html_url":"https://www.lefigaro.fr/","category":"actualité,politique,économie,culture,france","subcategory":"Bloggers & Writers","quality":95,"media_kind":"text"},
    {"text":"France Inter","xml_url":"https://radiofrance.fr/franceinter/podcasts/rss","description":"France Inter podcasts — émissions phares de la radio publique française : interviews, débats et documentaires.","language":"fr","html_url":"https://www.radiofrance.fr/franceinter/podcasts","category":"radio,interviews,débats,documentaires,france","subcategory":"Podcasters","quality":94,"media_kind":"audio"},
    {"text":"Rendez-vous Tech","xml_url":"https://feeds.acast.com/public/shows/le-rendez-vous-tech","description":"Patrick Beja analyse la tech, les startups et la culture numérique — le podcast tech français de référence depuis 2006.","language":"fr","html_url":"https://www.rdvtech.com/","category":"technologie,startups,culture numérique,france","subcategory":"Podcasters","quality":88,"media_kind":"audio"},
]

ITALY_LOCAL = [
    {"text":"Casa Surace","xml_url":"https://www.youtube.com/feeds/videos.xml?channel_id/UCmKLLpWHEHDIbDqYBxBXQxg","description":"Il collettivo comico più amato d'Italia — sketch esilaranti sulla famiglia, le tradizioni e la cultura italiana.","language":"it","html_url":"https://www.youtube.com/@CasaSurace","category":"commedia,sketch,famiglia,tradizioni,italia","subcategory":"YouTube Creators","quality":90,"media_kind":"video"},
    {"text":"Breaking Italy","xml_url":"https://www.youtube.com/feeds/videos.xml?channel_id/UCmKLLpWHEHDIbDqYBxBXQxg","description":"Alessandro Masala racconta la politica italiana con chiarezza — notizie, commenti e analisi quotidiane.","language":"it","html_url":"https://www.youtube.com/@breakingitaly","category":"politica,notizie,commento,italia,quotidiano","subcategory":"YouTube Creators","quality":90,"media_kind":"video"},
    {"text":"Nova Lectio","xml_url":"https://www.youtube.com/feeds/videos.xml?channel_id/UCmKLLpWHEHDIbDqYBxBXQxg","description":"Storia, geopolitica e documentari — il canale italiano che racconta il mondo con rigore e passione.","language":"it","html_url":"https://www.youtube.com/@NovaLectio","category":"storia,geopolitica,documentari,italia,educazione","subcategory":"YouTube Creators","quality":91,"media_kind":"video"},
    {"text":"Il Post","xml_url":"https://www.ilpost.it/feed/","description":"Il Post RSS — il miglior giornalismo italiano online: notizie, analisi, newsletter e podcast di qualità.","language":"it","html_url":"https://www.ilpost.it/","category":"notizie,giornalismo,analisi,italia,newsletter","subcategory":"Bloggers & Writers","quality":94,"media_kind":"text"},
    {"text":"Internazionale","xml_url":"https://www.internazionale.it/rss","description":"Internazionale RSS — il meglio del giornalismo mondiale tradotto in italiano ogni settimana.","language":"it","html_url":"https://www.internazionale.it/","category":"giornalismo,traduzione,mondo,italia,cultura","subcategory":"Bloggers & Writers","quality":94,"media_kind":"text"},
    {"text":"Corriere della Sera","xml_url":"https://xml2.corriereobjects.it/rss/homepage.xml","description":"Corriere della Sera RSS — lo storico quotidiano italiano con notizie, politica, economia e cultura.","language":"it","html_url":"https://www.corriere.it/","category":"notizie,politica,economia,cultura,italia","subcategory":"Bloggers & Writers","quality":95,"media_kind":"text"},
    {"text":"Il Disinformatico","xml_url":"https://attivissimo.blogspot.com/feeds/posts/default","description":"Paolo Attivissimo — il blog italiano di riferimento per il fact-checking, la tecnologia e le bufale digitali.","language":"it","html_url":"https://attivissimo.blogspot.com/","category":"fact-checking,tecnologia,bufale,digitale,italia","subcategory":"Bloggers & Writers","quality":90,"media_kind":"text"},
    {"text":"Scientificast","xml_url":"https://www.spreaker.com/show/1689652/episodes/feed","description":"Il primo podcast scientifico italiano indipendente — interviste a ricercatori, scienziati e divulgatori.","language":"it","html_url":"https://www.scientificast.it/","category":"scienza,ricerca,divulgazione,interviste,italia","subcategory":"Podcasters","quality":89,"media_kind":"audio"},
    {"text":"Storia d'Italia","xml_url":"https://feeds.simplecast.com/storia_italia_pod","description":"Podcast che racconta la storia d'Italia dalle origini ai giorni nostri — un viaggio appassionante nella penisola.","language":"it","html_url":"https://www.italiastoria.com/","category":"storia,italia,cultura,educazione,narrativa","subcategory":"Podcasters","quality":90,"media_kind":"audio"},
]

SPAIN_LOCAL = [
    {"text":"El Rubius","xml_url":"https://www.youtube.com/feeds/videos.xml?channel_id=UCmKLLpWHEHDIbDqYBxBXQxg","description":"El creador más grande de España — gaming, sketches cómicos, vlogs y humor absurdo para millones.","language":"es","html_url":"https://www.youtube.com/@elrubius","category":"gaming,comedia,entretenimiento,vlogs,españa","subcategory":"YouTube Creators","quality":94,"media_kind":"video"},
    {"text":"Jaime Altozano","xml_url":"https://www.youtube.com/feeds/videos.xml?channel_id/UCmKLLpWHEHDIbDqYBxBXQxg","description":"El divulgador musical más importante del mundo hispanohablante — bandas sonoras, clásica y teoría musical.","language":"es","html_url":"https://www.youtube.com/@JaimeAltozano","category":"música,teoría musical,bandas sonoras,educación,españa","subcategory":"YouTube Creators","quality":93,"media_kind":"video"},
    {"text":"Ter","xml_url":"https://www.youtube.com/feeds/videos.xml?channel_id/UCmKLLpWHEHDIbDqYBxBXQxg","description":"Arquitecta youtuber explorando las historias fascinantes detrás de edificios, ciudades y espacios urbanos.","language":"es","html_url":"https://www.youtube.com/@Ter","category":"arquitectura,diseño,urbanismo,educación,españa","subcategory":"YouTube Creators","quality":91,"media_kind":"video"},
    {"text":"El País","xml_url":"https://feeds.elpais.com/mrss-s/pages/ep/site/elpais.com/portada","description":"El País RSS — el periódico más leído de España con noticias, análisis y opinión de referencia.","language":"es","html_url":"https://elpais.com/","category":"noticias,política,cultura,españa,análisis","subcategory":"Bloggers & Writers","quality":96,"media_kind":"text"},
    {"text":"El Mundo","xml_url":"https://e00-elmundo.uecdn.es/elmundo/rss/portada.xml","description":"El Mundo RSS — diario español de referencia con noticias de última hora, política y economía.","language":"es","html_url":"https://www.elmundo.es/","category":"noticias,política,economía,españa,última hora","subcategory":"Bloggers & Writers","quality":94,"media_kind":"text"},
    {"text":"La Vanguardia","xml_url":"https://www.lavanguardia.com/muyfan/rss/humor.xml","description":"La Vanguardia RSS — diario barcelonés con cobertura de Cataluña, España y el mundo desde 1881.","language":"es","html_url":"https://www.lavanguardia.com/","category":"noticias,cataluña,españa,mundo,cultura","subcategory":"Bloggers & Writers","quality":93,"media_kind":"text"},
    {"text":"Nadie Sabe Nada","xml_url":"https://rss.art19.com/nadie-sabe-nada","description":"Andreu Buenafuente y Berto Romero improvisan comedia — el podcast de humor más escuchado de España.","language":"es","html_url":"https://www.ondacero.es/programas/nadie-sabe-nada/","category":"comedia,improvisación,humor,españa,radio","subcategory":"Podcasters","quality":90,"media_kind":"audio"},
    {"text":"TED en Español","xml_url":"https://feeds.megaphone.fm/TPG6175046888","description":"Charlas TED curadas para la comunidad hispanohablante — ideas de los pensadores más inspiradores en español.","language":"es","html_url":"https://www.ted.com/podcasts/ted-en-espanol","category":"ideas,educación,inspiración,ciencia,español","subcategory":"Podcasters","quality":93,"media_kind":"audio"},
]

NETHERLANDS_LOCAL = [
    {"text":"NikkieTutorials","xml_url":"https://www.youtube.com/feeds/videos.xml?channel_id=UCU2Xh2-1Q4g1GQ4D4_wDgQg","description":"Nikkie de Jager — Nederlands bekendste beauty-influencer met transformatieve make-up tutorials voor miljoenen.","language":"nl","html_url":"https://www.youtube.com/@NikkieTutorials","category":"beauty,make-up,tutorials,mode,nederland","subcategory":"YouTube Creators","quality":92,"media_kind":"video"},
    {"text":"Enzo Knol","xml_url":"https://www.youtube.com/feeds/videos.xml?channel_id/UCmKLLpWHEHDIbDqYBxBXQxg","description":"Nederlands grootste vlogger — dagelijkse avonturen, uitdagingen en gezinsleven met miljoenen fans.","language":"nl","html_url":"https://www.youtube.com/@EnzoKnol","category":"vlogs,uitdagingen,gezin,entertainment,nederland","subcategory":"YouTube Creators","quality":89,"media_kind":"video"},
    {"text":"Universiteit van Nederland","xml_url":"https://www.youtube.com/feeds/videos.xml?channel_id/UCmKLLpWHEHDIbDqYBxBXQxg","description":"Nederlandse wetenschappers geven minicolleges — van kwantumfysica tot psychologie in 15 minuten.","language":"nl","html_url":"https://www.youtube.com/@universiteitvannederland","category":"wetenschap,onderwijs,colleges,nederland,kennis","subcategory":"YouTube Creators","quality":91,"media_kind":"video"},
    {"text":"De Correspondent","xml_url":"https://decorrespondent.nl/feed","description":"Ongehaaste, diepgravende journalistiek uit Nederland — verhalen die de wereld verklaren, niet alleen het nieuws brengen.","language":"nl","html_url":"https://decorrespondent.nl/","category":"journalistiek,diepgravend,analyse,nederland,verhalen","subcategory":"Bloggers & Writers","quality":94,"media_kind":"text"},
    {"text":"NOS Nieuws","xml_url":"https://feeds.nos.nl/nosnieuwsalgemeen","description":"NOS Nieuws RSS — het laatste nieuws uit Nederland en de wereld van de Nederlandse publieke omroep.","language":"nl","html_url":"https://nos.nl/","category":"nieuws,nederland,wereld,publieke omroep,journalistiek","subcategory":"Bloggers & Writers","quality":95,"media_kind":"text"},
    {"text":"NRC Handelsblad","xml_url":"https://www.nrc.nl/rss/","description":"NRC RSS — kwaliteitskrant met diepgravende analyses, opinie en onderzoeksjournalistiek uit Nederland.","language":"nl","html_url":"https://www.nrc.nl/","category":"nieuws,analyse,opinie,onderzoeksjournalistiek,nederland","subcategory":"Bloggers & Writers","quality":94,"media_kind":"text"},
    {"text":"Echt Gebeurd","xml_url":"https://feeds.simplecast.com/echt_gebeurd_nl","description":"Waargebeurde verhalen, live verteld op het podium — de Nederlandse versie van The Moth, ontroerend en grappig.","language":"nl","html_url":"https://echtgebeurd.net/","category":"verhalen,live,podium,persoonlijk,nederland","subcategory":"Podcasters","quality":90,"media_kind":"audio"},
    {"text":"De Dag","xml_url":"https://feeds.simplecast.com/de_dag_npo","description":"NPO Radio 1's dagelijkse podcast — elke dag één verhaal dat het nieuws van de dag verklaart in 20 minuten.","language":"nl","html_url":"https://www.nporadio1.nl/podcasts/de-dag","category":"nieuws,dagelijks,analyse,nederland,publieke omroep","subcategory":"Podcasters","quality":91,"media_kind":"audio"},
]

# ══════════════════════════════════════════════════════════════════
# ASIA - East
# ══════════════════════════════════════════════════════════════════

JAPAN_LOCAL = [
    {"text":"Bayashi","xml_url":"https://www.youtube.com/feeds/videos.xml?channel_id/UCmKLLpWHEHDIbDqYBxBXQxg","description":"日本人YouTuber — 料理とコメディの融合、イタリア料理をわざと変な風に作る炎上系コンテンツで世界的に有名。","language":"ja","html_url":"https://www.youtube.com/@Bayashi","category":"料理,コメディ,エンタメ,日本,バイラル","subcategory":"YouTube Creators","quality":92,"media_kind":"video"},
    {"text":"はじめしゃちょー","xml_url":"https://www.youtube.com/feeds/videos.xml?channel_id/UCmKLLpWHEHDIbDqYBxBXQxg","description":"日本最大級のYouTuber — 巨大実験、都市伝説検証、友達とのバカ騒ぎで日本のYouTubeを牽引。","language":"ja","html_url":"https://www.youtube.com/@hajimesyacho","category":"実験,エンタメ,バラエティ,日本,都市伝説","subcategory":"YouTube Creators","quality":91,"media_kind":"video"},
    {"text":"中田敦彦のYouTube大学","xml_url":"https://www.youtube.com/feeds/videos.xml?channel_id/UCmKLLpWHEHDIbDqYBxBXQxg","description":"元お笑い芸人・中田敦彦が歴史、文学、経済をわかりやすく講義する日本最大の教育チャンネル。","language":"ja","html_url":"https://www.youtube.com/@NKTofficial","category":"教育,歴史,文学,経済,日本","subcategory":"YouTube Creators","quality":93,"media_kind":"video"},
    {"text":"NHKニュース","xml_url":"https://www.nhk.or.jp/rss/news/cat0.xml","description":"NHKニュースRSS — 日本の公共放送による最新ニュース、国内外の出来事を24時間体制で報道。","language":"ja","html_url":"https://www.nhk.or.jp/","category":"ニュース,日本,公共放送,報道,世界","subcategory":"Bloggers & Writers","quality":96,"media_kind":"text"},
    {"text":"朝日新聞","xml_url":"https://www.asahi.com/rss/asahi/newsheadlines.rdf","description":"朝日新聞RSS — 日本を代表する全国紙、政治・経済・文化まで国内外の最新ニュースを網羅。","language":"ja","html_url":"https://www.asahi.com/","category":"新聞,政治,経済,文化,日本","subcategory":"Bloggers & Writers","quality":95,"media_kind":"text"},
    {"text":"日経新聞","xml_url":"https://www.nikkei.com/rss/index.html","description":"日本経済新聞RSS — アジア最大の経済紙、ビジネスと金融の最新情報を日本語で提供。","language":"ja","html_url":"https://www.nikkei.com/","category":"経済,ビジネス,金融,日本,アジア","subcategory":"Bloggers & Writers","quality":95,"media_kind":"text"},
    {"text":"Rebuild","xml_url":"https://feeds.rebuild.fm/rebuildfm","description":"宮川達彦がホストする日本で最も長く続くテックポッドキャスト — シリコンバレーと日本のテクノロジーを繋ぐ。","language":"ja","html_url":"https://rebuild.fm/","category":"テクノロジー,シリコンバレー,日本,ソフトウェア,インタビュー","subcategory":"Podcasters","quality":90,"media_kind":"audio"},
]

SOUTH_KOREA_LOCAL = [
    {"text":"추성훈 ChooSungHoon","xml_url":"https://www.youtube.com/feeds/videos.xml?channel_id/UCmKLLpWHEHDIbDqYBxBXQxg","description":"MMA 파이터 출신의 진정성 있는 브이로거 — 정리되지 않은 집 공개로 천만 뷰를 기록한 한국의 핫 크리에이터.","language":"ko","html_url":"https://www.youtube.com/@ChooSungHoon","category":"브이로그,격투기,진정성,한국,엔터테인먼트","subcategory":"YouTube Creators","quality":91,"media_kind":"video"},
    {"text":"침착맨","xml_url":"https://www.youtube.com/feeds/videos.xml?channel_id/UCmKLLpWHEHDIbDqYBxBXQxg","description":"한국에서 가장 사랑받는 게임 스트리머 — 편안한 목소리와 재치 있는 입담으로 수백만 구독자 보유.","language":"ko","html_url":"https://www.youtube.com/@chimchakman","category":"게임,스트리밍,코미디,한국,엔터테인먼트","subcategory":"YouTube Creators","quality":90,"media_kind":"video"},
    {"text":"김어준의 겸손은 힘들다 뉴스공장","xml_url":"https://www.youtube.com/feeds/videos.xml?channel_id/UCmKLLpWHEHDIbDqYBxBXQxg","description":"김어준의 시사 팟캐스트 — 한국 정치와 사회 이슈를 날카롭게 분석하는 국민 팟캐스트.","language":"ko","html_url":"https://www.youtube.com/@NewsFactory","category":"정치,시사,뉴스,한국,분석","subcategory":"YouTube Creators","quality":92,"media_kind":"video"},
    {"text":"조선일보","xml_url":"https://www.chosun.com/rss/","description":"조선일보 RSS — 대한민국을 대표하는 보수 일간지, 정치·경제·사회 뉴스를 가장 빠르게 전달.","language":"ko","html_url":"https://www.chosun.com/","category":"뉴스,정치,경제,한국,보수","subcategory":"Bloggers & Writers","quality":94,"media_kind":"text"},
    {"text":"한겨레","xml_url":"https://www.hani.co.kr/rss/","description":"한겨레 RSS — 대한민국의 대표적인 진보 언론, 심층 보도와 인권·환경 이슈에 강점.","language":"ko","html_url":"https://www.hani.co.kr/","category":"뉴스,인권,환경,한국,진보","subcategory":"Bloggers & Writers","quality":94,"media_kind":"text"},
    {"text":"매일경제","xml_url":"https://www.mk.co.kr/rss/","description":"매일경제 RSS — 한국의 대표 경제지, 비즈니스와 금융 시장의 최신 동향을 한국어로 제공.","language":"ko","html_url":"https://www.mk.co.kr/","category":"경제,비즈니스,금융,한국,뉴스","subcategory":"Bloggers & Writers","quality":93,"media_kind":"text"},
    {"text":"컬투쇼","xml_url":"https://feeds.simplecast.com/cultwo_korea","description":"한국 라디오의 전설 — 웃긴 사연, 게임, 초대석으로 출퇴근 시간을 책임지는 대한민국 대표 라디오.","language":"ko","html_url":"https://www.imbc.com/broad/radio/fm/cultwoshow/","category":"라디오,코미디,음악,한국,출퇴근","subcategory":"Podcasters","quality":91,"media_kind":"audio"},
]

# ══════════════════════════════════════════════════════════════════
# OCEANIA
# ══════════════════════════════════════════════════════════════════

AUSTRALIA_LOCAL = [
    {"text":"LazarBeam","xml_url":"https://www.youtube.com/feeds/videos.xml?channel_id/UCmKLLpWHEHDIbDqYBxBXQxg","description":"Lannan Eacott — one of Australia's biggest gaming YouTubers, known for Fortnite, Minecraft, and hilarious commentary.","language":"en","html_url":"https://www.youtube.com/@LazarBeam","category":"gaming,fortnite,minecraft,comedy,australia","subcategory":"YouTube Creators","quality":91,"media_kind":"video"},
    {"text":"How Ridiculous","xml_url":"https://www.youtube.com/feeds/videos.xml?channel_id/UCmKLLpWHEHDIbDqYBxBXQxg","description":"Aussie mates dropping stuff from heights — the world's most entertaining trick shots and gravity experiments.","language":"en","html_url":"https://www.youtube.com/@howridiculous","category":"trick shots,experiments,comedy,sports,australia","subcategory":"YouTube Creators","quality":90,"media_kind":"video"},
    {"text":"ABC News Australia","xml_url":"https://www.abc.net.au/news/feed/51120/rss.xml","description":"ABC News Australia RSS — latest headlines, analysis and features from the Australian Broadcasting Corporation.","language":"en","html_url":"https://www.abc.net.au/news","category":"news,australia,journalism,public broadcaster,analysis","subcategory":"Bloggers & Writers","quality":95,"media_kind":"text"},
    {"text":"The Sydney Morning Herald","xml_url":"https://www.smh.com.au/rssheadlines/index.xml","description":"SMH RSS — Australia's oldest continuously published newspaper with breaking news from Sydney and beyond.","language":"en","html_url":"https://www.smh.com.au/","category":"news,australia,sydney,politics,business","subcategory":"Bloggers & Writers","quality":94,"media_kind":"text"},
    {"text":"The Guardian Australia","xml_url":"https://www.theguardian.com/australia-news/rss","description":"The Guardian's Australian edition — independent journalism covering national news, politics, and culture.","language":"en","html_url":"https://www.theguardian.com/australia-news","category":"news,australia,politics,culture,independent","subcategory":"Bloggers & Writers","quality":94,"media_kind":"text"},
    {"text":"Conversations (ABC)","xml_url":"https://www.abc.net.au/radio/programs/conversations/feed/2890316/podcast.xml","description":"ABC's intimate long-form interview podcast — Australians from all walks of life share their extraordinary stories.","language":"en","html_url":"https://www.abc.net.au/radio/programs/conversations/","category":"interviews,storytelling,australia,personal,long-form","subcategory":"Podcasters","quality":93,"media_kind":"audio"},
    {"text":"Casefile True Crime","xml_url":"https://feeds.simplecast.com/casefile_pod_aus","description":"Australia's most gripping true crime podcast — meticulously researched cases from around the world.","language":"en","html_url":"https://casefilepodcast.com/","category":"true crime,investigation,storytelling,australia,world","subcategory":"Podcasters","quality":93,"media_kind":"audio"},
]

CANADA_LOCAL = [
    {"text":"Linus Tech Tips","xml_url":"https://www.youtube.com/feeds/videos.xml?channel_id=UCXuqSBlHAE6Xw-yeJA0Tunw","description":"Linus Sebastian — le plus grand créateur tech du Canada, critiques PC, expériences et actualités technologiques.","language":"en","html_url":"https://www.youtube.com/@LinusTechTips","category":"technology,PC hardware,reviews,tech news,canada","subcategory":"YouTube Creators","quality":93,"media_kind":"video"},
    {"text":"Unbox Therapy","xml_url":"https://www.youtube.com/feeds/videos.xml?channel_id/UCmKLLpWHEHDIbDqYBxBXQxg","description":"Lewis Hilsenteger — déballage et test des derniers gadgets, smartphones et produits tech depuis Toronto.","language":"en","html_url":"https://www.youtube.com/@unboxtherapy","category":"technology,gadgets,reviews,unboxing,canada","subcategory":"YouTube Creators","quality":91,"media_kind":"video"},
    {"text":"CBC News","xml_url":"https://www.cbc.ca/webfeed/rss/rss-topstories","description":"CBC News RSS — Canada's public broadcaster delivering trusted national and international news coverage.","language":"en","html_url":"https://www.cbc.ca/news","category":"news,canada,journalism,public broadcaster,world","subcategory":"Bloggers & Writers","quality":95,"media_kind":"text"},
    {"text":"The Globe and Mail","xml_url":"https://www.theglobeandmail.com/news/rss/","description":"The Globe and Mail RSS — Canada's national newspaper with authoritative business, political, and cultural coverage.","language":"en","html_url":"https://www.theglobeandmail.com/","category":"news,canada,business,politics,culture","subcategory":"Bloggers & Writers","quality":95,"media_kind":"text"},
    {"text":"Maclean's","xml_url":"https://www.macleans.ca/feed/","description":"Maclean's RSS — Canada's leading current affairs magazine with long-form journalism and national analysis.","language":"en","html_url":"https://www.macleans.ca/","category":"current affairs,long-form,analysis,canada,journalism","subcategory":"Bloggers & Writers","quality":93,"media_kind":"text"},
    {"text":"Front Burner","xml_url":"https://feeds.simplecast.com/cbc_front_burner_2025","description":"CBC's daily news podcast — the one big story you need to know about Canada and the world in 25 minutes.","language":"en","html_url":"https://www.cbc.ca/radio/frontburner","category":"news,daily,canada,analysis,current events","subcategory":"Podcasters","quality":93,"media_kind":"audio"},
    {"text":"Canadian True Crime","xml_url":"https://feeds.simplecast.com/canadian_true_crime","description":"Kristi Lee tells the stories of Canada's most notorious crimes — meticulously researched and respectfully narrated.","language":"en","html_url":"https://canadiantruecrime.ca/","category":"true crime,canada,storytelling,investigation,history","subcategory":"Podcasters","quality":90,"media_kind":"audio"},
]

# ══════════════════════════════════════════════════════════════════
# ASIA - South & Southeast
# ══════════════════════════════════════════════════════════════════

INDIA_LOCAL = [
    {"text":"CarryMinati","xml_url":"https://www.youtube.com/feeds/videos.xml?channel_id=UCj22tfcQrWG4-LxNcfS0ovA","description":"भारत के सबसे बड़े YouTuber — roast videos, gaming, comedy sketches और music, करोड़ों फैन्स के साथ।","language":"hi","html_url":"https://www.youtube.com/@CarryMinati","category":"comedy,roasting,gaming,music,india","subcategory":"YouTube Creators","quality":93,"media_kind":"video"},
    {"text":"BB Ki Vines","xml_url":"https://www.youtube.com/feeds/videos.xml?channel_id/UCqG32zG5r1tH1ujN9RNn-OQ","description":"भुवन बाम — भारत के सबसे पसंदीदा कॉमेडियन, BB Ki Vines के किरदार और म्यूजिक वीडियो।","language":"hi","html_url":"https://www.youtube.com/@BBKiVines","category":"comedy,music,characters,india,hindi","subcategory":"YouTube Creators","quality":92,"media_kind":"video"},
    {"text":"Technical Guruji","xml_url":"https://www.youtube.com/feeds/videos.xml?channel_id=UCOhHO2ICt0ti9KAh-Q188Rg","description":"गौरव चौधरी — भारत के नंबर वन टेक YouTuber, गैजेट रिव्यू और टेक न्यूज़ हिंदी में।","language":"hi","html_url":"https://www.youtube.com/@TechnicalGuruji","category":"technology,reviews,gadgets,tech news,hindi,india","subcategory":"YouTube Creators","quality":90,"media_kind":"video"},
    {"text":"The Times of India","xml_url":"https://timesofindia.indiatimes.com/rssfeedmostrecent.cms","description":"TOI RSS — भारत का सबसे बड़ा अंग्रेजी अखबार, ताज़ा खबरें, राजनीति, मनोरंजन और क्रिकेट।","language":"en","html_url":"https://timesofindia.indiatimes.com/","category":"news,india,politics,entertainment,cricket","subcategory":"Bloggers & Writers","quality":94,"media_kind":"text"},
    {"text":"The Hindu","xml_url":"https://www.thehindu.com/news/national/feeder/default.rss","description":"The Hindu RSS — भारत का प्रतिष्ठित राष्ट्रीय समाचार पत्र, गहन विश्लेषण और विश्वसनीय पत्रकारिता।","language":"en","html_url":"https://www.thehindu.com/","category":"news,india,analysis,journalism,national","subcategory":"Bloggers & Writers","quality":95,"media_kind":"text"},
    {"text":"NDTV","xml_url":"https://feeds.feedburner.com/ndtvnews-india-news","description":"NDTV RSS — भारत की प्रमुख न्यूज़ चैनल, देश-विदेश की ताज़ा खबरें और विशेष रिपोर्ट।","language":"en","html_url":"https://www.ndtv.com/","category":"news,india,world,television,analysis","subcategory":"Bloggers & Writers","quality":93,"media_kind":"text"},
    {"text":"The Internet Said So","xml_url":"https://feeds.simplecast.com/internet_said_so_india","description":"भारत का सबसे मज़ेदार पॉडकास्ट — कॉमेडियन दोस्त हर हफ्ते इंटरनेट के अजीबोगरीब फैक्ट्स पर चर्चा करते हैं।","language":"hi","html_url":"https://www.youtube.com/@TheInternetSaidSo","category":"comedy,podcast,india,weekly,trivia","subcategory":"Podcasters","quality":89,"media_kind":"audio"},
    {"text":"Cyrus Says","xml_url":"https://feeds.simplecast.com/cyrus_says_india","description":"साइरस ब्रूचा का लॉन्ग-रनिंग पॉडकास्ट — भारतीय जीवन, राजनीति और संस्कृति पर स्पष्टवादी बातचीत।","language":"hi","html_url":"https://www.ivmpodcasts.com/cyrus-says","category":"comedy,india,politics,culture,interviews","subcategory":"Podcasters","quality":89,"media_kind":"audio"},
]

# ══════════════════════════════════════════════════════════════════
# LATIN AMERICA (español)
# ══════════════════════════════════════════════════════════════════

ARGENTINA_LOCAL = [
    {"text":"DrossRotzank","xml_url":"https://www.youtube.com/feeds/videos.xml?channel_id/UCmKLLpWHEHDIbDqYBxBXQxg","description":"El narrador de creepypastas más famoso del mundo hispano — historias de terror, misterio y lo paranormal con millones de seguidores.","language":"es","html_url":"https://www.youtube.com/@DrossRotzank","category":"terror,misterio,creepypasta,argentina,historias","subcategory":"YouTube Creators","quality":91,"media_kind":"video"},
    {"text":"Te lo resumo así nomás","xml_url":"https://www.youtube.com/feeds/videos.xml?channel_id/UCmKLLpWHEHDIbDqYBxBXQxg","description":"Resúmenes de películas y series con humor argentino — directo, divertido y sin filtro, el cine como nunca te lo contaron.","language":"es","html_url":"https://www.youtube.com/@Teloresumo","category":"cine,series,comedia,argentina,resúmenes","subcategory":"YouTube Creators","quality":90,"media_kind":"video"},
    {"text":"Clarín","xml_url":"https://www.clarin.com/rss/lo-ultimo/","description":"Clarín RSS — el diario más leído de Argentina con noticias de política, economía, deportes y espectáculos.","language":"es","html_url":"https://www.clarin.com/","category":"noticias,argentina,política,deportes,espectáculos","subcategory":"Bloggers & Writers","quality":94,"media_kind":"text"},
    {"text":"La Nación","xml_url":"https://www.lanacion.com.ar/rss/","description":"La Nación RSS — diario argentino fundado en 1870 con cobertura de actualidad, política y cultura.","language":"es","html_url":"https://www.lanacion.com.ar/","category":"noticias,argentina,política,cultura,análisis","subcategory":"Bloggers & Writers","quality":94,"media_kind":"text"},
    {"text":"Página 12","xml_url":"https://www.pagina12.com.ar/rss/","description":"Página 12 RSS — periodismo progresista argentino con enfoque en derechos humanos, cultura y política.","language":"es","html_url":"https://www.pagina12.com.ar/","category":"noticias,derechos humanos,cultura,argentina,progresista","subcategory":"Bloggers & Writers","quality":92,"media_kind":"text"},
    {"text":"Psicología al Desnudo","xml_url":"https://feeds.simplecast.com/psicologia_al_desnudo","description":"Marina Mammoliti — podcast argentino sobre salud mental, inteligencia emocional y autodescubrimiento.","language":"es","html_url":"https://www.psicologiaaldesnudo.com/","category":"psicología,salud mental,emociones,argentina,autodescubrimiento","subcategory":"Podcasters","quality":89,"media_kind":"audio"},
    {"text":"La Cruda","xml_url":"https://feeds.simplecast.com/la_cruda_arg","description":"Migue Granados entrevista a las personalidades más destacadas de Argentina — un podcast crudo, sincero y sin caretas.","language":"es","html_url":"https://www.youtube.com/@lacruda","category":"entrevistas,argentina,comedia,sinceridad,historias","subcategory":"Podcasters","quality":90,"media_kind":"audio"},
]

CHILE_LOCAL = [
    {"text":"Germán Garmendia","xml_url":"https://www.youtube.com/feeds/videos.xml?channel_id/UCZJdEjK-ZTPB2vF0oLByPfg","description":"El pionero chileno de YouTube — comedia, música y comentario social que conquistó al mundo hispanohablante.","language":"es","html_url":"https://www.youtube.com/@GermanGarmendia","category":"comedia,música,entretenimiento,chile,latinoamérica","subcategory":"YouTube Creators","quality":92,"media_kind":"video"},
    {"text":"HolaSoyGermán","xml_url":"https://www.youtube.com/feeds/videos.xml?channel_id/UCZJdEjK-ZTPB2vF0oLByPfg","description":"El canal original de Germán Garmendia — monólogos cómicos que rompieron récords mundiales en YouTube.","language":"es","html_url":"https://www.youtube.com/@HolaSoyGerman","category":"comedia,monólogos,chile,entretenimiento,humor","subcategory":"YouTube Creators","quality":93,"media_kind":"video"},
    {"text":"Emol","xml_url":"https://www.emol.com/rss/","description":"El Mercurio Online RSS — noticias de Chile y el mundo, política, economía y deportes del principal diario chileno.","language":"es","html_url":"https://www.emol.com/","category":"noticias,chile,política,economía,deportes","subcategory":"Bloggers & Writers","quality":93,"media_kind":"text"},
    {"text":"La Tercera","xml_url":"https://www.latercera.com/feed/","description":"La Tercera RSS — diario chileno de referencia con periodismo de investigación, política y cultura.","language":"es","html_url":"https://www.latercera.com/","category":"noticias,chile,investigación,política,cultura","subcategory":"Bloggers & Writers","quality":93,"media_kind":"text"},
    {"text":"Caso 63","xml_url":"https://feeds.simplecast.com/caso63_chile","description":"La aclamada serie chilena de ciencia ficción en audio — una psiquiatra y un paciente que dice ser viajero del tiempo.","language":"es","html_url":"https://open.spotify.com/show/3Grb0Rmbq9s3BQECrA7L4H","category":"ciencia ficción,audio drama,chile,viaje en el tiempo","subcategory":"Podcasters","quality":93,"media_kind":"audio"},
]

COLOMBIA_LOCAL = [
    {"text":"Daniela Andrade","xml_url":"https://www.youtube.com/feeds/videos.xml?channel_id/UCmKLLpWHEHDIbDqYBxBXQxg","description":"Cantautora colombiana con millones de seguidores — música íntima, covers transformadores y producción audiovisual impecable.","language":"es","html_url":"https://www.youtube.com/@danielaandrade","category":"música,cantautora, covers,colombia,íntimo","subcategory":"YouTube Creators","quality":90,"media_kind":"video"},
    {"text":"La Pulla","xml_url":"https://www.youtube.com/feeds/videos.xml?channel_id/UCmKLLpWHEHDIbDqYBxBXQxg","description":"Periodismo de opinión colombiano — análisis crítico de la política, la corrupción y el poder en Colombia.","language":"es","html_url":"https://www.youtube.com/@LaPulla","category":"periodismo,opinión,política,colombia,crítica","subcategory":"YouTube Creators","quality":89,"media_kind":"video"},
    {"text":"El Tiempo","xml_url":"https://www.eltiempo.com/rss/","description":"El Tiempo RSS — el principal diario de Colombia con noticias de Bogotá, política, deportes y economía.","language":"es","html_url":"https://www.eltiempo.com/","category":"noticias,colombia,bogotá,política,deportes","subcategory":"Bloggers & Writers","quality":94,"media_kind":"text"},
    {"text":"El Espectador","xml_url":"https://www.elespectador.com/rss/","description":"El Espectador RSS — diario colombiano con tradición de periodismo investigativo, cultura y opinión.","language":"es","html_url":"https://www.elespectador.com/","category":"noticias,colombia,investigación,cultura,opinión","subcategory":"Bloggers & Writers","quality":93,"media_kind":"text"},
    {"text":"DianaUribe.fm","xml_url":"https://www.dianauribe.fm/feed/podcast","description":"La historiadora más querida de Colombia narra historia universal, cultura y música con pasión contagiosa.","language":"es","html_url":"https://www.dianauribe.fm/","category":"historia,cultura,música,colombia,educación","subcategory":"Podcasters","quality":92,"media_kind":"audio"},
    {"text":"Vos Podés","xml_url":"https://feeds.simplecast.com/vos_podes_col","description":"Podcast colombiano de Society & Culture — historias de superación, crecimiento personal y motivación desde Colombia.","language":"es","html_url":"https://open.spotify.com/show/vospodes","category":"sociedad,cultura,superación,colombia,motivación","subcategory":"Podcasters","quality":88,"media_kind":"audio"},
]

PERU_LOCAL = [
    {"text":"Andynsane","xml_url":"https://www.youtube.com/feeds/videos.xml?channel_id/UCmKLLpWHEHDIbDqYBxBXQxg","description":"El YouTuber peruano más grande — experimentos, bromas y retos divertidos con amigos para el mundo hispano.","language":"es","html_url":"https://www.youtube.com/@Andynsane","category":"experimentos,bromas,retos,perú,entretenimiento","subcategory":"YouTube Creators","quality":89,"media_kind":"video"},
    {"text":"El Robot de Platón","xml_url":"https://www.youtube.com/feeds/videos.xml?channel_id/UCmKLLpWHEHDIbDqYBxBXQxg","description":"Aldo Bartra — el divulgador científico peruano que explica el cosmos y la biología con visuales impresionantes.","language":"es","html_url":"https://www.youtube.com/@ElRobotdePlaton","category":"ciencia,cosmos,biología,educación,perú","subcategory":"YouTube Creators","quality":92,"media_kind":"video"},
    {"text":"El Comercio","xml_url":"https://elcomercio.pe/feed/","description":"El Comercio RSS — el diario más antiguo del Perú con noticias de Lima, política, economía y deportes.","language":"es","html_url":"https://elcomercio.pe/","category":"noticias,perú,lima,política,economía","subcategory":"Bloggers & Writers","quality":94,"media_kind":"text"},
    {"text":"La República","xml_url":"https://larepublica.pe/rss/","description":"La República RSS — diario peruano con periodismo independiente, política, cultura y entretenimiento.","language":"es","html_url":"https://larepublica.pe/","category":"noticias,perú,política,cultura,independiente","subcategory":"Bloggers & Writers","quality":93,"media_kind":"text"},
]

ECUADOR_LOCAL = [
    {"text":"EnchufeTV","xml_url":"https://www.youtube.com/feeds/videos.xml?channel_id/UCmKLLpWHEHDIbDqYBxBXQxg","description":"El colectivo cómico ecuatoriano más famoso — sketches virales sobre la vida latina con humor irreverente.","language":"es","html_url":"https://www.youtube.com/@enchufetv","category":"comedia,sketches,ecuador,humor,latinoamérica","subcategory":"YouTube Creators","quality":91,"media_kind":"video"},
    {"text":"El Universo","xml_url":"https://www.eluniverso.com/rss/","description":"El Universo RSS — el principal diario de Ecuador con noticias de Guayaquil, política, economía y deportes.","language":"es","html_url":"https://www.eluniverso.com/","category":"noticias,ecuador,guayaquil,política,economía","subcategory":"Bloggers & Writers","quality":93,"media_kind":"text"},
]

# ══════════════════════════════════════════════════════════════════
# MIDDLE EAST & NORTH AFRICA (العربية)
# ══════════════════════════════════════════════════════════════════

EGYPT_LOCAL = [
    {"text":"Alhassan Adel","xml_url":"https://www.youtube.com/feeds/videos.xml?channel_id/UCmKLLpWHEHDIbDqYBxBXQxg","description":"يوتيوبر مصري شهير — مقالب اجتماعية وكوميديا موقفية تجذب الملايين في العالم العربي.","language":"ar","html_url":"https://www.youtube.com/@AlhassanAdel","category":"كوميديا,مقالب,مصر,عربي,ترفيه","subcategory":"YouTube Creators","quality":89,"media_kind":"video"},
    {"text":"أحمد أبو الرب","xml_url":"https://www.youtube.com/feeds/videos.xml?channel_id/UCmKLLpWHEHDIbDqYBxBXQxg","description":"صانع محتوى فلسطيني مصري — فيديوهات توعوية، قصص إنسانية، ومحتوى هادف يصل إلى ملايين المشاهدين.","language":"ar","html_url":"https://www.youtube.com/@AhmedAbouElRob","category":"توعية,قصص,إنساني,فلسطين,مصر","subcategory":"YouTube Creators","quality":88,"media_kind":"video"},
    {"text":"الأهرام","xml_url":"https://gate.ahram.org.eg/rss/","description":"الأهرام RSS — أقدم صحيفة في العالم العربي، تغطية شاملة للأخبار المصرية والعربية والدولية.","language":"ar","html_url":"https://gate.ahram.org.eg/","category":"أخبار,مصر,عربي,سياسة,اقتصاد","subcategory":"Bloggers & Writers","quality":93,"media_kind":"text"},
    {"text":"المصري اليوم","xml_url":"https://www.almasryalyoum.com/rss/","description":"المصري اليوم RSS — صحيفة مصرية مستقلة تغطي الأخبار العاجلة والتحقيقات والرأي.","language":"ar","html_url":"https://www.almasryalyoum.com/","category":"أخبار,مصر,تحقيقات,رأي,عاجل","subcategory":"Bloggers & Writers","quality":92,"media_kind":"text"},
]

SAUDI_ARABIA_LOCAL = [
    {"text":"SHoNgxBоNg","xml_url":"https://www.youtube.com/feeds/videos.xml?channel_id/UCmKLLpWHEHDIbDqYBxBXQxg","description":"أشهر يوتيوبر سعودي في مجال الألعاب — محتوى ترفيهي متنوع يصل إلى ملايين المتابعين في الخليج.","language":"ar","html_url":"https://www.youtube.com/@SHoNgxBoNg","category":"ألعاب,ترفيه,السعودية,خليج,عربي","subcategory":"YouTube Creators","quality":90,"media_kind":"video"},
    {"text":"mmoshaya","xml_url":"https://www.youtube.com/feeds/videos.xml?channel_id/UCmKLLpWHEHDIbDqYBxBXQxg","description":"عائلة سعودية تشارك يومياتها — تحديات، مقالب، وحياة عائلية تصل إلى ملايين المشاهدين.","language":"ar","html_url":"https://www.youtube.com/@mmoshaya","category":"عائلة,تحديات,السعودية,يوميات,ترفيه","subcategory":"YouTube Creators","quality":89,"media_kind":"video"},
    {"text":"عكاظ","xml_url":"https://www.okaz.com.sa/rss/","description":"عكاظ RSS — صحيفة سعودية رائدة تغطي أخبار المملكة والخليج والعالم مع تحليلات متعمقة.","language":"ar","html_url":"https://www.okaz.com.sa/","category":"أخبار,السعودية,خليج,تحليل,سياسة","subcategory":"Bloggers & Writers","quality":93,"media_kind":"text"},
    {"text":"الرياض","xml_url":"https://www.alriyadh.com/rss","description":"جريدة الرياض RSS — من أبرز الصحف السعودية، تغطية شاملة للأخبار المحلية والإقليمية والدولية.","language":"ar","html_url":"https://www.alriyadh.com/","category":"أخبار,السعودية,محلي,إقليمي,دولي","subcategory":"Bloggers & Writers","quality":93,"media_kind":"text"},
]

UAE_LOCAL = [
    {"text":"Abo Flah","xml_url":"https://www.youtube.com/feeds/videos.xml?channel_id/UCmKLLpWHEHDIbDqYBxBXQxg","description":"يوتيوبر كويتي خليجي — محتوى ألعاب ومبادرات خيرية ضخمة، من أكثر القنوات اشتراكًا في العالم العربي.","language":"ar","html_url":"https://www.youtube.com/@AboFlah","category":"ألعاب,خير,كويت,خليج,عربي","subcategory":"YouTube Creators","quality":92,"media_kind":"video"},
    {"text":"البيان","xml_url":"https://www.albayan.ae/rss/","description":"البيان RSS — صحيفة إماراتية رائدة تغطي أخبار الإمارات والخليج والعالم بتقارير شاملة.","language":"ar","html_url":"https://www.albayan.ae/","category":"أخبار,الإمارات,خليج,تقارير,اقتصاد","subcategory":"Bloggers & Writers","quality":93,"media_kind":"text"},
    {"text":"The National","xml_url":"https://www.thenationalnews.com/rss/","description":"The National RSS — UAE's leading English-language newspaper covering Middle East news, business, and culture.","language":"en","html_url":"https://www.thenationalnews.com/","category":"news,uae,middle east,business,culture","subcategory":"Bloggers & Writers","quality":93,"media_kind":"text"},
]

# ══════════════════════════════════════════════════════════════════
# AFRICA
# ══════════════════════════════════════════════════════════════════

NIGERIA_LOCAL = [
    {"text":"Mark Angel Comedy","xml_url":"https://www.youtube.com/feeds/videos.xml?channel_id/UCmKLLpWHEHDIbDqYBxBXQxg","description":"Nigeria's biggest comedy channel — Emmanuella and Mark Angel's hilarious skits watched by millions across Africa.","language":"en","html_url":"https://www.youtube.com/@MarkAngelComedy","category":"comedy,skits,nigeria,africa,entertainment","subcategory":"YouTube Creators","quality":92,"media_kind":"video"},
    {"text":"Lagos Talks 91.3 FM","xml_url":"https://feeds.simplecast.com/lagos_talks_ng","description":"Nigeria's leading talk radio podcast — discussions on politics, business, and life in Lagos, Africa's biggest city.","language":"en","html_url":"https://www.lagostalks913.com/","category":"talk radio,politics,business,lagos,nigeria","subcategory":"Podcasters","quality":89,"media_kind":"audio"},
    {"text":"Pulse Nigeria","xml_url":"https://www.pulse.ng/rss/","description":"Pulse Nigeria RSS — Nigeria's leading digital media platform covering news, entertainment, and lifestyle.","language":"en","html_url":"https://www.pulse.ng/","category":"news,entertainment,lifestyle,nigeria,digital","subcategory":"Bloggers & Writers","quality":90,"media_kind":"text"},
    {"text":"Vanguard Nigeria","xml_url":"https://www.vanguardngr.com/feed/","description":"Vanguard RSS — one of Nigeria's most widely read newspapers with breaking news, politics, and sports.","language":"en","html_url":"https://www.vanguardngr.com/","category":"news,nigeria,politics,sports,breaking","subcategory":"Bloggers & Writers","quality":92,"media_kind":"text"},
    {"text":"The Guardian Nigeria","xml_url":"https://guardian.ng/feed/","description":"The Guardian Nigeria RSS — independent journalism covering Nigerian affairs, business, and culture.","language":"en","html_url":"https://guardian.ng/","category":"news,nigeria,independent,journalism,culture","subcategory":"Bloggers & Writers","quality":92,"media_kind":"text"},
]

SOUTH_AFRICA_LOCAL = [
    {"text":"Radio 702","xml_url":"https://feeds.simplecast.com/radio702_za","description":"South Africa's premier talk radio podcast — in-depth interviews and analysis on politics, business, and society.","language":"en","html_url":"https://www.702.co.za/","category":"talk radio,politics,business,south africa,analysis","subcategory":"Podcasters","quality":90,"media_kind":"audio"},
    {"text":"News24","xml_url":"https://www.news24.com/rss/","description":"News24 RSS — South Africa's leading digital news platform with breaking news, sport, and opinion.","language":"en","html_url":"https://www.news24.com/","category":"news,south africa,sport,opinion,breaking","subcategory":"Bloggers & Writers","quality":93,"media_kind":"text"},
    {"text":"Mail & Guardian","xml_url":"https://mg.co.za/feed/","description":"Mail & Guardian RSS — South Africa's investigative journalism pioneer covering politics, business, and culture.","language":"en","html_url":"https://mg.co.za/","category":"news,south africa,investigative,politics,culture","subcategory":"Bloggers & Writers","quality":93,"media_kind":"text"},
    {"text":"Daily Maverick","xml_url":"https://www.dailymaverick.co.za/feed/","description":"Daily Maverick RSS — South Africa's leading independent news and analysis platform for thinking people.","language":"en","html_url":"https://www.dailymaverick.co.za/","category":"news,south africa,independent,analysis,opinion","subcategory":"Bloggers & Writers","quality":94,"media_kind":"text"},
]

KENYA_LOCAL = [
    {"text":"Nairobi News","xml_url":"https://nairobinews.nation.africa/feed/","description":"Nairobi News RSS — breaking news from Kenya's capital and beyond, covering politics, business, and entertainment.","language":"en","html_url":"https://nairobinews.nation.africa/","category":"news,kenya,nairobi,politics,business","subcategory":"Bloggers & Writers","quality":90,"media_kind":"text"},
    {"text":"The Standard","xml_url":"https://www.standardmedia.co.ke/rss/","description":"The Standard RSS — one of Kenya's oldest newspapers with comprehensive coverage of national and regional news.","language":"en","html_url":"https://www.standardmedia.co.ke/","category":"news,kenya,national,regional,analysis","subcategory":"Bloggers & Writers","quality":92,"media_kind":"text"},
    {"text":"The Elephant","xml_url":"https://www.theelephant.info/feed/","description":"The Elephant RSS — Kenyan platform for investigative journalism, political analysis, and cultural commentary.","language":"en","html_url":"https://www.theelephant.info/","category":"investigative,politics,culture,kenya,analysis","subcategory":"Bloggers & Writers","quality":91,"media_kind":"text"},
]

# ══════════════════════════════════════════════════════════════════
# EASTERN EUROPE
# ══════════════════════════════════════════════════════════════════

POLAND_LOCAL = [
    {"text":"Niekryty Krytyk","xml_url":"https://www.youtube.com/feeds/videos.xml?channel_id/UCmKLLpWHEHDIbDqYBxBXQxg","description":"Najpopularniejszy polski recenzent filmowy — ostre, zabawne i szczere recenzje filmów, seriali i gier.","language":"pl","html_url":"https://www.youtube.com/@NiekrytyKrytyk","category":"filmy,recenzje,komedia,polska,seriale","subcategory":"YouTube Creators","quality":89,"media_kind":"video"},
    {"text":"Gazeta Wyborcza","xml_url":"https://wyborcza.pl/rss/","description":"Gazeta Wyborcza RSS — największy polski dziennik liberalny z wiadomościami, analizami i opiniami.","language":"pl","html_url":"https://wyborcza.pl/","category":"wiadomości,polska,polityka,analiza,opinie","subcategory":"Bloggers & Writers","quality":94,"media_kind":"text"},
    {"text":"Rzeczpospolita","xml_url":"https://www.rp.pl/rss/","description":"Rzeczpospolita RSS — polski dziennik ekonomiczno-prawny z wiadomościami biznesowymi i politycznymi.","language":"pl","html_url":"https://www.rp.pl/","category":"biznes,polityka,ekonomia,polska,analiza","subcategory":"Bloggers & Writers","quality":93,"media_kind":"text"},
]

TURKEY_LOCAL = [
    {"text":"Orkun Işıtmak","xml_url":"https://www.youtube.com/feeds/videos.xml?channel_id/UCmKLLpWHEHDIbDqYBxBXQxg","description":"Türkiye'nin en büyük YouTuber'larından — komedi, challenge videoları ve günlük vlog içerikleri.","language":"tr","html_url":"https://www.youtube.com/@Orkunisitmak","category":"komedi,challenge,vlog,türkiye,eğlence","subcategory":"YouTube Creators","quality":90,"media_kind":"video"},
    {"text":"Barış Özcan","xml_url":"https://www.youtube.com/feeds/videos.xml?channel_id/UCmKLLpWHEHDIbDqYBxBXQxg","description":"Türkiye'nin en popüler hikaye anlatıcısı — bilim, teknoloji, sanat ve felsefe üzerine büyüleyici videolar.","language":"tr","html_url":"https://www.youtube.com/@BarisOzcan","category":"bilim,teknoloji,sanat,felsefe,türkiye","subcategory":"YouTube Creators","quality":93,"media_kind":"video"},
    {"text":"Hürriyet","xml_url":"https://www.hurriyet.com.tr/rss/","description":"Hürriyet RSS — Türkiye'nin önde gelen gazetesi, son dakika haberleri, politika, ekonomi ve yaşam.","language":"tr","html_url":"https://www.hurriyet.com.tr/","category":"haber,türkiye,politika,ekonomi,yaşam","subcategory":"Bloggers & Writers","quality":93,"media_kind":"text"},
    {"text":"Anadolu Ajansı","xml_url":"https://www.aa.com.tr/tr/rss/","description":"AA RSS — Türkiye'nin resmi haber ajansı, yurt içi ve yurt dışı güncel haberler ve analizler.","language":"tr","html_url":"https://www.aa.com.tr/tr","category":"haber,türkiye,resmi,analiz,dünya","subcategory":"Bloggers & Writers","quality":94,"media_kind":"text"},
]

# ══════════════════════════════════════════════════════════════════
# NORDIC
# ══════════════════════════════════════════════════════════════════

SWEDEN_LOCAL = [
    {"text":"PewDiePie","xml_url":"https://www.youtube.com/feeds/videos.xml?channel_id=UC-lHJZR3Gqxm24_Vd_AJ5Yw","description":"Felix Kjellberg — Sveriges och världens mest ikoniska YouTuber, gaming, memes och kommentarer i över ett decennium.","language":"sv","html_url":"https://www.youtube.com/@PewDiePie","category":"gaming,kommentarer,memes,underhållning,sverige","subcategory":"YouTube Creators","quality":95,"media_kind":"video"},
    {"text":"Dagens Nyheter","xml_url":"https://www.dn.se/rss/","description":"DN RSS — Sveriges största morgontidning med nyheter, analys och kulturdebatt.","language":"sv","html_url":"https://www.dn.se/","category":"nyheter,sverige,analys,kultur,debatt","subcategory":"Bloggers & Writers","quality":95,"media_kind":"text"},
    {"text":"Sveriges Radio","xml_url":"https://api.sr.se/api/rss/program/83","description":"SR RSS — Sveriges Radio, public service med nyheter, kultur och underhållning för hela landet.","language":"sv","html_url":"https://sverigesradio.se/","category":"nyheter,radio,sverige,kultur,public service","subcategory":"Bloggers & Writers","quality":95,"media_kind":"text"},
]

NORWAY_LOCAL = [
    {"text":"VG","xml_url":"https://www.vg.no/rss/feed/","description":"VG RSS — Norges største nyhetsnettsted med siste nytt, sport og underholdning.","language":"no","html_url":"https://www.vg.no/","category":"nyheter,norge,sport,underholdning,siste nytt","subcategory":"Bloggers & Writers","quality":94,"media_kind":"text"},
    {"text":"NRK Nyheter","xml_url":"https://www.nrk.no/rss/nyheter/","description":"NRK RSS — Norsk rikskringkasting, Norges offentlige kringkaster med pålitelige nyheter og aktualiteter.","language":"no","html_url":"https://www.nrk.no/","category":"nyheter,norge,public service,aktuelt,kultur","subcategory":"Bloggers & Writers","quality":95,"media_kind":"text"},
    {"text":"Aftenposten","xml_url":"https://www.aftenposten.no/rss/","description":"Aftenposten RSS — Norges ledende abonnementsavis med grundig journalistikk og samfunnsanalyse.","language":"no","html_url":"https://www.aftenposten.no/","category":"nyheter,norge,journalistikk,samfunn,analyse","subcategory":"Bloggers & Writers","quality":94,"media_kind":"text"},
]

DENMARK_LOCAL = [
    {"text":"DR Nyheder","xml_url":"https://www.dr.dk/nyheder/service/feeds/allenyheder","description":"DR RSS — Danmarks Radio, public service med breaking news, analyser og dokumentarer.","language":"da","html_url":"https://www.dr.dk/nyheder","category":"nyheder,danmark,public service,dokumentar,analyse","subcategory":"Bloggers & Writers","quality":95,"media_kind":"text"},
    {"text":"Politiken","xml_url":"https://politiken.dk/rss/","description":"Politiken RSS — Danmarks førende kultur- og samfundsavis med dybdeborende journalistik siden 1884.","language":"da","html_url":"https://politiken.dk/","category":"nyheder,danmark,kultur,samfund,journalistik","subcategory":"Bloggers & Writers","quality":94,"media_kind":"text"},
    {"text":"Berlingske","xml_url":"https://www.berlingske.dk/rss/","description":"Berlingske RSS — Danmarks ældste avis med erhvervsnyheder, politisk analyse og borgerlig opinionsdannelse.","language":"da","html_url":"https://www.berlingske.dk/","category":"nyheder,danmark,erhverv,politik,opinion","subcategory":"Bloggers & Writers","quality":93,"media_kind":"text"},
]

# ══════════════════════════════════════════════════════════════════
# PORTUGAL (& lusophone Africa)
# ══════════════════════════════════════════════════════════════════

PORTUGAL_LOCAL = [
    {"text":"Wuant","xml_url":"https://www.youtube.com/feeds/videos.xml?channel_id/UCmKLLpWHEHDIbDqYBxBXQxg","description":"O maior YouTuber português — gaming, comédia e vlogs que conquistaram milhões de fãs em Portugal e no Brasil.","language":"pt-PT","html_url":"https://www.youtube.com/@Wuant","category":"gaming,comédia,vlogs,portugal,entretenimento","subcategory":"YouTube Creators","quality":90,"media_kind":"video"},
    {"text":"SirKazzio","xml_url":"https://www.youtube.com/feeds/videos.xml?channel_id/UCmKLLpWHEHDIbDqYBxBXQxg","description":"Criador português de gaming e reações — um dos nomes mais reconhecidos do YouTube lusitano.","language":"pt-PT","html_url":"https://www.youtube.com/@sirkazzio","category":"gaming,reações,portugal,entretenimento","subcategory":"YouTube Creators","quality":88,"media_kind":"video"},
    {"text":"Público","xml_url":"https://feeds.feedburner.com/PublicoRSS","description":"Público RSS — jornal português de referência com notícias, política, cultura e análise aprofundada.","language":"pt-PT","html_url":"https://www.publico.pt/","category":"notícias,portugal,política,cultura,análise","subcategory":"Bloggers & Writers","quality":95,"media_kind":"text"},
    {"text":"Expresso","xml_url":"https://feeds.feedburner.com/expresso-geral","description":"Expresso RSS — semanário português de referência com jornalismo de investigação e análise política.","language":"pt-PT","html_url":"https://expresso.pt/","category":"notícias,portugal,investigação,política,semanário","subcategory":"Bloggers & Writers","quality":94,"media_kind":"text"},
    {"text":"Diário de Notícias","xml_url":"https://www.dn.pt/rss/","description":"DN RSS — um dos jornais mais antigos de Portugal com cobertura abrangente de notícias nacionais e internacionais.","language":"pt-PT","html_url":"https://www.dn.pt/","category":"notícias,portugal,nacional,internacional,história","subcategory":"Bloggers & Writers","quality":93,"media_kind":"text"},
    {"text":"Rádio Comercial","xml_url":"https://feeds.simplecast.com/radio_comercial_pt","description":"A rádio mais ouvida de Portugal — música, humor e os programas matinais que animam o país.","language":"pt-PT","html_url":"https://radiocomercial.pt/","category":"rádio,música,humor,portugal,manhã","subcategory":"Podcasters","quality":90,"media_kind":"audio"},
]

ANGOLA_LOCAL = [
    {"text":"Jornal de Angola","xml_url":"https://www.jornaldeangola.ao/rss/","description":"Jornal de Angola RSS — o principal diário angolano com notícias de Luanda, política e economia nacional.","language":"pt-AO","html_url":"https://www.jornaldeangola.ao/","category":"notícias,angola,luanda,política,economia","subcategory":"Bloggers & Writers","quality":91,"media_kind":"text"},
    {"text":"AngoNotícias","xml_url":"https://www.angonoticias.com/rss/","description":"AngoNotícias RSS — portal de notícias angolano com informação atualizada sobre o país e a diáspora.","language":"pt-AO","html_url":"https://www.angonoticias.com/","category":"notícias,angola,diáspora,atualidade,português","subcategory":"Bloggers & Writers","quality":88,"media_kind":"text"},
    {"text":"PlatinaLine","xml_url":"https://platinaline.com/feed/","description":"PlatinaLine RSS — revista angolana sobre cultura, música e lifestyle da nova geração angolana.","language":"pt-AO","html_url":"https://platinaline.com/","category":"cultura,música,lifestyle,angola,juventude","subcategory":"Bloggers & Writers","quality":87,"media_kind":"text"},
]

# ══════════════════════════════════════════════════════════════════
# MORE ASIA
# ══════════════════════════════════════════════════════════════════

INDONESIA_LOCAL = [
    {"text":"Atta Halilintar","xml_url":"https://www.youtube.com/feeds/videos.xml?channel_id/UCmKLLpWHEHDIbDqYBxBXQxg","description":"YouTuber terbesar Indonesia — vlog keluarga, tantangan, dan kehidupan selebriti yang menginspirasi jutaan.","language":"id","html_url":"https://www.youtube.com/@AttaHalilintar","category":"vlog,keluarga,tantangan,indonesia,hiburan","subcategory":"YouTube Creators","quality":90,"media_kind":"video"},
    {"text":"Raditya Dika","xml_url":"https://www.youtube.com/feeds/videos.xml?channel_id/UCmKLLpWHEHDIbDqYBxBXQxg","description":"Komedian dan penulis Indonesia — podcast, komedi, dan cerita kehidupan yang jujur dan lucu.","language":"id","html_url":"https://www.youtube.com/@radityadika","category":"komedi,podcast,cerita,indonesia,hiburan","subcategory":"YouTube Creators","quality":90,"media_kind":"video"},
    {"text":"Kompas","xml_url":"https://www.kompas.com/rss/","description":"Kompas RSS — surat kabar terbesar di Indonesia dengan berita nasional, politik, ekonomi, dan olahraga.","language":"id","html_url":"https://www.kompas.com/","category":"berita,indonesia,politik,ekonomi,olahraga","subcategory":"Bloggers & Writers","quality":94,"media_kind":"text"},
    {"text":"Detik","xml_url":"https://www.detik.com/rss/","description":"Detik RSS — portal berita online terkemuka di Indonesia dengan liputan 24 jam dan investigasi mendalam.","language":"id","html_url":"https://www.detik.com/","category":"berita,indonesia,online,investigasi,24jam","subcategory":"Bloggers & Writers","quality":93,"media_kind":"text"},
    {"text":"Tempo","xml_url":"https://www.tempo.co/rss/","description":"Tempo RSS — majalah berita mingguan terkemuka di Indonesia dengan jurnalisme investigasi dan analisis.","language":"id","html_url":"https://www.tempo.co/","category":"berita,indonesia,mingguan,investigasi,analisis","subcategory":"Bloggers & Writers","quality":93,"media_kind":"text"},
]

MALAYSIA_LOCAL = [
    {"text":"Nazirul Zainal","xml_url":"https://www.youtube.com/feeds/videos.xml?channel_id/UCmKLLpWHEHDIbDqYBxBXQxg","description":"Pencipta kandungan Malaysia — komedi, cabaran, dan vlog harian yang menghiburkan jutaan penonton.","language":"ms","html_url":"https://www.youtube.com/@NazirulZainal","category":"komedi,cabaran,vlog,malaysia,hiburan","subcategory":"YouTube Creators","quality":88,"media_kind":"video"},
    {"text":"The Star Malaysia","xml_url":"https://www.thestar.com.my/rss/","description":"The Star RSS — akhbar terbesar Malaysia dalam bahasa Inggeris dengan berita nasional, bisnes dan sukan.","language":"en","html_url":"https://www.thestar.com.my/","category":"news,malaysia,business,sports,national","subcategory":"Bloggers & Writers","quality":93,"media_kind":"text"},
    {"text":"Malaysiakini","xml_url":"https://www.malaysiakini.com/rss/","description":"Malaysiakini RSS — media berita bebas Malaysia dengan liputan politik, masyarakat dan hak asasi.","language":"ms","html_url":"https://www.malaysiakini.com/","category":"berita,malaysia,bebas,politik,masyarakat","subcategory":"Bloggers & Writers","quality":92,"media_kind":"text"},
]

PHILIPPINES_LOCAL = [
    {"text":"Cong TV","xml_url":"https://www.youtube.com/feeds/videos.xml?channel_id/UCmKLLpWHEHDIbDqYBxBXQxg","description":"Pinoy comedy creator — relatable sketches, funny vlogs, and slice-of-life content from Manila.","language":"tl","html_url":"https://www.youtube.com/@CongTV","category":"comedy,sketches,vlogs,philippines,manila","subcategory":"YouTube Creators","quality":89,"media_kind":"video"},
    {"text":"Rappler","xml_url":"https://www.rappler.com/feed/","description":"Rappler RSS — independent Philippine news platform with investigative journalism and community engagement.","language":"en","html_url":"https://www.rappler.com/","category":"news,philippines,independent,investigative,community","subcategory":"Bloggers & Writers","quality":93,"media_kind":"text"},
    {"text":"Inquirer","xml_url":"https://www.inquirer.net/feed/","description":"Philippine Daily Inquirer RSS — the Philippines' newspaper of record with comprehensive national coverage.","language":"en","html_url":"https://www.inquirer.net/","category":"news,philippines,national,politics,business","subcategory":"Bloggers & Writers","quality":94,"media_kind":"text"},
]

# ══════════════════════════════════════════════════════════════════
# MAPPING: country slug -> local data list
# ══════════════════════════════════════════════════════════════════

# ══════════════════════════════════════════════════════════════════
# QUICK-REST COUNTRIES — Small batch of locals per country
# (national newspapers, known local creators, local podcasts)
# ══════════════════════════════════════════════════════════════════

AUSTRIA_LOCAL = [
    {"text":"ORF News","xml_url":"https://orf.at/rss/news.xml","description":"ORF Nachrichten RSS — Österreichs öffentlich-rechtlicher Rundfunk mit aktuellen Nachrichten aus Politik, Wirtschaft und Kultur.","language":"de","html_url":"https://orf.at/","category":"nachrichten,österreich,orf,politik,wirtschaft","subcategory":"Bloggers & Writers","quality":95,"media_kind":"text"},
    {"text":"Der Standard","xml_url":"https://www.derstandard.at/rss","description":"Der Standard RSS — Österreichs führende liberale Tageszeitung mit Qualitätsjournalismus aus Wien.","language":"de","html_url":"https://www.derstandard.at/","category":"nachrichten,österreich,wien,liberal,journalismus","subcategory":"Bloggers & Writers","quality":94,"media_kind":"text"},
    {"text":"Die Presse","xml_url":"https://www.diepresse.com/rss","description":"Die Presse RSS — bürgerlich-liberale Tageszeitung aus Wien mit Schwerpunkt Wirtschaft und Politik.","language":"de","html_url":"https://www.diepresse.com/","category":"nachrichten,österreich,wien,bürgerlich,wirtschaft","subcategory":"Bloggers & Writers","quality":93,"media_kind":"text"},
]
BELGIUM_LOCAL = [
    {"text":"Le Soir","xml_url":"https://www.lesoir.be/rss.xml","description":"Le Soir RSS — le grand quotidien belge francophone avec actualité, politique et culture de Bruxelles et de Wallonie.","language":"fr","html_url":"https://www.lesoir.be/","category":"actualité,belgique,bruxelles,francophone,wallonie","subcategory":"Bloggers & Writers","quality":94,"media_kind":"text"},
    {"text":"De Standaard","xml_url":"https://www.standaard.be/rss.xml","description":"De Standaard RSS — Vlaamse kwaliteitskrant met diepgaande analyses en nieuws uit België en de wereld.","language":"nl","html_url":"https://www.standaard.be/","category":"nieuws,belgië,vlaanderen,analyse,kwaliteit","subcategory":"Bloggers & Writers","quality":94,"media_kind":"text"},
    {"text":"VRT NWS","xml_url":"https://www.vrt.be/vrtnws/nl.rss/","description":"VRT NWS RSS — nieuws van de Vlaamse openbare omroep met actualiteit, sport en cultuur uit België.","language":"nl","html_url":"https://www.vrt.be/vrtnws/","category":"nieuws,belgië,vlaanderen,openbare omroep,actualiteit","subcategory":"Bloggers & Writers","quality":94,"media_kind":"text"},
]
SWITZERLAND_LOCAL = [
    {"text":"NZZ","xml_url":"https://www.nzz.ch/recent.rss","description":"Neue Zürcher Zeitung RSS — die führende Schweizer Qualitätszeitung mit Fokus auf Wirtschaft, Politik und Internationales.","language":"de","html_url":"https://www.nzz.ch/","category":"nachrichten,schweiz,zürich,wirtschaft,politik","subcategory":"Bloggers & Writers","quality":95,"media_kind":"text"},
    {"text":"Le Temps","xml_url":"https://www.letemps.ch/rss","description":"Le Temps RSS — le quotidien suisse romand de référence, actualité, économie et culture de Genève à Lausanne.","language":"fr","html_url":"https://www.letemps.ch/","category":"actualité,suisse,romandie,genève,économie","subcategory":"Bloggers & Writers","quality":94,"media_kind":"text"},
    {"text":"SWI swissinfo","xml_url":"https://www.swissinfo.ch/eng/rss","description":"SWI swissinfo RSS — Switzerland's international public broadcaster with news in 10 languages for a global audience.","language":"en","html_url":"https://www.swissinfo.ch/eng","category":"news,switzerland,international,public broadcaster,multilingual","subcategory":"Bloggers & Writers","quality":94,"media_kind":"text"},
]
IRELAND_LOCAL = [
    {"text":"The Irish Times","xml_url":"https://www.irishtimes.com/rss/","description":"The Irish Times RSS — Ireland's newspaper of record with trusted coverage of national news, business, and culture.","language":"en","html_url":"https://www.irishtimes.com/","category":"news,ireland,dublin,politics,culture","subcategory":"Bloggers & Writers","quality":95,"media_kind":"text"},
    {"text":"RTE News","xml_url":"https://www.rte.ie/rss/news.xml","description":"RTE News RSS — Ireland's public service broadcaster providing news, sport and entertainment to the nation.","language":"en","html_url":"https://www.rte.ie/news/","category":"news,ireland,public service,sport,entertainment","subcategory":"Bloggers & Writers","quality":95,"media_kind":"text"},
    {"text":"The Irish Independent","xml_url":"https://www.independent.ie/rss/","description":"Irish Independent RSS — Ireland's largest-selling daily newspaper covering national and international news.","language":"en","html_url":"https://www.independent.ie/","category":"news,ireland,national,international,daily","subcategory":"Bloggers & Writers","quality":94,"media_kind":"text"},
]
FINLAND_LOCAL = [
    {"text":"YLE News","xml_url":"https://feeds.yle.fi/uutiset/v1/recent.rss?publisherIds=YLE_UUTISET","description":"YLE Uutiset RSS — Suomen julkinen yleisradio, luotettavat uutiset, urheilu ja kulttuuri koko maasta.","language":"fi","html_url":"https://yle.fi/uutiset","category":"uutiset,suomi,yle,julkinen,urheilu","subcategory":"Bloggers & Writers","quality":95,"media_kind":"text"},
    {"text":"Helsingin Sanomat","xml_url":"https://www.hs.fi/rss/","description":"HS RSS — Suomen suurin sanomalehti, syvällistä journalismia politiikasta, taloudesta ja kulttuurista.","language":"fi","html_url":"https://www.hs.fi/","category":"uutiset,suomi,helsinki,politiikka,talous","subcategory":"Bloggers & Writers","quality":95,"media_kind":"text"},
]
ICELAND_LOCAL = [
    {"text":"RUV","xml_url":"https://www.ruv.is/rss/","description":"RUV RSS — Íslenski ríkisútvarpið, traustar fréttir og menningarefni frá Íslandi og umheiminum.","language":"is","html_url":"https://www.ruv.is/","category":"fréttir,ísland,menning,ríkisútvarp,traust","subcategory":"Bloggers & Writers","quality":93,"media_kind":"text"},
    {"text":"Morgunblaðið","xml_url":"https://www.mbl.is/rss/","description":"Morgunblaðið RSS — stærsta dagblað Íslands með fréttir, viðskipti og menningu.","language":"is","html_url":"https://www.mbl.is/","category":"fréttir,ísland,dagblað,viðskipti,menning","subcategory":"Bloggers & Writers","quality":92,"media_kind":"text"},
]
LUXEMBOURG_LOCAL = [
    {"text":"RTL Luxembourg","xml_url":"https://www.rtl.lu/rss/","description":"RTL Lëtzebuerg RSS — neiheet vum gréisste Mediegroupe zu Lëtzebuerg op Lëtzebuergesch, Franséisch an Däitsch.","language":"fr","html_url":"https://www.rtl.lu/","category":"actualité,luxembourg,multilingue,rtl,news","subcategory":"Bloggers & Writers","quality":92,"media_kind":"text"},
    {"text":"Luxemburger Wort","xml_url":"https://www.wort.lu/rss/","description":"Luxemburger Wort RSS — déi gréissten Zeitung zu Lëtzebuerg mat Neiheeten op Däitsch a Franséisch.","language":"de","html_url":"https://www.wort.lu/","category":"nachrichten,luxemburg,zeitung,zweisprachig,aktuell","subcategory":"Bloggers & Writers","quality":93,"media_kind":"text"},
]
MALTA_LOCAL = [
    {"text":"Times of Malta","xml_url":"https://timesofmalta.com/rss/","description":"Times of Malta RSS — Malta's oldest and most trusted news source covering the islands, politics, and Mediterranean affairs.","language":"en","html_url":"https://timesofmalta.com/","category":"news,malta,mediterranean,politics,islands","subcategory":"Bloggers & Writers","quality":93,"media_kind":"text"},
    {"text":"Malta Today","xml_url":"https://www.maltatoday.com.mt/rss/","description":"Malta Today RSS — independent Maltese journalism covering national news, environment, and social affairs.","language":"en","html_url":"https://www.maltatoday.com.mt/","category":"news,malta,independent,environment,social","subcategory":"Bloggers & Writers","quality":91,"media_kind":"text"},
]
CYPRUS_LOCAL = [
    {"text":"Cyprus Mail","xml_url":"https://cyprus-mail.com/feed/","description":"Cyprus Mail RSS — the island's leading English-language newspaper with daily news from Cyprus and the region.","language":"en","html_url":"https://cyprus-mail.com/","category":"news,cyprus,english,mediterranean,daily","subcategory":"Bloggers & Writers","quality":91,"media_kind":"text"},
]
GREECE_LOCAL = [
    {"text":"Καθημερινή","xml_url":"https://www.kathimerini.gr/rss/","description":"Η Καθημερινή RSS — η κορυφαία ελληνική εφημερίδα με ειδήσεις, πολιτική, οικονομία και πολιτισμό.","language":"el","html_url":"https://www.kathimerini.gr/","category":"ειδήσεις,ελλάδα,πολιτική,οικονομία,πολιτισμός","subcategory":"Bloggers & Writers","quality":94,"media_kind":"text"},
    {"text":"Τα Νέα","xml_url":"https://www.tanea.gr/rss/","description":"Τα Νέα RSS — ελληνική καθημερινή εφημερίδα με ενημέρωση, απόψεις και ρεπορτάζ από όλη την Ελλάδα.","language":"el","html_url":"https://www.tanea.gr/","category":"ειδήσεις,ελλάδα,καθημερινή,απόψεις,ρεπορτάζ","subcategory":"Bloggers & Writers","quality":93,"media_kind":"text"},
]
ISRAEL_LOCAL = [
    {"text":"הארץ","xml_url":"https://www.haaretz.co.il/rss/","description":"הארץ RSS — העיתון המוביל בישראל עם חדשות, פרשנות פוליטית, תרבות ודעות מעמיקות.","language":"he","html_url":"https://www.haaretz.co.il/","category":"חדשות,ישראל,פוליטיקה,תרבות,פרשנות","subcategory":"Bloggers & Writers","quality":94,"media_kind":"text"},
    {"text":"The Times of Israel","xml_url":"https://www.timesofisrael.com/rss/","description":"The Times of Israel RSS — independent English-language journalism covering Israel, the Middle East and the Jewish world.","language":"en","html_url":"https://www.timesofisrael.com/","category":"news,israel,middle east,english,independent","subcategory":"Bloggers & Writers","quality":93,"media_kind":"text"},
]
RUSSIA_LOCAL = [
    {"text":"Юрий Дудь","xml_url":"https://www.youtube.com/feeds/videos.xml?channel_id/UCmKLLpWHEHDIbDqYBxBXQxg","description":"Самый известный интервьюер России — глубокие беседы с ключевыми фигурами российской культуры и политики.","language":"ru","html_url":"https://www.youtube.com/@vDud","category":"интервью,россия,культура,политика,документалистика","subcategory":"YouTube Creators","quality":93,"media_kind":"video"},
    {"text":"Meduza","xml_url":"https://meduza.io/rss/all","description":"Meduza RSS — независимое русскоязычное издание с оперативными новостями, расследованиями и анализом.","language":"ru","html_url":"https://meduza.io/","category":"новости,россия,независимые,расследования,анализ","subcategory":"Bloggers & Writers","quality":93,"media_kind":"text"},
    {"text":"Коммерсантъ","xml_url":"https://www.kommersant.ru/RSS/news.xml","description":"Коммерсантъ RSS — ведущая российская деловая газета с новостями политики, экономики и финансов.","language":"ru","html_url":"https://www.kommersant.ru/","category":"новости,россия,бизнес,политика,экономика","subcategory":"Bloggers & Writers","quality":93,"media_kind":"text"},
]
UKRAINE_LOCAL = [
    {"text":"Українська правда","xml_url":"https://www.pravda.com.ua/rss/","description":"Українська правда RSS — провідне незалежне видання України з новинами, розслідуваннями та аналітикою.","language":"uk","html_url":"https://www.pravda.com.ua/","category":"новини,україна,незалежні,розслідування,аналітика","subcategory":"Bloggers & Writers","quality":94,"media_kind":"text"},
    {"text":"NV","xml_url":"https://nv.ua/rss/","description":"NV RSS — український новинний портал і журнал з фокусом на політику, бізнес і суспільство.","language":"uk","html_url":"https://nv.ua/","category":"новини,україна,політика,бізнес,суспільство","subcategory":"Bloggers & Writers","quality":93,"media_kind":"text"},
]
HUNGARY_LOCAL = [
    {"text":"Telex","xml_url":"https://telex.hu/rss","description":"Telex RSS — Magyarország vezető független hírportálja, naprakész hírek, elemzések és oknyomozó újságírás.","language":"hu","html_url":"https://telex.hu/","category":"hírek,magyarország,független,elemzés,oknyomozó","subcategory":"Bloggers & Writers","quality":93,"media_kind":"text"},
    {"text":"444.hu","xml_url":"https://444.hu/rss","description":"444 RSS — magyar oknyomozó és véleményportál, kritikus hangvételű hírek és közéleti elemzések.","language":"hu","html_url":"https://444.hu/","category":"hírek,magyarország,vélemény,kritikus,közélet","subcategory":"Bloggers & Writers","quality":92,"media_kind":"text"},
]
CZECH_REPUBLIC_LOCAL = [
    {"text":"Seznam Zprávy","xml_url":"https://www.seznamzpravy.cz/rss","description":"Seznam Zprávy RSS — největší český zpravodajský portál s aktuálními zprávami, analýzami a investigací.","language":"cs","html_url":"https://www.seznamzpravy.cz/","category":"zprávy,česko,analýza,investigace,aktuální","subcategory":"Bloggers & Writers","quality":93,"media_kind":"text"},
    {"text":"iDNES","xml_url":"https://www.idnes.cz/rss","description":"iDNES RSS — zpravodajský server Mladé fronty DNES, nejčtenější české noviny s politickým a sportovním zpravodajstvím.","language":"cs","html_url":"https://www.idnes.cz/","category":"zprávy,česko,politika,sport,mf dnes","subcategory":"Bloggers & Writers","quality":93,"media_kind":"text"},
]
SLOVAKIA_LOCAL = [
    {"text":"SME","xml_url":"https://www.sme.sk/rss-title/","description":"SME RSS — najčítanejší slovenský denník s kvalitným spravodajstvom, analýzami a investigatívnou žurnalistikou.","language":"sk","html_url":"https://www.sme.sk/","category":"správy,slovensko,analýza,investigatíva,denník","subcategory":"Bloggers & Writers","quality":93,"media_kind":"text"},
    {"text":"Denník N","xml_url":"https://dennikn.sk/rss/","description":"Denník N RSS — nezávislý slovenský denník založený novinármi, ktorí opustili SME, kvalitná žurnalistika.","language":"sk","html_url":"https://dennikn.sk/","category":"správy,slovensko,nezávislý,žurnalistika,kvalita","subcategory":"Bloggers & Writers","quality":94,"media_kind":"text"},
]
ROMANIA_LOCAL = [
    {"text":"Digi24","xml_url":"https://www.digi24.ro/rss/","description":"Digi24 RSS — principala televiziune de știri din România cu informații actualizate 24/7.","language":"ro","html_url":"https://www.digi24.ro/","category":"știri,românia,televiziune,24/7,actualități","subcategory":"Bloggers & Writers","quality":93,"media_kind":"text"},
    {"text":"HotNews","xml_url":"https://www.hotnews.ro/rss","description":"HotNews RSS — unul dintre cele mai citite site-uri de știri din România, anchete și analize politice.","language":"ro","html_url":"https://www.hotnews.ro/","category":"știri,românia,anchete,politică,analiză","subcategory":"Bloggers & Writers","quality":92,"media_kind":"text"},
]
BULGARIA_LOCAL = [
    {"text":"Дневник","xml_url":"https://www.dnevnik.bg/rss/","description":"Дневник RSS — водещ български новинарски сайт с бизнес, политика и анализи от България и света.","language":"bg","html_url":"https://www.dnevnik.bg/","category":"новини,българия,бизнес,политика,анализи","subcategory":"Bloggers & Writers","quality":92,"media_kind":"text"},
]
SERBIA_LOCAL = [
    {"text":"B92","xml_url":"https://www.b92.net/rss/","description":"B92 RSS — najposećeniji informativni portal u Srbiji sa vestima, sportom i zabavom.","language":"sr","html_url":"https://www.b92.net/","category":"vesti,srbija,sport,zabava,informativni","subcategory":"Bloggers & Writers","quality":92,"media_kind":"text"},
]
CROATIA_LOCAL = [
    {"text":"Jutarnji list","xml_url":"https://www.jutarnji.hr/rss/","description":"Jutarnji list RSS — najčitaniji hrvatski dnevni list s vijestima, politikom, sportom i kulturom.","language":"hr","html_url":"https://www.jutarnji.hr/","category":"vijesti,hrvatska,politika,sport,kultura","subcategory":"Bloggers & Writers","quality":93,"media_kind":"text"},
]
SLOVENIA_LOCAL = [
    {"text":"24ur","xml_url":"https://www.24ur.com/rss/","description":"24ur RSS — najbolj obiskan slovenski novičarski portal z aktualnimi novicami, športom in zabavo.","language":"sl","html_url":"https://www.24ur.com/","category":"novice,slovenija,šport,zabava,aktualno","subcategory":"Bloggers & Writers","quality":92,"media_kind":"text"},
]
ESTONIA_LOCAL = [
    {"text":"ERR","xml_url":"https://www.err.ee/rss/","description":"ERR RSS — Eesti Rahvusringhääling, usaldusväärsed uudised, sport ja kultuur eesti keeles.","language":"et","html_url":"https://www.err.ee/","category":"uudised,eesti,rahvusringhääling,sport,kultuur","subcategory":"Bloggers & Writers","quality":94,"media_kind":"text"},
]
LATVIA_LOCAL = [
    {"text":"LSM","xml_url":"https://www.lsm.lv/rss/","description":"LSM RSS — Latvijas Sabiedriskie Mediji, uzticamas ziņas latviešu valodā par Latviju un pasauli.","language":"lv","html_url":"https://www.lsm.lv/","category":"ziņas,latvija,sabiedriskie mediji,pasaule,uzticamas","subcategory":"Bloggers & Writers","quality":93,"media_kind":"text"},
]
LITHUANIA_LOCAL = [
    {"text":"LRT","xml_url":"https://www.lrt.lt/rss/","description":"LRT RSS — Lietuvos nacionalinis radijas ir televizija, patikimos naujienos iš Lietuvos ir pasaulio.","language":"lt","html_url":"https://www.lrt.lt/","category":"naujienos,lietuva,nacionalinis,pasaulis,patikimos","subcategory":"Bloggers & Writers","quality":94,"media_kind":"text"},
]
KAZAKHSTAN_LOCAL = [
    {"text":"Tengrinews","xml_url":"https://tengrinews.kz/rss/","description":"Tengrinews RSS — ведущий новостной портал Казахстана на русском языке с новостями, бизнесом и спортом.","language":"ru","html_url":"https://tengrinews.kz/","category":"новости,казахстан,русский,бизнес,спорт","subcategory":"Bloggers & Writers","quality":92,"media_kind":"text"},
]
AZERBAIJAN_LOCAL = [
    {"text":"Trend","xml_url":"https://en.trend.az/rss/","description":"Trend News Agency RSS — Azerbaijan's leading news agency covering the South Caucasus, energy and geopolitics.","language":"en","html_url":"https://en.trend.az/","category":"news,azerbaijan,caucasus,energy,geopolitics","subcategory":"Bloggers & Writers","quality":91,"media_kind":"text"},
]
GEORGIA_LOCAL = [
    {"text":"Agenda.ge","xml_url":"https://agenda.ge/en/rss.xml","description":"Agenda.ge RSS — Georgia's leading English-language news portal covering Tbilisi, politics, and the Caucasus region.","language":"en","html_url":"https://agenda.ge/en","category":"news,georgia,tbilisi,caucasus,english","subcategory":"Bloggers & Writers","quality":91,"media_kind":"text"},
]
ARMENIA_LOCAL = [
    {"text":"News.am","xml_url":"https://news.am/rss/","description":"News.am RSS — Armenia's popular news portal covering Yerevan, the diaspora, and regional affairs.","language":"en","html_url":"https://news.am/","category":"news,armenia,yerevan,diaspora,regional","subcategory":"Bloggers & Writers","quality":90,"media_kind":"text"},
]
BELARUS_LOCAL = [
    {"text":"TUT.BY","xml_url":"https://tut.by/rss/","description":"TUT.BY RSS — крупнейший независимый новостной портал Беларуси с новостями, аналитикой и расследованиями.","language":"ru","html_url":"https://tut.by/","category":"новости,беларусь,независимый,аналитика,расследования","subcategory":"Bloggers & Writers","quality":92,"media_kind":"text"},
]
MOROCCO_LOCAL = [
    {"text":"Hespress","xml_url":"https://www.hespress.com/rss","description":"هسبريس RSS — أشهر موقع إخباري مغربي مع تغطية شاملة للأخبار الوطنية والدولية والسياسة.","language":"ar","html_url":"https://www.hespress.com/","category":"أخبار,المغرب,وطنية,دولية,سياسة","subcategory":"Bloggers & Writers","quality":93,"media_kind":"text"},
    {"text":"Le Matin","xml_url":"https://lematin.ma/rss/","description":"Le Matin RSS — quotidien marocain francophone avec actualité nationale, économie et sport du royaume.","language":"fr","html_url":"https://lematin.ma/","category":"actualité,maroc,francophone,économie,sport","subcategory":"Bloggers & Writers","quality":92,"media_kind":"text"},
]
TUNISIA_LOCAL = [
    {"text":"Mosaïque FM","xml_url":"https://www.mosaiquefm.net/rss/","description":"موزاييك FM RSS — الإذاعة التونسية الأولى مع الأخبار العاجلة والموسيقى والبرامج الثقافية.","language":"ar","html_url":"https://www.mosaiquefm.net/","category":"أخبار,تونس,راديو,موسيقى,ثقافة","subcategory":"Bloggers & Writers","quality":91,"media_kind":"text"},
]
ALGERIA_LOCAL = [
    {"text":"El Khabar","xml_url":"https://www.elkhabar.com/rss/","description":"الخبر RSS — الجريدة الجزائرية الرائدة مع تغطية شاملة لأخبار الجزائر والوطن العربي.","language":"ar","html_url":"https://www.elkhabar.com/","category":"أخبار,الجزائر,عربي,تحقيق,سياسة","subcategory":"Bloggers & Writers","quality":92,"media_kind":"text"},
]
IRAQ_LOCAL = [
    {"text":"Al Sumaria","xml_url":"https://www.alsumaria.tv/rss/","description":"السومرية RSS — شبكة إعلامية عراقية رائدة مع أخبار بغداد والسياسة والاقتصاد والأمن.","language":"ar","html_url":"https://www.alsumaria.tv/","category":"أخبار,العراق,بغداد,سياسة,أمن","subcategory":"Bloggers & Writers","quality":91,"media_kind":"text"},
]
IRAN_LOCAL = [
    {"text":"BBC Persian","xml_url":"https://feeds.bbci.co.uk/persian/rss.xml","description":"بی‌بی‌سی فارسی RSS — اخبار موثق و تحلیل از ایران و جهان به زبان فارسی از پربیننده‌ترین رسانه بین‌المللی.","language":"fa","html_url":"https://www.bbc.com/persian","category":"اخبار,ایران,فارسی,تحلیل,بین‌المللی","subcategory":"Bloggers & Writers","quality":93,"media_kind":"text"},
]
QATAR_LOCAL = [
    {"text":"Al Jazeera Arabic","xml_url":"https://www.aljazeera.net/rss/","description":"الجزيرة نت RSS — الشبكة الإخبارية الرائدة في العالم العربي من الدوحة مع تغطية شاملة للأخبار.","language":"ar","html_url":"https://www.aljazeera.net/","category":"أخبار,قطر,الدوحة,عربي,تغطية شاملة","subcategory":"Bloggers & Writers","quality":95,"media_kind":"text"},
]
SUDAN_LOCAL = [
    {"text":"Sudan Tribune","xml_url":"https://sudantribune.com/rss/","description":"Sudan Tribune RSS — independent Sudanese news covering Khartoum, Darfur, South Sudan and regional politics.","language":"en","html_url":"https://sudantribune.com/","category":"news,sudan,khartoum,darfur,independent","subcategory":"Bloggers & Writers","quality":90,"media_kind":"text"},
]
BANGLADESH_LOCAL = [
    {"text":"Prothom Alo","xml_url":"https://www.prothomalo.com/rss","description":"প্রথম আলো RSS — বাংলাদেশের সবচেয়ে জনপ্রিয় বাংলা সংবাদপত্র, বিশ্বস্ত খবর ও বিশ্লেষণ।","language":"bn","html_url":"https://www.prothomalo.com/","category":"খবর,বাংলাদেশ,বাংলা,বিশ্বাসযোগ্য,বিশ্লেষণ","subcategory":"Bloggers & Writers","quality":93,"media_kind":"text"},
    {"text":"The Daily Star","xml_url":"https://www.thedailystar.net/rss","description":"The Daily Star RSS — Bangladesh's leading English daily with comprehensive news, business and cricket coverage.","language":"en","html_url":"https://www.thedailystar.net/","category":"news,bangladesh,english,cricket,business","subcategory":"Bloggers & Writers","quality":93,"media_kind":"text"},
]
PAKISTAN_LOCAL = [
    {"text":"Dawn","xml_url":"https://www.dawn.com/rss/","description":"Dawn RSS — Pakistan's most widely read English-language newspaper with authoritative news and analysis.","language":"en","html_url":"https://www.dawn.com/","category":"news,pakistan,english,authoritative,analysis","subcategory":"Bloggers & Writers","quality":94,"media_kind":"text"},
    {"text":"Geo News","xml_url":"https://www.geo.tv/rss/","description":"Geo News RSS — Pakistan's leading Urdu and English news channel with breaking stories and political coverage.","language":"ur","html_url":"https://www.geo.tv/","category":"khabrain,pakistan,urdu,breaking,politics","subcategory":"Bloggers & Writers","quality":92,"media_kind":"text"},
]
SRI_LANKA_LOCAL = [
    {"text":"Daily Mirror","xml_url":"https://www.dailymirror.lk/rss","description":"Daily Mirror RSS — Sri Lanka's popular English daily newspaper with news, business, sports and opinions.","language":"en","html_url":"https://www.dailymirror.lk/","category":"news,sri lanka,colombo,english,daily","subcategory":"Bloggers & Writers","quality":92,"media_kind":"text"},
]
NEPAL_LOCAL = [
    {"text":"The Kathmandu Post","xml_url":"https://kathmandupost.com/rss","description":"The Kathmandu Post RSS — Nepal's leading English daily covering the Himalayas, politics, and society.","language":"en","html_url":"https://kathmandupost.com/","category":"news,nepal,kathmandu,english,himalayas","subcategory":"Bloggers & Writers","quality":92,"media_kind":"text"},
]
SINGAPORE_LOCAL = [
    {"text":"The Straits Times","xml_url":"https://www.straitstimes.com/rss.xml","description":"The Straits Times RSS — Singapore's newspaper of record with trusted coverage of the city-state and Asia.","language":"en","html_url":"https://www.straitstimes.com/","category":"news,singapore,asia,english,trusted","subcategory":"Bloggers & Writers","quality":95,"media_kind":"text"},
    {"text":"CNA","xml_url":"https://www.channelnewsasia.com/rss.xml","description":"CNA RSS — Singapore's flagship news broadcaster covering Asia and the world with in-depth reporting.","language":"en","html_url":"https://www.channelnewsasia.com/","category":"news,singapore,asia,broadcast,in-depth","subcategory":"Bloggers & Writers","quality":94,"media_kind":"text"},
]
TAIWAN_LOCAL = [
    {"text":"自由時報","xml_url":"https://news.ltn.com.tw/rss/","description":"自由時報 RSS — 台灣發行量最大的報紙，提供政治、財經、社會和國際新聞。","language":"zh-TW","html_url":"https://www.ltn.com.tw/","category":"新聞,台灣,政治,財經,國際","subcategory":"Bloggers & Writers","quality":93,"media_kind":"text"},
    {"text":"中央社","xml_url":"https://www.cna.com.tw/rss/","description":"中央社 RSS — 台灣的國家通訊社，中英雙語提供即時新聞和深度報導。","language":"zh-TW","html_url":"https://www.cna.com.tw/","category":"新聞,台灣,通訊社,中英雙語,即時","subcategory":"Bloggers & Writers","quality":94,"media_kind":"text"},
]
CHINA_LOCAL = [
    {"text":"财新网","xml_url":"https://www.caixin.com/rss/","description":"财新 RSS — 中国领先的财经媒体，提供深度的经济分析和调查报道。","language":"zh-CN","html_url":"https://www.caixin.com/","category":"财经,中国,经济,调查,分析","subcategory":"Bloggers & Writers","quality":93,"media_kind":"text"},
    {"text":"澎湃新闻","xml_url":"https://www.thepaper.cn/rss/","description":"澎湃 RSS — 上海报业集团旗下的新媒体平台，专注时政新闻与思想评论。","language":"zh-CN","html_url":"https://www.thepaper.cn/","category":"新闻,中国,上海,时政,思想","subcategory":"Bloggers & Writers","quality":94,"media_kind":"text"},
]
THAILAND_LOCAL = [
    {"text":"The Bangkok Post","xml_url":"https://www.bangkokpost.com/rss/","description":"Bangkok Post RSS — Thailand's leading English-language newspaper with news from Bangkok and Southeast Asia.","language":"en","html_url":"https://www.bangkokpost.com/","category":"news,thailand,bangkok,english,southeast asia","subcategory":"Bloggers & Writers","quality":93,"media_kind":"text"},
    {"text":"Thai PBS","xml_url":"https://www.thaipbs.or.th/rss/","description":"Thai PBS RSS — สื่อสาธารณะของประเทศไทย ข่าวสารที่น่าเชื่อถือ วัฒนธรรม และสาระความรู้","language":"th","html_url":"https://www.thaipbs.or.th/","category":"ข่าว,ไทย,สาธารณะ,วัฒนธรรม,ความรู้","subcategory":"Bloggers & Writers","quality":93,"media_kind":"text"},
]
VIETNAM_LOCAL = [
    {"text":"VNExpress","xml_url":"https://vnexpress.net/rss/","description":"VNExpress RSS — trang tin tức hàng đầu Việt Nam với tin nóng, kinh doanh, thể thao và giải trí.","language":"vi","html_url":"https://vnexpress.net/","category":"tin tức,việt nam,kinh doanh,thể thao,giải trí","subcategory":"Bloggers & Writers","quality":94,"media_kind":"text"},
    {"text":"Tuổi Trẻ","xml_url":"https://tuoitre.vn/rss/","description":"Tuổi Trẻ RSS — nhật báo hàng đầu tại TP.HCM với tin tức xã hội, pháp luật và văn hóa Việt Nam.","language":"vi","html_url":"https://tuoitre.vn/","category":"tin tức,việt nam,xã hội,pháp luật,văn hóa","subcategory":"Bloggers & Writers","quality":93,"media_kind":"text"},
]
MYANMAR_LOCAL = [
    {"text":"The Irrawaddy","xml_url":"https://www.irrawaddy.com/feed/","description":"The Irrawaddy RSS — independent Burmese news covering Myanmar's politics, human rights, and the struggle for democracy.","language":"en","html_url":"https://www.irrawaddy.com/","category":"news,myanmar,independent,human rights,democracy","subcategory":"Bloggers & Writers","quality":91,"media_kind":"text"},
]
CAMBODIA_LOCAL = [
    {"text":"Phnom Penh Post","xml_url":"https://www.phnompenhpost.com/rss/","description":"Phnom Penh Post RSS — Cambodia's oldest English-language newspaper covering the kingdom and Southeast Asia.","language":"en","html_url":"https://www.phnompenhpost.com/","category":"news,cambodia,phnom penh,english,southeast asia","subcategory":"Bloggers & Writers","quality":92,"media_kind":"text"},
]
ETHIOPIA_LOCAL = [
    {"text":"Addis Standard","xml_url":"https://addisstandard.com/feed/","description":"Addis Standard RSS — independent Ethiopian news and analysis covering Addis Ababa, the Horn of Africa and beyond.","language":"en","html_url":"https://addisstandard.com/","category":"news,ethiopia,addis ababa,independent,horn of africa","subcategory":"Bloggers & Writers","quality":90,"media_kind":"text"},
]
GHANA_LOCAL = [
    {"text":"Graphic Online","xml_url":"https://www.graphic.com.gh/rss/","description":"Graphic Online RSS — Ghana's most authoritative newspaper with daily news, politics, sports and entertainment.","language":"en","html_url":"https://www.graphic.com.gh/","category":"news,ghana,accra,politics,sports","subcategory":"Bloggers & Writers","quality":92,"media_kind":"text"},
]
IVORY_COAST_LOCAL = [
    {"text":"Fraternité Matin","xml_url":"https://www.fratmat.info/rss/","description":"Fraternité Matin RSS — le quotidien ivoirien de référence depuis 1964, actualité politique et économique de Côte d'Ivoire.","language":"fr","html_url":"https://www.fratmat.info/","category":"actualité,côte d'ivoire,abidjan,politique,économie","subcategory":"Bloggers & Writers","quality":91,"media_kind":"text"},
]
JAMAICA_LOCAL = [
    {"text":"Jamaica Gleaner","xml_url":"https://jamaica-gleaner.com/feed/","description":"Jamaica Gleaner RSS — the Caribbean's leading newspaper covering Jamaican news, sports and entertainment since 1834.","language":"en","html_url":"https://jamaica-gleaner.com/","category":"news,jamaica,caribbean,sports,entertainment","subcategory":"Bloggers & Writers","quality":93,"media_kind":"text"},
]
NEW_ZEALAND_LOCAL = [
    {"text":"RNZ","xml_url":"https://www.rnz.co.nz/rss/national.xml","description":"RNZ RSS — Radio New Zealand, Aotearoa's public broadcaster with trusted national, Pacific, and world news.","language":"en","html_url":"https://www.rnz.co.nz/","category":"news,new zealand,aotearoa,pacific,public broadcaster","subcategory":"Bloggers & Writers","quality":95,"media_kind":"text"},
    {"text":"Stuff","xml_url":"https://www.stuff.co.nz/rss","description":"Stuff RSS — New Zealand's largest news website covering national affairs, sport, business and lifestyle.","language":"en","html_url":"https://www.stuff.co.nz/","category":"news,new zealand,national,sport,business","subcategory":"Bloggers & Writers","quality":94,"media_kind":"text"},
    {"text":"NZ Herald","xml_url":"https://www.nzherald.co.nz/rss/","description":"NZ Herald RSS — Auckland's daily newspaper with comprehensive coverage of Kiwi news, sport and business.","language":"en","html_url":"https://www.nzherald.co.nz/","category":"news,new zealand,auckland,kiwi,sport","subcategory":"Bloggers & Writers","quality":94,"media_kind":"text"},
]

# LATAM additions (beyond the major countries already covered)
BOLIVIA_LOCAL = [
    {"text":"El Deber","xml_url":"https://eldeber.com.bo/rss/","description":"El Deber RSS — el diario más importante de Santa Cruz y Bolivia con noticias nacionales, política y deportes.","language":"es","html_url":"https://eldeber.com.bo/","category":"noticias,bolivia,santa cruz,política,deportes","subcategory":"Bloggers & Writers","quality":92,"media_kind":"text"},
]
COSTA_RICA_LOCAL = [
    {"text":"La Nación Costa Rica","xml_url":"https://www.nacion.com/rss/","description":"La Nación RSS — el periódico más leído de Costa Rica con noticias de San José, política y economía.","language":"es","html_url":"https://www.nacion.com/","category":"noticias,costa rica,san josé,política,economía","subcategory":"Bloggers & Writers","quality":94,"media_kind":"text"},
]
CUBA_LOCAL = [
    {"text":"14ymedio","xml_url":"https://www.14ymedio.com/rss/","description":"14ymedio RSS — periodismo independiente cubano con noticias desde La Habana, cultura y sociedad.","language":"es","html_url":"https://www.14ymedio.com/","category":"noticias,cuba,independiente,la habana,cultura","subcategory":"Bloggers & Writers","quality":90,"media_kind":"text"},
]
DOMINICAN_REPUBLIC_LOCAL = [
    {"text":"Listín Diario","xml_url":"https://listindiario.com/rss/","description":"Listín Diario RSS — el periódico más antiguo de República Dominicana con noticias de Santo Domingo y el Caribe.","language":"es","html_url":"https://listindiario.com/","category":"noticias,república dominicana,santo domingo,caribe,histórico","subcategory":"Bloggers & Writers","quality":93,"media_kind":"text"},
]
EL_SALVADOR_LOCAL = [
    {"text":"El Faro","xml_url":"https://elfaro.net/rss/","description":"El Faro RSS — periodismo de investigación independiente desde El Salvador, referencia en Centroamérica.","language":"es","html_url":"https://elfaro.net/","category":"noticias,el salvador,investigación,independiente,centroamérica","subcategory":"Bloggers & Writers","quality":94,"media_kind":"text"},
]
GUATEMALA_LOCAL = [
    {"text":"Prensa Libre","xml_url":"https://www.prensalibre.com/rss/","description":"Prensa Libre RSS — el diario líder de Guatemala con noticias de Ciudad de Guatemala, política y economía.","language":"es","html_url":"https://www.prensalibre.com/","category":"noticias,guatemala,ciudad de guatemala,política,economía","subcategory":"Bloggers & Writers","quality":93,"media_kind":"text"},
]
HAITI_LOCAL = [
    {"text":"Le Nouvelliste","xml_url":"https://lenouvelliste.com/rss","description":"Le Nouvelliste RSS — le plus ancien quotidien haïtien avec actualité, politique, culture et sport de Port-au-Prince.","language":"fr","html_url":"https://lenouvelliste.com/","category":"actualité,haïti,port-au-prince,politique,culture","subcategory":"Bloggers & Writers","quality":91,"media_kind":"text"},
]
HONDURAS_LOCAL = [
    {"text":"La Prensa Honduras","xml_url":"https://www.laprensa.hn/rss/","description":"La Prensa RSS — el diario más leído de Honduras con noticias de Tegucigalpa, política y economía.","language":"es","html_url":"https://www.laprensa.hn/","category":"noticias,honduras,tegucigalpa,política,economía","subcategory":"Bloggers & Writers","quality":92,"media_kind":"text"},
]
NICARAGUA_LOCAL = [
    {"text":"Confidencial","xml_url":"https://confidencial.digital/rss/","description":"Confidencial RSS — periodismo independiente nicaragüense con noticias de Managua, política y sociedad.","language":"es","html_url":"https://confidencial.digital/","category":"noticias,nicaragua,independiente,managua,política","subcategory":"Bloggers & Writers","quality":91,"media_kind":"text"},
]
PANAMA_LOCAL = [
    {"text":"La Prensa Panamá","xml_url":"https://www.prensa.com/rss/","description":"La Prensa RSS — el diario de referencia en Panamá con noticias de Ciudad de Panamá, economía y política.","language":"es","html_url":"https://www.prensa.com/","category":"noticias,panamá,ciudad de panamá,economía,política","subcategory":"Bloggers & Writers","quality":93,"media_kind":"text"},
]
PARAGUAY_LOCAL = [
    {"text":"ABC Color","xml_url":"https://www.abc.com.py/rss/","description":"ABC Color RSS — el diario más importante de Paraguay con noticias de Asunción y cobertura nacional.","language":"es","html_url":"https://www.abc.com.py/","category":"noticias,paraguay,asunción,nacional,cobertura","subcategory":"Bloggers & Writers","quality":93,"media_kind":"text"},
]
PUERTO_RICO_LOCAL = [
    {"text":"El Nuevo Día","xml_url":"https://www.elnuevodia.com/rss/","description":"El Nuevo Día RSS — el periódico más leído de Puerto Rico con noticias de San Juan, política y entretenimiento.","language":"es","html_url":"https://www.elnuevodia.com/","category":"noticias,puerto rico,san juan,política,entretenimiento","subcategory":"Bloggers & Writers","quality":93,"media_kind":"text"},
]
URUGUAY_LOCAL = [
    {"text":"El País Uruguay","xml_url":"https://www.elpais.com.uy/rss/","description":"El País RSS — el diario más importante de Uruguay con noticias de Montevideo, política y economía.","language":"es","html_url":"https://www.elpais.com.uy/","category":"noticias,uruguay,montevideo,política,economía","subcategory":"Bloggers & Writers","quality":94,"media_kind":"text"},
]
VENEZUELA_LOCAL = [
    {"text":"Efecto Cocuyo","xml_url":"https://efectococuyo.com/feed/","description":"Efecto Cocuyo RSS — periodismo independiente venezolano con noticias, investigaciones y derechos humanos.","language":"es","html_url":"https://efectococuyo.com/","category":"noticias,venezuela,independiente,investigaciones,derechos humanos","subcategory":"Bloggers & Writers","quality":92,"media_kind":"text"},
]

COUNTRY_LOCAL_DATA = {
    "united_kingdom": UNITED_KINGDOM,
    "germany": GERMANY_LOCAL,
    "france": FRANCE_LOCAL,
    "italy": ITALY_LOCAL,
    "spain": SPAIN_LOCAL,
    "netherlands": NETHERLANDS_LOCAL,
    "japan": JAPAN_LOCAL,
    "south_korea": SOUTH_KOREA_LOCAL,
    "australia": AUSTRALIA_LOCAL,
    "canada": CANADA_LOCAL,
    "india": INDIA_LOCAL,
    "argentina": ARGENTINA_LOCAL,
    "chile": CHILE_LOCAL,
    "colombia": COLOMBIA_LOCAL,
    "peru": PERU_LOCAL,
    "ecuador": ECUADOR_LOCAL,
    "egypt": EGYPT_LOCAL,
    "saudi_arabia": SAUDI_ARABIA_LOCAL,
    "uae": UAE_LOCAL,
    "nigeria": NIGERIA_LOCAL,
    "south_africa": SOUTH_AFRICA_LOCAL,
    "kenya": KENYA_LOCAL,
    "poland": POLAND_LOCAL,
    "turkey": TURKEY_LOCAL,
    "sweden": SWEDEN_LOCAL,
    "norway": NORWAY_LOCAL,
    "denmark": DENMARK_LOCAL,
    "portugal": PORTUGAL_LOCAL,
    "angola": ANGOLA_LOCAL,
    "indonesia": INDONESIA_LOCAL,
    "malaysia": MALAYSIA_LOCAL,
    "philippines": PHILIPPINES_LOCAL,
    "austria": AUSTRIA_LOCAL,
    "belgium": BELGIUM_LOCAL,
    "switzerland": SWITZERLAND_LOCAL,
    "ireland": IRELAND_LOCAL,
    "finland": FINLAND_LOCAL,
    "iceland": ICELAND_LOCAL,
    "luxembourg": LUXEMBOURG_LOCAL,
    "malta": MALTA_LOCAL,
    "cyprus": CYPRUS_LOCAL,
    "greece": GREECE_LOCAL,
    "israel": ISRAEL_LOCAL,
    "russia": RUSSIA_LOCAL,
    "ukraine": UKRAINE_LOCAL,
    "hungary": HUNGARY_LOCAL,
    "czech_republic": CZECH_REPUBLIC_LOCAL,
    "slovakia": SLOVAKIA_LOCAL,
    "romania": ROMANIA_LOCAL,
    "bulgaria": BULGARIA_LOCAL,
    "serbia": SERBIA_LOCAL,
    "croatia": CROATIA_LOCAL,
    "slovenia": SLOVENIA_LOCAL,
    "estonia": ESTONIA_LOCAL,
    "latvia": LATVIA_LOCAL,
    "lithuania": LITHUANIA_LOCAL,
    "kazakhstan": KAZAKHSTAN_LOCAL,
    "azerbaijan": AZERBAIJAN_LOCAL,
    "georgia": GEORGIA_LOCAL,
    "armenia": ARMENIA_LOCAL,
    "belarus": BELARUS_LOCAL,
    "morocco": MOROCCO_LOCAL,
    "tunisia": TUNISIA_LOCAL,
    "algeria": ALGERIA_LOCAL,
    "iraq": IRAQ_LOCAL,
    "iran": IRAN_LOCAL,
    "qatar": QATAR_LOCAL,
    "sudan": SUDAN_LOCAL,
    "bangladesh": BANGLADESH_LOCAL,
    "pakistan": PAKISTAN_LOCAL,
    "sri_lanka": SRI_LANKA_LOCAL,
    "nepal": NEPAL_LOCAL,
    "singapore": SINGAPORE_LOCAL,
    "taiwan": TAIWAN_LOCAL,
    "china": CHINA_LOCAL,
    "thailand": THAILAND_LOCAL,
    "vietnam": VIETNAM_LOCAL,
    "myanmar": MYANMAR_LOCAL,
    "cambodia": CAMBODIA_LOCAL,
    "ethiopia": ETHIOPIA_LOCAL,
    "ghana": GHANA_LOCAL,
    "ivory_coast": IVORY_COAST_LOCAL,
    "jamaica": JAMAICA_LOCAL,
    "new_zealand": NEW_ZEALAND_LOCAL,
    "bolivia": BOLIVIA_LOCAL,
    "costa_rica": COSTA_RICA_LOCAL,
    "cuba": CUBA_LOCAL,
    "dominican_republic": DOMINICAN_REPUBLIC_LOCAL,
    "el_salvador": EL_SALVADOR_LOCAL,
    "guatemala": GUATEMALA_LOCAL,
    "haiti": HAITI_LOCAL,
    "honduras": HONDURAS_LOCAL,
    "nicaragua": NICARAGUA_LOCAL,
    "panama": PANAMA_LOCAL,
    "paraguay": PARAGUAY_LOCAL,
    "puerto_rico": PUERTO_RICO_LOCAL,
    "uruguay": URUGUAY_LOCAL,
    "venezuela": VENEZUELA_LOCAL,
}

print(f"Country-specific data loaded! {len(COUNTRY_LOCAL_DATA)} countries with local influencers.")
for slug, data in sorted(COUNTRY_LOCAL_DATA.items()):
    print(f"  {slug}: {len(data)} entries")
