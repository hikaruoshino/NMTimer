-- NMTimer の同梱データ (エンピリアン武器のメイジャンの試練に出る NM と、ヴァナ・ディールの異変の NM のうち、再出現を数えたいもの)。
-- ユーザー自身が足した NM は data/user.lua に保存される (このファイルは更新で上書きされてよい)。
--
-- 項目:
--   key        内部の名前 (小文字・英数字と _)。コマンドで NM を指すときにも使える
--   name       表示する名前 (英語)
--   alias      ほかの名前 (日本語クライアントでの表示名など)。分かっているものだけ。足りなければ //nmt alias で足せる
--   kind       "lottery" = 抽選型 (PH を倒すと NM が出る。NM を倒してから一定時間は抽選が始まらない)
--              "timed"   = 時間型 (倒してから一定時間で再出現する)
--   zones      出るエリア (英語名。res/zones.lua の en と同じ)
--   ph         抽選型の PH の名前 (英語)。倒したことを覚えるのに使う
--   min, max   分。抽選型は「NM を倒してから抽選が始まるまで」、時間型は「再出現まで」。max は幅があるものだけ
--   approx     true のとき、数字は目安 (wiki の記述があいまい)。実測で直せる
--   ph_repop   抽選型: PH を倒してから次の PH が湧くまでの分
--   job        アビセアンの NM のジョブ (表示用)
--   hint       見つけ方・抽選の対象の見分け方 (表示用)
--   src        出どころ (wiki.ffo.jp の記事)。文章は写さず、数字と名前だけを使っている
--
-- 数字は wiki の記述で、ゲーム内では未確認 (2026-10-16 時点)。

local S = "https://wiki.ffo.jp/html/"

local data = {
    ---------------------------------------------------------------------------
    -- ヴァナ・ディールの異変を調査せよ (イベント。第1回 2026-03、第2回 2026-05〜、第3回 2026-09〜10。次回は未定)
    -- 倒すと宝箱が出て、10分で消える。再出現は宝箱の消失から45分後 = 討伐 (HPゲージが黒くなった時点) から55分
    -- (ページ作成者の実測 55分00秒)。公式の案内は「約45分後」で、実測とずれがある
    ---------------------------------------------------------------------------
    {key = "kirin_event", name = "Kirin", kind = "timed", min = 55,
     zones = {"Ru'Aun Gardens"},
     hint = "ル・オンの庭 H-9〜H-10付近。早いと3分弱で倒される",
     src = S .. "39989.html"},
    {key = "fafnir_event", name = "Fafnir", kind = "timed", min = 55,
     zones = {"The Boyahda Tree"},
     hint = "ボヤーダ樹 G-7〜I-9付近。雷の回廊の通路入口側にブレスを向けさせない",
     src = S .. "39989.html"},
    {key = "alexander_event", name = "Alexander", kind = "timed", min = 55,
     zones = {"Alzadaal Undersea Ruins"},
     hint = "アルザダール海底遺跡群の各遺構入口前。出現場所は完全ランダム(見つけたらシャウト)",
     src = S .. "39989.html"},

    ---------------------------------------------------------------------------
    -- 抽選型 (メイジャン 格闘/片手斧/両手槍/ほか の 3〜4 体討伐に出る NM)
    ---------------------------------------------------------------------------
    {key = "tumbling_truffle", name = "Tumbling Truffle", kind = "lottery",
     zones = {"La Theine Plateau"}, ph = {"Poison Funguar"}, min = 18, approx = true,
     hint = "K-6の谷底(H-7から降りる)。南の谷の3体のうち、広域スキャンの最上位が対象",
     src = S .. "11812.html"},
    {key = "helldiver", name = "Helldiver", kind = "lottery",
     zones = {"Buburimu Peninsula"}, ph = {"Zu"}, min = 30, approx = true,
     hint = "K-9〜L-9。Zuは東側2体のうち、広域スキャンで下側が対象",
     src = S .. "11994.html"},
    {key = "orctrap", name = "Orctrap", kind = "lottery",
     zones = {"Carpenters' Landing"}, ph = {"Birdtrap"}, min = 60,
     hint = "I-9・I-10付近。Birdtrapの3匹グループの最上位が対象",
     src = S .. "12457.html"},
    {key = "intulo", name = "Intulo", kind = "lottery",
     zones = {"Bibiki Bay"}, ph = {"Eft"}, min = 60,
     hint = "H-7の坂。広域スキャンで並ぶ鳥3匹の下にいるEftが対象",
     src = S .. "12528.html"},
    {key = "ramponneau", name = "Ramponneau", kind = "lottery",
     zones = {"West Sarutabaruta [S]"}, ph = {"Toad"}, min = 90, ph_repop = 5,
     hint = "I-9の南西。Toadが4匹連続で並ぶ最上位が対象",
     src = S .. "18823.html"},
    {key = "keeper_of_halidom", name = "Keeper of Halidom", kind = "lottery",
     zones = {"The Sanctuary of Zi'Tah"}, ph = {"Goobbue Gardener"}, min = 60, ph_repop = 5,
     hint = "J-9から地図にない道を進んだJ-7付近。2匹見えたら下側が対象",
     src = S .. "8864.html"},

    -- 両手剣の試練 (サンブレード 攻+3)。再抽選は 5 分 (2013-11-05 の更新前は 60 分)
    {key = "golden_bat", name = "Golden Bat", kind = "lottery",
     zones = {"Valkurm Dunes"}, ph = {"Giant Bat"}, min = 5,
     hint = "B-8 グスタフの洞門の入り口前。Giant Bat 2匹のうち広域スキャンで上側が対象。(C-7)か(B-8)の洞窟に出る",
     src = S .. "11055.html"},

    ---------------------------------------------------------------------------
    -- メイジャンの試練: 武器の最初の段階の NM (3〜4 体討伐)。2013-11-05 の更新で抽選までの時間が短縮された NM が多く、
    -- 数字があいまいなものは approx = true (目安)。分からないものは min を書かず、使う人が //nmt time で決める
    ---------------------------------------------------------------------------
    {key = "nocuous_weapon", name = "Nocuous Weapon", kind = "lottery", zones = {"Inner Horutoto Ruins"}, ph = {"Boggart"}, min = 15, approx = true, hint = "I-9の東側の柱の周り。広域スキャンで2匹のWill-o'-the-Wispに挟まれた6匹のうち、柱の周りの3匹が対象", src = S .. "18691.html"},
    {key = "black_triple_stars", name = "Black Triple Stars", kind = "lottery", zones = {"Rolanberry Fields"}, ph = {"Midnight Wings"}, min = 45, approx = true, hint = "夜間(18:00〜6:00)だけ。北(I-9)か南(I-10〜I-11)の4匹のグループの最上位が対象", src = S .. "10740.html"},
    {key = "serra", name = "Serra", kind = "lottery", zones = {"Bibiki Bay"}, ph = {"Jagil"}, min = 15, ph_repop = 5, hint = "プルゴノルゴ島のF-9(西海岸)。Coralline UragniteとCoastal Opo-opoに挟まれたJagilが対象", src = S .. "12526.html"},
    {key = "bugbear_strongman", name = "Bugbear Strongman", kind = "lottery", zones = {"Oldton Movalpolos"}, ph = {"Bugbear Bondman"}, min = 60, ph_repop = 14, hint = "I-11の北側かJ-11の東側。見張り3体のうち、そこに湧くものが対象", src = S .. "15131.html"},
    {key = "la_velue", name = "La Velue", kind = "lottery", zones = {"Batallia Downs [S]"}, ph = {"Smilodon"}, min = 60, ph_repop = 5, hint = "G-7〜G-8の東側。H-8で広域スキャンして、Smilodonが並ぶ列の上から10番目が対象", src = S .. "14837.html"},
    {key = "hovering_hotpot", name = "Hovering Hotpot", kind = "lottery", zones = {"Garlaige Citadel"}, ph = {"Fallen Major", "Fallen Mage"}, min = 10, ph_repop = 5, hint = "2門奥の装置の前(J-8)。Fallen***が3匹並び、2匹いるほうが対象", src = S .. "18728.html"},
    {key = "serpopard_ishtar", name = "Serpopard Ishtar", kind = "lottery", zones = {"Tahrongi Canyon"}, ph = {"Wild Dhalmel"}, min = 26, approx = true, hint = "H-8とH-6付近。各グループの一番上が対象。討伐から26分で再抽選の報告", src = S .. "11493.html"},
    {key = "tottering_toby", name = "Tottering Toby", kind = "lottery", zones = {"Batallia Downs"}, ph = {"Stalking Sapling"}, min = 10, approx = true, hint = "G-6/G-7。上側のStalking Saplingが対象(下側も倒すと確実)。10〜15分の報告", src = S .. "12119.html"},
    {key = "drooling_daisy", name = "Drooling Daisy", kind = "lottery", zones = {"Rolanberry Fields"}, ph = {"Ochu"}, min = 15, approx = true, hint = "D-11。Ochuは1匹だけ。約15分の報告", src = S .. "12104.html"},
    {key = "gargantua", name = "Gargantua", kind = "lottery", zones = {"Beaucedine Glacier"}, ph = {"Stone Golem"}, min = 8, approx = true, ph_repop = 5, hint = "J-8の最下段。Tundra Tiger3体・Goblin Poacher・Goblin Traderの並びの4番目のStone Golemが対象", src = S .. "5791.html"},
    {key = "megalobugard", name = "Megalobugard", kind = "lottery", zones = {"Lufaise Meadows"}, ph = {"Gigantobugard"}, min = 60, hint = "G-8(下段)。G-7〜H-7(上段)にも出る。広域スキャンで対象を見分ける", src = S .. "12459.html"},
    {key = "ratatoskr", name = "Ratatoskr", kind = "lottery", zones = {"Fort Karugo-Narugo [S]"}, ph = {"Vorpal Bunny"}, min = 60, ph_repop = 5, hint = "H-10〜H-11。北側3匹のうち、スキャンの一番上が対象(南の2匹は対象外)", src = S .. "18624.html"},
    {key = "bloodpool_vorax", name = "Bloodpool Vorax", kind = "lottery", zones = {"Pashhow Marshlands"}, ph = {"Thread Leech"}, min = 16, approx = true, hint = "F-5。広場のリーチ5匹のうち一番上が対象。討伐後約16分の報告", src = S .. "8862.html"},
    {key = "slippery_sucker", name = "Slippery Sucker", kind = "lottery", zones = {"Qufim Island"}, min = 16, approx = true, hint = "H-8付近。巨人族(ランダム)との抽選。スキャンの巨人の列の一番下が対象", src = S .. "18712.html"},
    {key = "seww_the_squidlimbed", name = "Seww the Squidlimbed", kind = "lottery", zones = {"Sea Serpent Grotto"}, ph = {"Riparian Sahagin"}, min = 60, hint = "獣人銀貨で開ける扉の先のF-7〜G-7。Riparian Sahaginは1匹だけ", src = S .. "18857.html"},
    {key = "ankabut", name = "Ankabut", kind = "lottery", zones = {"North Gustaberg [S]"}, ph = {"Huge Spider"}, min = 90, hint = "L-7の高台。Huge Spider3匹のうち、スキャンの一番上が対象", src = S .. "18775.html"},
    {key = "okyupete", name = "Okyupete", kind = "lottery", zones = {"Misareaux Coast"}, ph = {"Diatryma"}, min = 60, approx = true, hint = "G-6〜G-5(南側)。Diatryma4匹の一番上が対象。60分・90〜120分・104分の報告", src = S .. "18771.html"},
    {key = "panzer_percival", name = "Panzer Percival", kind = "lottery", zones = {"Jugner Forest"}, ph = {"Stag Beetle"}, min = 60, hint = "J-5付近とL-7付近の2か所(別々に抽選)。1匹多いときのスキャンの一番上が対象", src = S .. "3947.html"},
    {key = "gedha_evileye", name = "Ge'Dha Evileye", kind = "lottery", zones = {"Beadeaux"}, ph = {"Old Quadav"}, min = 20, approx = true, hint = "E-11の高台の下。Old Quadav2匹のうち、スキャンの下側が対象。遅くとも20分", src = S .. "981.html"},
    {key = "bashe", name = "Bashe", kind = "lottery", zones = {"Sauromugue Champaign"}, ph = {"Hill Lizard"}, min = 0, approx = true, ph_repop = 5, hint = "L-8〜L-9の段差の上。トカゲ3匹のうち、スキャンの一番上が対象。討伐後すぐに抽選が始まる", src = S .. "18720.html"},
    {key = "hoo_mjuu_the_torrent", name = "Hoo Mjuu the Torrent", kind = "lottery", zones = {"Giddeus"}, ph = {"Yagudo Mendicant"}, min = 60, approx = true, hint = "H-10の高台。Yagudo Mendicant(召喚士)のうち、スキャンの一番下が対象。すぐ湧く場合もある", src = S .. "6132.html"},
    {key = "daggerclaw_dracos", name = "Daggerclaw Dracos", kind = "lottery", zones = {"Meriphataud Mountains"}, ph = {"Raptor"}, min = 30, approx = true, ph_repop = 5, hint = "K-9〜K-11の広場(抽選はK-10中央〜南)。鳥とゴブリンに挟まれた3匹の1番目が対象。30分の報告", src = S .. "12106.html"},
    {key = "namtar", name = "Namtar", kind = "lottery", zones = {"Sea Serpent Grotto"}, ph = {"Ghast"}, min = 60, hint = "D-8の広場。Ghastが「5・3」か「4・4」に並ぶ。上(または下)のグループの一番下が対象", src = S .. "13572.html"},
    {key = "barbastelle", name = "Barbastelle", kind = "timed", zones = {"King Ranperre's Tomb"}, min = 15, max = 20, hint = "階段を上がった地上部(J-6付近)。単独のNM。前回の討伐から15〜20分", src = S .. "18560.html"},
    {key = "ah_puch", name = "Ah Puch", kind = "lottery", zones = {"Outer Horutoto Ruins"}, ph = {"Ghoul"}, min = 30, approx = true, hint = "アマリリスの塔の2枚目のマップG-8付近。周囲のGhoul7匹のうちランダムな1匹が対象", src = S .. "18711.html"},
    {key = "donggu", name = "Donggu", kind = "lottery", zones = {"Ordelle's Caves"}, ph = {"Fly Agaric"}, min = 15, hint = "MAP[4]のH-7(ラテーヌ高原F-7から入る)。Fly Agaric4匹のうち、スキャンの一番上が対象", src = S .. "18706.html"},
    {key = "slendlix_spindlethumb", name = "Slendlix Spindlethumb", kind = "lottery", zones = {"Inner Horutoto Ruins"}, ph = {"Goblin Leecher"}, min = 15, approx = true, hint = "MAP2のD-11、隠し通路の先の部屋。部屋の外の対象を先に倒す。長くても15分以下", src = S .. "18694.html"},
    {key = "herbage_hunter", name = "Herbage Hunter", kind = "lottery", zones = {"Tahrongi Canyon"}, ph = {"Canyon Crawler"}, min = 30, approx = true, hint = "G-5。Canyon Crawlerは1匹だけ。長くても30分以下(要検証)", src = S .. "18479.html"},
    {key = "kirata", name = "Kirata", kind = "lottery", zones = {"Beaucedine Glacier"}, ph = {"Tundra Tiger"}, min = 15, approx = true, hint = "H-10の魔法塔の周り。Tundra Tigerのうち、スキャンの下側が対象", src = S .. "11960.html"},
    {key = "zighi_boneeater", name = "Zi'Ghi Boneeater", kind = "lottery", zones = {"Palborough Mines"}, ph = {"Veteran Quadav"}, min = 16, approx = true, ph_repop = 8, hint = "3FのH-7〜H-8。Old ToolBoxが無い側の小部屋。16分で出た報告", src = S .. "11514.html"},
    {key = "lumbering_lambert", name = "Lumbering Lambert", kind = "lottery", zones = {"La Theine Plateau"}, ph = {"Battering Ram"}, min = 30, approx = true, hint = "G-9〜I-9付近。東側のBattering Ramが対象(西側は対象外)。30分で出た報告", src = S .. "3952.html"},
    {key = "deadly_dodo", name = "Deadly Dodo", kind = "lottery", zones = {"Sauromugue Champaign"}, ph = {"Tabar Beak"}, hint = "I-6〜K-6。Tabar Beak2匹のうち、スキャンの上側が対象。短縮後の時間は不明(//nmt time で決める)", src = S .. "9038.html"},
    {key = "vuu_puqu_the_beguiler", name = "Vuu Puqu the Beguiler", kind = "lottery", zones = {"Giddeus"}, ph = {"Yagudo Piper"}, min = 20, hint = "H-14の最奥の広場。Yagudo Piperだけが対象", src = S .. "14540.html"},
    {key = "buburimboo", name = "Buburimboo", kind = "lottery", zones = {"Buburimu Peninsula"}, ph = {"Shoal Pugil"}, min = 15, approx = true, hint = "K-7のミゴヤ砂浜。Shoal Pugil4匹のうち、スキャンの一番下が対象。遅くとも15分", src = S .. "11993.html"},
    {key = "zokhu_blackcloud", name = "Zo'Khu Blackcloud", kind = "lottery", zones = {"Beadeaux"}, ph = {"Zircon Quadav"}, min = 20, approx = true, ph_repop = 12, hint = "E-11〜F-11の高台の上。最大20分", src = S .. "3955.html"},
    {key = "stray_mary", name = "Stray Mary", kind = "lottery", zones = {"Konschtat Highlands"}, ph = {"Mad Sheep"}, min = 40, approx = true, hint = "F-6とF-9の風車付近の2か所。F-6は5匹の一番上、F-9は上から2番目が対象。40分以下", src = S .. "3949.html"},
    {key = "hawkeyed_dnatbat", name = "Hawkeyed Dnatbat", kind = "lottery", zones = {"Davoi"}, ph = {"Orcish Cursemaker"}, min = 20, approx = true, hint = "L-8〜L-9の池から通路周辺。約20分で出た報告", src = S .. "6435.html"},
    {key = "dune_widow", name = "Dune Widow", kind = "lottery", zones = {"Eastern Altepa Desert"}, ph = {"Giant Spider"}, min = 60, hint = "G-8の中央。Sabotenderの下にGiant Spiderが2匹並び、上側が対象", src = S .. "12765.html"},
    {key = "teporingo", name = "Teporingo", kind = "lottery", zones = {"Dangruf Wadi"}, ph = {"Hoarder Hare"}, min = 10, approx = true, hint = "H-9〜I-9。3匹のうち、スキャンの一番下が対象。10分で出た報告", src = S .. "18710.html"},
    {key = "valkurm_emperor", name = "Valkurm Emperor", kind = "lottery", zones = {"Valkurm Dunes"}, ph = {"Damselfly"}, min = 15, approx = true, ph_repop = 5, hint = "西海岸のE-8付近。Snipper・Thread Leechに挟まれた4匹の一番上が対象。約15分", src = S .. "2662.html"},
    {key = "hyakume", name = "Hyakume", kind = "lottery", zones = {"Ranguemont Pass"}, ph = {"Hecteyes"}, min = 18, approx = true, ph_repop = 5, hint = "J-8。Hecteyes5匹のうち、スキャンの一番上が対象。約18分で出た報告", src = S .. "18722.html"},
    {key = "gloomanita", name = "Gloomanita", kind = "lottery", zones = {"North Gustaberg [S]"}, ph = {"Coppercap"}, min = 60, approx = true, hint = "H-6〜H-7。Rock Eater・Coppercap×5・Rock Eaterの並びの一番下のCoppercapが対象", src = S .. "14880.html"},
    {key = "mischievous_micholas", name = "Mischievous Micholas", kind = "lottery", zones = {"Yuhtunga Jungle"}, ph = {"Young Opo-opo"}, min = 60, hint = "G-9付近(Overgrown Roseの上)。Young Opo-opo10匹の一番下が対象。60分〜3時間", src = S .. "18130.html"},
    {key = "cactuar_cantautor", name = "Cactuar Cantautor", kind = "lottery", zones = {"Western Altepa Desert"}, ph = {"Cactuar"}, min = 60, hint = "F-11〜G-11。昼夜でスキャンの並びが違う。Cactuar2匹の下側が対象", src = S .. "17240.html"},
    {key = "behya_hundredwall", name = "Be'Hya Hundredwall", kind = "lottery", zones = {"Palborough Mines"}, ph = {"Copper Quadav", "Old Quadav"}, min = 20, approx = true, ph_repop = 10, hint = "3FのJ-9の南の小部屋。対象はCopper QuadavかOld Quadav(その都度ランダム)。約20分", src = S .. "18690.html"},
    {key = "jolly_green", name = "Jolly Green", kind = "lottery", zones = {"Pashhow Marshlands"}, ph = {"Goobbue"}, min = 20, hint = "I-7〜I-8とJ-8。Goobbueは1匹だけ(抽選対象の印が付く)", src = S .. "8863.html"},
    {key = "trembler_tabitha", name = "Trembler Tabitha", kind = "lottery", zones = {"Maze of Shakhrami"}, ph = {"Maze Maker"}, min = 15, ph_repop = 5, hint = "F-8の南端(タロンギ大峡谷から入る)。Maze Maker2匹のうち、スキャンの上側が対象", src = S .. "18718.html"},
    {key = "desmodont", name = "Desmodont", kind = "lottery", zones = {"Outer Horutoto Ruins"}, ph = {"Stink Bats"}, min = 15, ph_repop = 5, hint = "アマリリスの塔の最初のマップG-6の小部屋。2匹のうち、スキャンの上が対象", src = S .. "18697.html"},
    {key = "moo_ouzi_the_swiftblade", name = "Moo Ouzi the Swiftblade", kind = "lottery", zones = {"Castle Oztroja"}, ph = {"Yagudo Theologist"}, min = 20, approx = true, ph_repop = 10, hint = "1FのH-9・I-9のL字通路。黒固定のYagudo Theologistが対象。20分で出た報告", src = S .. "14309.html"},
    {key = "nizho_bladebender", name = "Ni'Zho Bladebender", kind = "lottery", zones = {"Pashhow Marshlands"}, ph = {"Veteran Quadav"}, min = 15, approx = true, ph_repop = 5, hint = "E-11〜I-10の道沿い(広範囲)。クゥダフ5匹の列に加わって6匹になる1匹が対象。約15分", src = S .. "18885.html"},

    ---------------------------------------------------------------------------
    -- 時間型: アビセアン (第二段階。各エリアに1体。撃破後 約1時間。不可視でヒーリングで探す)
    ---------------------------------------------------------------------------
    {key = "capricornus", name = "Capricornus", job = "戦", kind = "timed", min = 60, approx = true,
     zones = {"East Ronfaure", "East Ronfaure [S]", "Jugner Forest", "Jugner Forest [S]"}, src = S .. "19626.html"},
    {key = "yacumama", name = "Yacumama", job = "モ", kind = "timed", min = 60, approx = true,
     zones = {"East Ronfaure", "East Ronfaure [S]", "Jugner Forest", "Jugner Forest [S]"}, src = S .. "19626.html"},
    {key = "lamprey_lord", name = "Lamprey Lord", job = "暗", kind = "timed", min = 60, approx = true,
     zones = {"North Gustaberg", "North Gustaberg [S]", "Pashhow Marshlands", "Pashhow Marshlands [S]"}, src = S .. "19626.html"},
    {key = "shoggoth", name = "Shoggoth", job = "赤", kind = "timed", min = 60, approx = true,
     zones = {"North Gustaberg", "North Gustaberg [S]", "Pashhow Marshlands", "Pashhow Marshlands [S]"}, src = S .. "19626.html"},
    {key = "jyeshtha", name = "Jyeshtha", job = "戦", kind = "timed", min = 60, approx = true,
     zones = {"West Sarutabaruta", "West Sarutabaruta [S]", "Meriphataud Mountains", "Meriphataud Mountains [S]"}, src = S .. "19626.html"},
    {key = "farruca_fly", name = "Farruca Fly", job = "シ", kind = "timed", min = 60, approx = true,
     zones = {"West Sarutabaruta", "West Sarutabaruta [S]", "Meriphataud Mountains", "Meriphataud Mountains [S]"}, src = S .. "19626.html"},
    {key = "skuld", name = "Skuld", job = "赤", kind = "timed", min = 60, approx = true,
     zones = {"Batallia Downs", "Batallia Downs [S]", "Rolanberry Fields", "Rolanberry Fields [S]",
              "Sauromugue Champaign", "Sauromugue Champaign [S]"}, src = S .. "19626.html"},
    {key = "urd", name = "Urd", job = "踊", kind = "timed", min = 60, approx = true,
     zones = {"Batallia Downs", "Batallia Downs [S]", "Rolanberry Fields", "Rolanberry Fields [S]",
              "Sauromugue Champaign", "Sauromugue Champaign [S]"}, src = S .. "19626.html"},
    {key = "erebus", name = "Erebus", job = "黒", kind = "timed", min = 60, approx = true,
     zones = {"Beaucedine Glacier", "Beaucedine Glacier [S]", "Xarcabard", "Xarcabard [S]"}, src = S .. "19626.html"},
    {key = "feuerunke", name = "Feuerunke", job = "モ", kind = "timed", min = 60, approx = true,
     zones = {"Beaucedine Glacier", "Beaucedine Glacier [S]", "Xarcabard", "Xarcabard [S]"}, src = S .. "19626.html"},
    {key = "chesma", name = "Chesma", kind = "timed", min = 60, approx = true,
     zones = {"La Theine Plateau", "Konschtat Highlands", "Tahrongi Canyon"}, src = S .. "19626.html"},
    {key = "tammuz", name = "Tammuz", kind = "timed", min = 60, approx = true,
     zones = {"La Theine Plateau", "Konschtat Highlands", "Tahrongi Canyon"}, src = S .. "19626.html"},

    ---------------------------------------------------------------------------
    -- 時間型: 覇者のアビセアエリアの第三段階 (無色の魂)。Brulo・Maere は未調査のため入れていない
    ---------------------------------------------------------------------------
    {key = "ogopogo", name = "Ogopogo", kind = "timed", min = 15, max = 20,
     zones = {"Abyssea - Uleguerand"},
     hint = "三日月形の緋色のジェイド。アクロリス(H-8)・ギア(G-9)付近",
     src = S .. "22875.html"},
}

return data
