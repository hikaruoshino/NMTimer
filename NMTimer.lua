-- =============================================================================
-- NMTimer.lua : NM の再出現タイマー (v0.6.0)
-- =============================================================================
-- 【目的】
-- メイジャンの試練 (エンピリアン武器) に出る NM などが倒されたとき、その時刻と場所を覚え、
-- 次に出られるまでの残り時間を HUD に出す。先に誰かに倒されて間に合わなかった NM も、
-- 倒された時刻と場所が分かれば次を狙える。
--
-- 【覚えるもの】
--   - 抽選型 (lottery) : PH を倒すと NM が出る型。NM を倒してから、一定時間は抽選が始まらない。その時間を数える
--   - 時間型 (timed)   : 倒してから一定時間で再出現する型 (アビセアンなど)
--   ※ 同梱の NM は nm_data.lua (メイジャン・異変) と nm_data_bgwiki.lua (BG-Wiki のエリアごと)。自分で足した NM は data/user.lua に保存する (//nmt add)
--
-- 【動き】
--   - 敵の更新パケット (0x00E) で、敵が倒れた (状態 2 か 3) ことを知る。自分の画面に映る範囲の討伐だけ分かる。
--     見ていない討伐は、シャウトなどで知ったあとに //nmt tod で手で記録する
--   - 受け取るだけで、ゲームのサーバーへ送る操作は一切しない
--   - 時刻は実時間 (os.time) なので、ログアウトしても、エリアを変えても数え続ける (data/state.lua に保存)
--   - 倒した場所の座標を覚える。同じ名前の敵が同じエリアで再び現れたら、何分で出たかを実測として覚える
--     (その間エリアを離れていなかったときだけ)
--   - PH (抽選の対象の敵) も、倒した時刻と敵の ID を覚える。敵の ID は湧く場所ごとに決まっているので、同じ ID が再び現れた
--     時刻との差が、その PH の再湧き時間の実測になる。実測は ID とエリアを付けて 10 回分まで覚える。
--     その ID の実測があればそれ (個体ごとに違うことがある)、なければそのエリアの実測の中央値を使う。
--     PH が何体いても (ID が違う 2 体のどちらかが抽選の対象、など) //nmt ph で何体でも登録できる。
--     PH ではない敵を数えてしまったときは //nmt ph del で外せる
--   - 同梱データは敵の ID を持たない。名前つきの更新 (敵が現れたとき) で、登録した NM と名前が合えば、その ID を覚える
--     (エリアにいるあいだだけ。同じ ID に別の名前が現れたら捨てる)。倒れたとき名前が読めなくても、覚えた ID の NM なら記録する
--   - 時間が分からない NM (BG-Wiki に数字が無いもの) は、実測から時間を決める (抽選型は最短・時間型は中央値。3 分未満の実測は使わない)。
--     時間が分からないままの記録は、HUD に 3 時間残す。BG-Wiki のデータの PH は、//nmt ph で指定するまで数えない
--
-- 【文字コード】
--   - HUD (libs/texts.lua) : UTF-8
--   - チャット (windower.add_to_chat) : Shift-JIS (windower.to_shift_jis)
-- =============================================================================

_addon.name     = "NMTimer"
_addon.author   = "hikaruoshino"
_addon.version  = "0.6.3"
_addon.commands = {"nmtimer", "nmt"}

local config = require("config")
local texts  = require("texts")
local res    = require("resources")

-- -----------------------------------------------------------------------------
-- 設定 (data/settings.xml)
-- -----------------------------------------------------------------------------
local defaults = {}
defaults.pos = {x = 40, y = 300}
defaults.text = {font = "Meiryo", size = 10, alpha = 255}
defaults.bg = {alpha = 180, red = 10, green = 10, blue = 15}
defaults.padding = 6
defaults.show = true        -- HUD を出す
defaults.sound = true       -- 音を鳴らす (sounds/ready.wav があるとき)
defaults.chat = true        -- 知らせをチャットログにも出す
defaults.lead_min = 5       -- 出られる何分前に知らせるか (0 で前もっての知らせなし)
defaults.expire_min = 30    -- 出られるようになってから、HUD に残す分
defaults.coord = true       -- HUD に討伐した座標と距離を出す (行が長くて切れるときはオフ)
defaults.debug = false      -- 倒れた敵の名前をチャットに出す (名前の別名を探すとき用)

local settings = config.load(defaults)

local DATA_DIR   = windower.addon_path .. "data/"
local STATE_FILE = DATA_DIR .. "state.lua"
local USER_FILE  = DATA_DIR .. "user.lua"
local SOUND_FILE = windower.addon_path .. "sounds/ready.wav"

local DEAD_STATUS = {[2] = true, [3] = true}   -- 敵の状態: 2 / 3 = 倒れた (BanishgaPull と同じ扱い)
local SIGHT_MIN_SEC = 60                       -- 倒してからこれより早く現れたものは再出現とみなさない
local PH_NEAR_SQ = 50 * 50                     -- PH の討伐を覚える範囲 (自分から 50 ヤルム。距離は 2 乗で届く。//nmt ph で指定した PH には使わない)
local PH_SIGHT_MIN_SEC = 30                    -- PH を倒してからこれより早く現れたものは再湧きとみなさない
local PH_SLOT_KEEP_SEC = 3 * 3600              -- PH の記録を残す時間 (これを過ぎたら実測にも使わない)
local REFRESH_SEC = 0.5
local LEARN_MIN_SEC = 180                          -- 学習に使う実測の下限。倒してすぐ同名の別の敵が見えただけの短い値で、時間が短く決まるのを防ぐ
local ALIVE_KEEP_SEC = 120                -- 生きている状態を最後に見てから、倒れた更新を討伐とみなす猶予 (これを過ぎたら「見ていない」扱い)
local ALIVE_LIMIT = 4000                 -- alive_seen の件数の上限 (超えたら古いものだけ捨てる)
local UNKNOWN_KEEP_SEC = 3 * 3600                  -- 時間が分からない NM の記録を HUD に残す時間 (出るのを見ない限り終わりが無いので期限を付ける)
local SAVED_LIMIT = 5000                 -- 読み込む記録・学習データ・自分で足した NM の件数の上限 (壊れた・大きすぎる保存で重くしない)
local MEASURE_KEEP = 5                   -- NM ごとに覚える実測の数
local PH_MEASURE_KEEP = 10               -- PH ごとに覚える実測の数
local SAVE_RETRY_SEC = 5                 -- 画面の更新で消えた記録の保存に失敗したとき、次に試すまでの秒数
local FUTURE_SLACK_SEC = 300             -- 時刻 (at) が今よりこれ以上先の記録は使わない (PC の時計を戻したとき・壊れた保存)
local BROKEN_KEEP = 5                    -- 読めなかったファイル (.broken-日時) を、保存先ごとに新しいものからいくつ残すか
local LOGIN_CHECK_SEC = 1                -- ログアウト中に、ログインしたかを見直す間隔 (login イベントが来ないときのため)

-- -----------------------------------------------------------------------------
-- 小さな道具
-- -----------------------------------------------------------------------------
local function sjis(str)
    if not str then return "" end
    return windower.to_shift_jis and windower.to_shift_jis(str) or str
end

local function chat(text, color)
    windower.add_to_chat(color or 207, sjis(text))
end

local function color_text(str, r, g, b)
    return string.format("\\cs(%d,%d,%d)%s\\cr", r, g, b, tostring(str or ""))
end

-- 敵の ID の表示。10 進に、ゾーン内の番号 (下位 12 ビット) を 16 進で添える (マップツールの表記と突き合わせるため)
local function id_tag(id)
    return string.format("%d / 0x%X", id, id % 4096)
end
local function id_tags(ids)
    local t = {}
    for i, id in ipairs(ids) do t[i] = id_tag(id) end
    return t
end

local function fmt_time(sec)
    sec = math.max(0, math.floor(sec + 0.5))
    local h = math.floor(sec / 3600)
    local m = math.floor((sec % 3600) / 60)
    local s = sec % 60
    if h > 0 then return string.format("%d:%02d:%02d", h, m, s) end
    return string.format("%d:%02d", m, s)
end

local function clock_text(t)
    return os.date("%H:%M", t)
end

-- 表に書き出す (数・文字・真偽・入れ子の表だけ)
local function serialize(v, indent)
    indent = indent or ""
    local kind = type(v)
    if kind == "number" then return string.format("%.14g", v) end
    if kind == "boolean" then return tostring(v) end
    if kind == "string" then return string.format("%q", v) end
    if kind ~= "table" then return "nil" end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b)
        if type(a) == type(b) then return a < b end
        return type(a) == "number"
    end)
    local inner = indent .. "    "
    local lines = {}
    for _, k in ipairs(keys) do
        local key
        if type(k) == "number" then
            key = "[" .. string.format("%.14g", k) .. "]"
        elseif tostring(k):match("^[%a_][%w_]*$") then
            key = k
        else
            key = "[" .. string.format("%q", k) .. "]"
        end
        lines[#lines + 1] = inner .. key .. " = " .. serialize(v[k], inner)
    end
    if #lines == 0 then return "{}" end
    return "{\n" .. table.concat(lines, ",\n") .. "\n" .. indent .. "}"
end

local function read_table(path)
    local chunk = loadfile(path)
    if not chunk then return nil end
    setfenv(chunk, {})
    local ok, tbl = pcall(chunk)
    if ok and type(tbl) == "table" then return tbl end
    return nil
end

local function file_present(path)
    local f = io.open(path, "rb")
    if not f then return false end
    f:close()
    return true
end

local function read_text(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

-- 読めなかったファイルを残す名前 (path.broken-日時)。同じ秒に 2 回目があれば -02・-03 … を付けて、前のものと重ねない
local function broken_name(path)
    local base = path .. ".broken-" .. os.date("%Y%m%d-%H%M%S", os.time())
    if not file_present(base) then return base end
    for n = 2, 99 do
        local name = string.format("%s-%02d", base, n)
        if not file_present(name) then return name end
    end
    return nil
end

-- path の .broken- ファイルを、新しい BROKEN_KEEP 個だけ残して消す (名前の日時の順。自分で付けた形の名前だけ)
local function prune_broken(path)
    if type(windower.get_dir) ~= "function" then return end
    local dir, file = path:match("^(.*)[/\\]([^/\\]+)$")
    if not dir then return end
    local ok, list = pcall(windower.get_dir, dir)
    if not ok or type(list) ~= "table" then return end
    local prefix = file .. ".broken-"
    local found = {}
    for _, name in pairs(list) do
        if type(name) == "string" and name:sub(1, #prefix) == prefix
                and name:sub(#prefix + 1):find("^%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d") then
            found[#found + 1] = name
        end
    end
    if #found <= BROKEN_KEEP then return end
    table.sort(found)                               -- 日時の順 (同じ秒の -02 … は、その後ろ)
    for i = 1, #found - BROKEN_KEEP do os.remove(dir .. "/" .. found[i]) end
end

-- 読めなかったのに別名にできなかった本体のパス。保存のとき、これを .bak に回して良い .bak を消さないための印
local broken_left = {}

-- 保存は、同じフォルダの一時ファイル (.tmp) に書き、write と close の成功と、読み直した中身を確かめてから本名に置き換える
-- (容量不足や保存途中の終了で、前の保存を失わないため)。Windows の os.rename は既存のファイルを上書きできないので、
-- 今のファイルを .prev に移し、一時ファイルを本名にしてから、.prev を .bak (前回の保存) にする。
-- 正常な .bak は、新しい本体を置けるまで消さない (どこで失敗しても、本体か .bak のどちらかから戻せる)。
-- 置き換えの途中で止まったときは、読み込みで .prev・.bak を使う。
-- 戻り値: 成功か, 失敗の理由
local function write_table(path, tbl)
    local text = "return " .. serialize(tbl) .. "\n"
    local tmp, prev, bak = path .. ".tmp", path .. ".prev", path .. ".bak"
    local f, err = io.open(tmp, "w")
    if not f then return false, err end
    local wrote, werr = f:write(text)
    local closed, cerr = f:close()
    if not wrote or not closed then
        os.remove(tmp)
        return false, werr or cerr or "write failed"
    end
    if read_text(tmp) ~= text or not read_table(tmp) then
        os.remove(tmp)
        return false, "verify failed: " .. tmp
    end
    if broken_left[path] then
        -- 読めなかった本体が残っている: .prev・.bak に回すと良い .bak を消すので、もう一度別名にし、だめなら消す
        local name = broken_name(path)
        if not (name and os.rename(path, name)) then os.remove(path) end
        if file_present(path) then
            os.remove(tmp)
            return false, "could not move the unreadable " .. path
        end
        broken_left[path] = nil
    end
    local moved = false
    if file_present(path) then
        os.remove(prev)                             -- 前回の途中で残ったもの (本体があるので使わない)
        local ok, merr = os.rename(path, prev)
        if not ok then
            os.remove(tmp)
            return false, merr
        end
        moved = true
    end
    local ok, rerr = os.rename(tmp, path)
    if not ok then
        if moved then os.rename(prev, path) end     -- 前の保存を本名に戻す (.bak は触っていない)
        os.remove(tmp)
        return false, rerr
    end
    if file_present(prev) then                      -- 新しい本体を置けたので、前の本体を .bak にする
        os.remove(bak)
        os.rename(prev, bak)                        -- 失敗しても .prev が残り、読み込みで使える
    end
    return true
end

-- -----------------------------------------------------------------------------
-- 読み込んだ表の検証 (文法上は読めても、型の違う値で止まらないように)
-- -----------------------------------------------------------------------------
local function finite(v)
    return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end
local function opt_finite(v) return v == nil or finite(v) end
local function is_string(v) return type(v) == "string" end
local function valid_sight(v) return v == nil or v == true or v == false or v == "returned" end

-- nil か、配列の項目が全部 check に通る表か
local function list_of(v, check)
    if v == nil then return true end
    if type(v) ~= "table" then return false end
    for _, x in ipairs(v) do
        if not check(x) then return false end
    end
    return true
end

-- 表のうち check(k, v) に通る項目だけを、SAVED_LIMIT 件まで写す
local function keep_valid(map, check)
    local out, n = {}, 0
    for k, v in pairs(map or {}) do
        if n >= SAVED_LIMIT then break end
        if check(k, v) then out[k] = v; n = n + 1 end
    end
    return out
end

-- 時刻 at が、今 (now) より FUTURE_SLACK_SEC を超えて先か。先の記録は、残り時間が大きく出て、再出現も学習も来ない
local function future(at, now)
    return at > now + FUTURE_SLACK_SEC
end

-- now: 比べる今の時刻 (os.time)。省くと今
local function valid_record(rk, r, now)
    return type(rk) == "string" and type(r) == "table" and is_string(r.key) and finite(r.zone) and finite(r.at)
        and not future(r.at, now or os.time())
        and opt_finite(r.x) and opt_finite(r.y) and opt_finite(r.z) and valid_sight(r.sight)
end

local function valid_slot(id, s, now)
    return finite(id) and type(s) == "table" and is_string(s.key) and finite(s.zone) and finite(s.at)
        and not future(s.at, now or os.time())
        and opt_finite(s.x) and opt_finite(s.y) and valid_sight(s.sight) and (s.name == nil or is_string(s.name))
end

-- 実測の列のうち、check に通るものを、新しい方から keep 個まで残す
local function clean_samples(list, check, keep)
    local out = {}
    for _, v in ipairs(list) do
        if check(v) then out[#out + 1] = v end
    end
    while #out > keep do table.remove(out, 1) end
    return out
end

-- 実測の秒数は 0 以上 (負の値は、時計が戻ったときの誤り)
local function valid_secs(v)
    return finite(v) and v >= 0
end

local function valid_ph_sample(smp, now)
    return type(smp) == "table" and finite(smp.id) and valid_secs(smp.secs) and opt_finite(smp.at)
        and (smp.at == nil or not future(smp.at, now or os.time()))
end

-- state.lua の中身を確かめる。トップレベルの型が違えば nil (使わない)。不正な項目は捨てる。欠けた表は空で補う
local function clean_state(s)
    if type(s) ~= "table" then return nil end
    for _, field in ipairs({"records", "ph_slots", "ph_measured", "measured"}) do
        if s[field] ~= nil and type(s[field]) ~= "table" then return nil end
    end
    local now = os.time()                      -- これより先の時刻の記録・PH の記録・実測は捨てる
    -- 記録: 件数が上限を超えたら、新しいものを残す
    local src, keys = s.records or {}, {}
    for rk, r in pairs(src) do
        if valid_record(rk, r, now) then keys[#keys + 1] = rk end
    end
    if #keys > SAVED_LIMIT then table.sort(keys, function(a, b) return src[a].at > src[b].at end) end
    local records = {}
    for i = 1, math.min(#keys, SAVED_LIMIT) do records[keys[i]] = src[keys[i]] end
    -- PH の記録: エリアごとの表の中の、ID ごとの項目を確かめる (全体で SAVED_LIMIT 件まで)
    local ph_slots, n = {}, 0
    for rk, slots in pairs(s.ph_slots or {}) do
        if type(rk) == "string" and type(slots) == "table" then
            local kept
            for id, slot in pairs(slots) do
                if n >= SAVED_LIMIT then break end
                if valid_slot(id, slot, now) then
                    kept = kept or {}
                    kept[id] = slot
                    n = n + 1
                end
            end
            if kept then ph_slots[rk] = kept end
        end
    end
    -- 学習データ (実測)
    local ph_measured = keep_valid(s.ph_measured, function(rk, list) return type(rk) == "string" and type(list) == "table" end)
    for rk, list in pairs(ph_measured) do
        local kept = clean_samples(list, valid_ph_sample, PH_MEASURE_KEEP)
        ph_measured[rk] = #kept > 0 and kept or nil
    end
    local measured = keep_valid(s.measured, function(key, list) return type(key) == "string" and type(list) == "table" end)
    for key, list in pairs(measured) do
        local kept = clean_samples(list, valid_secs, MEASURE_KEEP)
        measured[key] = #kept > 0 and kept or nil
    end
    return {records = records, ph_slots = ph_slots, ph_measured = ph_measured, measured = measured}
end

-- 自分で足した NM (rebuild_index・timing・ph_wait が使う項目の型)
local function valid_entry(e)
    return type(e) == "table" and is_string(e.key) and is_string(e.name)
        and list_of(e.zone_ids, finite) and list_of(e.zones, is_string) and list_of(e.alias, is_string) and list_of(e.ph, is_string)
        and opt_finite(e.min) and opt_finite(e.max) and opt_finite(e.ph_repop)
        and (e.job == nil or is_string(e.job)) and (e.hint == nil or is_string(e.hint))
end

local USER_TABLES = {"entries", "alias", "times", "ignored", "ph_ids", "ph_times", "ph_excluded"}

-- user.lua の中身を確かめる。トップレベルの型が違えば nil (使わない)。不正な項目は捨てる。欠けた表は空で補う
local function clean_user(u)
    if type(u) ~= "table" then return nil end
    for _, field in ipairs(USER_TABLES) do
        if u[field] ~= nil and type(u[field]) ~= "table" then return nil end
    end
    local entries = {}
    for _, e in ipairs(u.entries or {}) do
        if #entries >= SAVED_LIMIT then break end
        if valid_entry(e) then entries[#entries + 1] = e end
    end
    local ph_ids = keep_valid(u.ph_ids, function(key, ids) return is_string(key) and type(ids) == "table" end)
    for key, ids in pairs(ph_ids) do
        ph_ids[key] = keep_valid(ids, function(id) return finite(id) end)
    end
    return {
        entries = entries,
        alias = keep_valid(u.alias, function(key, list) return is_string(key) and type(list) == "table" and list_of(list, is_string) end),
        times = keep_valid(u.times, function(key, t) return is_string(key) and type(t) == "table" and finite(t.min) and opt_finite(t.max) end),
        ignored = keep_valid(u.ignored, function(key) return is_string(key) end),
        ph_ids = ph_ids,
        ph_times = keep_valid(u.ph_times, function(key, minutes) return is_string(key) and finite(minutes) end),
        ph_excluded = keep_valid(u.ph_excluded, function(id) return finite(id) end),
    }
end

local last_error_at = {}   -- 知らせの文 (where) → 最後に知らせた時刻。保存先ごと・エラーの種類ごとに間引く
-- immediate: 間引かずにすぐ知らせる (コマンドを打った直後の失敗は、その場で知らせる)
local function report_error(where, err, immediate)
    local now = os.clock()
    if not immediate and last_error_at[where] and now - last_error_at[where] < 10 then return end   -- 同じエラーで画面を埋めない
    last_error_at[where] = now
    chat(string.format("[NMTimer] %s: %s", where, tostring(err)), 123)
end

-- -----------------------------------------------------------------------------
-- データ
-- -----------------------------------------------------------------------------
local builtin = {}          -- nm_data.lua の中身
local user = {entries = {}, alias = {}, times = {}, ignored = {}, ph_ids = {}, ph_times = {}, ph_excluded = {}}   -- data/user.lua
local state = {records = {}, ph_slots = {}, ph_measured = {}, measured = {}}   -- data/state.lua

local entries = {}          -- 全部の NM (同梱 + ユーザー)
local by_key = {}
local name_index = {}       -- 小文字の名前・別名 → NM の一覧
local ph_index = {}         -- 小文字の PH 名 → NM の一覧
local zone_sets = {}       -- NM の key → 出るエリアの ID の集合 (保存する表には混ぜない)
local nm_zones = {}        -- 登録された NM が1体でもいるエリアの ID の集合
local zone_by_en = nil
local current_zone = 0
local state_dirty = false  -- 画面の更新で記録が消えたとき、保存し直すための印 (保存に成功したら消す)
local logged_in = true      -- ログイン中だけ HUD・知らせ・パケットを扱う (起動時は get_info で決め、login / logout で切り替える)
local pending_sight = false -- 再出現の実測を待っている記録があるか (パケットごとの確認を軽くするため)
local ph_pending = {}       -- 再湧きの実測を待っている PH の ID → 記録の key のつづき (rk) の集合
local ph_told = {}          -- PH の記録を知らせた ID (同じ ID で何度も知らせない)

local function ensure_dir()
    if windower.create_dir then windower.create_dir(DATA_DIR) end
end

local function zone_id_of(name)
    if not zone_by_en then
        zone_by_en = {}
        for id, row in pairs(res.zones) do
            if type(row) == "table" and row.en then zone_by_en[row.en] = id end
        end
    end
    return zone_by_en[name]
end

local function zone_label(id)
    local row = res.zones[id]
    return row and (row.ja or row.en) or ("エリア" .. tostring(id))
end

local function rebuild_index()
    entries, by_key, name_index, ph_index, zone_sets, nm_zones = {}, {}, {}, {}, {}, {}
    local function add_entry(e)
        if by_key[e.key] then return end
        local set = {}
        for _, z in ipairs(e.zone_ids or {}) do set[z] = true end
        for _, zname in ipairs(e.zones or {}) do
            local id = zone_id_of(zname)
            if id then set[id] = true end
        end
        zone_sets[e.key] = set
        for z in pairs(set) do nm_zones[z] = true end
        entries[#entries + 1] = e
        by_key[e.key] = e
        local function index(map, name)
            if not name or name == "" then return end
            local l = name:lower()
            map[l] = map[l] or {}
            for _, existing in ipairs(map[l]) do
                if existing == e then return end      -- 名前と別名が同じなら 1 回だけ
            end
            table.insert(map[l], e)
        end
        index(name_index, e.name)
        for _, a in ipairs(e.alias or {}) do index(name_index, a) end
        for _, a in ipairs(user.alias[e.key] or {}) do index(name_index, a) end
        for _, p in ipairs(e.ph or {}) do index(ph_index, p) end
    end
    for _, e in ipairs(builtin) do add_entry(e) end
    for _, e in ipairs(user.entries) do add_entry(e) end
end

-- immediate: 失敗を間引かずに知らせる (コマンドから保存するとき)。戻り値: 保存できたか
local function save_state(immediate)
    ensure_dir()
    local ok, err = write_table(STATE_FILE, state)
    if ok then
        state_dirty = false                    -- 今の記録 (消した記録を含む) がディスクに入った
    else
        report_error("state.lua を保存できませんでした (前の保存は残しています)", err, immediate)
    end
    return ok
end

-- user.lua はコマンドからだけ保存する: 失敗はいつも、その場で知らせる。戻り値: 保存できたか
local function save_user()
    ensure_dir()
    local ok, err = write_table(USER_FILE, user)
    if not ok then report_error("user.lua を保存できませんでした (前の保存は残しています)", err, true) end
    return ok
end

-- コマンドの結果の文に足す: 保存できなかったときは、次の起動で元に戻ることを書く
local function unsaved_note(saved)
    return saved and "" or "(保存できなかったため、次の起動では元に戻ります)"
end

-- 読めて、検証 (clean) に通った表だけを返す
local function read_valid(path, clean)
    local tbl = read_table(path)
    return tbl and clean(tbl)
end

-- 前回の保存を読む。置き換えの途中で止まったときの .prev (直前の本体) を先に、なければ .bak
local function read_backup(path, clean)
    return read_valid(path .. ".prev", clean) or read_valid(path .. ".bak", clean)
end

-- 保存したファイルを読む。読めないとき (文法の誤り・型の違い) は、壊れたファイルを別名 (.broken-日時) で残してから、
-- .bak (前回の保存) を読む。.bak も読めなければ空で始める (戻り値 nil)。
-- 別名は同じ秒でも重ならないように連番を付け、新しい BROKEN_KEEP 個だけ残す。別名にできなければ、次の保存で .bak に回さない
local function load_saved(path, label, clean)
    broken_left[path] = nil
    if not file_present(path) then
        return read_backup(path, clean)        -- 置き換えの途中で止まったときは、本名が無く .prev・.bak だけが残る
    end
    local tbl = read_valid(path, clean)
    if tbl then return tbl end
    local keep = broken_name(path)
    local moved = keep ~= nil and os.rename(path, keep) and true or false
    if moved then prune_broken(path) else broken_left[path] = true end
    local backup = read_backup(path, clean)
    chat(string.format("[NMTimer] %s を読めませんでした。%s%s", label,
        moved and ("壊れたファイルを " .. keep:match("[^/\\]+$") .. " として残しました。")
            or "壊れたファイルを別名にできませんでした (次の保存で、もう一度試します。前回の保存 (.bak) は残します)。",
        backup and "前回の保存 (.bak) から読み込みます。" or "空の状態で始めます。"), 123)
    return backup
end

local function load_all()
    builtin = {}
    -- nm_data.lua (メイジャン・異変) を先に、nm_data_bgwiki.lua (BG-Wiki のエリアごと) を後に。同じ key は先のものが残る
    for _, file in ipairs({"nm_data.lua", "nm_data_bgwiki.lua"}) do
        local chunk = loadfile(windower.addon_path .. file)
        if chunk then
            local ok, tbl = pcall(chunk)
            if ok and type(tbl) == "table" then
                for _, e in ipairs(tbl) do builtin[#builtin + 1] = e end
            end
        end
    end
    user = load_saved(USER_FILE, "user.lua", clean_user) or clean_user({})
    state = load_saved(STATE_FILE, "state.lua", clean_state) or clean_state({})
    rebuild_index()
end

-- 実際に使う時間 (分)。ユーザーが決めた値が先。戻り値: 最短, 最長, 目安か
-- 同梱データに時間が無い NM (BG-Wiki に数字が無いもの) は、自分で見た出現の実測から決める。
-- 抽選型: 実測は「倒してから PH を倒して出るまで」なので、いちばん短い値を使う (抽選が始まるまでの時間はそれ以下)。時間型: 中央値
local median   -- 下で定義する
local function learned_minutes(e)
    local list = state.measured[e.key]
    if not list or #list == 0 then return nil end
    local usable = {}
    for _, s in ipairs(list) do
        if s >= LEARN_MIN_SEC then usable[#usable + 1] = s end
    end
    if #usable == 0 then return nil end
    local secs
    if e.kind == "lottery" then
        for _, s in ipairs(usable) do
            if not secs or s < secs then secs = s end
        end
    else
        secs = median(usable)
    end
    return math.max(1, math.floor(secs / 60))
end

-- 戻り値: 最短, 最長, 目安か, 学習した値か
local function timing(e)
    local u = user.times[e.key]
    if u and u.min then return u.min, u.max, false, false end
    if e.min then return e.min, e.max, e.approx and true or false, false end
    local learned = learned_minutes(e)
    if learned then return learned, nil, true, true end
    return nil, nil, false, false
end

local function tracked(e)
    return not user.ignored[e.key]
end

local function rec_key(e, zone)
    return e.key .. "|" .. tostring(zone)
end

local function recount_pending()
    pending_sight = false
    for _, rec in pairs(state.records) do
        if rec.sight and rec.zone == current_zone then pending_sight = true break end
    end
    ph_pending = {}
    for rk, slots in pairs(state.ph_slots) do
        for id, slot in pairs(slots) do
            if slot.sight and slot.zone == current_zone then
                -- 同じ PH が 2 体以上の NM に登録されていると、1 つの ID に記録が複数できる。全部を覚える
                local set = ph_pending[id]
                if not set then set = {}; ph_pending[id] = set end
                set[rk] = true
            end
        end
    end
end

function median(list)
    local copy = {}
    for _, v in ipairs(list) do copy[#copy + 1] = v end
    table.sort(copy)
    local n = #copy
    if n == 0 then return nil end
    if n % 2 == 1 then return copy[(n + 1) / 2] end
    return (copy[n / 2] + copy[n / 2 + 1]) / 2
end

-- PH の再湧き時間 (分)。ユーザーが決めた値 > その ID の実測の中央値 > そのエリアの実測の中央値 > 同梱データ。
-- 戻り値: 分, 由来 ("user" / "id" / "area" / "data"), 使った実測の回数
local function ph_wait(e, zone, id)
    local u = user.ph_times[e.key]
    if u then return u, "user", 0 end
    local samples = zone and state.ph_measured[rec_key(e, zone)]
    if samples and #samples > 0 then
        local mine, all = {}, {}
        for _, smp in ipairs(samples) do
            if type(smp) == "table" and smp.secs then
                all[#all + 1] = smp.secs
                if id and smp.id == id then mine[#mine + 1] = smp.secs end
            end
        end
        if #mine > 0 then return median(mine) / 60, "id", #mine end
        if #all > 0 then return median(all) / 60, "area", #all end
    end
    if e.ph_repop then return e.ph_repop, "data", 0 end
    return nil
end

-- -----------------------------------------------------------------------------
-- 記録
-- -----------------------------------------------------------------------------
local function describe_wait(e)
    local min, max, approx, learned = timing(e)
    if not min then return nil end
    local text
    if max and max > min then text = string.format("%d～%d分", min, max) else text = string.format("%d分", min) end
    if learned then text = text .. "(学習)" elseif approx then text = text .. "(目安)" end
    return text
end

-- immediate: コマンド (//nmt tod) からの記録。保存の失敗を間引かずに知らせる
local function record_kill(e, zone, x, y, z, when, immediate)
    if not tracked(e) then return end
    local rk = rec_key(e, zone)
    state.records[rk] = {key = e.key, zone = zone, at = when, x = x, y = y, z = z, sight = (zone == current_zone)}
    save_state(immediate)
    recount_pending()
    local wait = describe_wait(e)
    local label = e.kind == "lottery" and "抽選の開始" or "再出現"
    if wait then
        chat(string.format("[NMTimer] %s を記録しました(%s)。%sまで %s", e.name, zone_label(zone), label, wait))
    else
        chat(string.format("[NMTimer] %s を記録しました(%s)。時間は不明です。出るのを見ると学習します (//nmt time %s <分> で決めることもできます)", e.name, zone_label(zone), e.key), 167)
    end
end

-- name: 倒れたときに確かめた敵の名前 (再湧きのとき、同じ ID に別の敵が出たのを見分けるため)
local function record_ph(e, zone, id, x, y, when, name)
    if not tracked(e) then return end
    local rk = rec_key(e, zone)
    local slots = state.ph_slots[rk] or {}
    slots[id] = {key = e.key, zone = zone, at = when, x = x, y = y, sight = (zone == current_zone), name = name}
    state.ph_slots[rk] = slots
    save_state()
    recount_pending()
    if settings.chat and not ph_told[id] then
        ph_told[id] = true
        chat(string.format("[NMTimer] PH(%s ID %s)を記録しました(%s)。この敵が PH でなければ //nmt ph del %d", e.ph and e.ph[1] or "PH", id_tag(id), e.name, id), 160)
    end
end

-- PH が再び現れた (同じ ID)。倒してから見続けていたときだけ、かかった時間を実測として覚える
-- 同じ ID の記録が複数の NM にあるとき (同じ PH を 2 体の NM に登録したとき) は、同じ更新で全部を処理する
-- name: 今の個体の名前 (分からなければ nil)。倒れたときの名前と違えば、同じ ID に別の敵が湧いたので、学習せずに記録だけ消す
local function on_ph_respawn(id, when, name)
    local set = ph_pending[id]
    if not set then return end
    local changed, stale = false, false
    for rk in pairs(set) do
        local slots = state.ph_slots[rk]
        local slot = slots and slots[id]
        if not slot then
            stale = true                                     -- 記録が消えていた: 数え直す
        elseif name and slot.name and name:lower() ~= slot.name:lower() then
            slots[id] = nil                                  -- 別の敵: PH の再湧きとは学習しない
            changed = true
            if next(slots) == nil then state.ph_slots[rk] = nil end
        elseif when - slot.at >= PH_SIGHT_MIN_SEC then       -- それより早い更新は、倒れる途中のものかもしれない
            local secs = when - slot.at
            slots[id] = nil
            changed = true
            local e = by_key[slot.key]
            if e and slot.sight == true and secs <= PH_SLOT_KEEP_SEC then
                local list = state.ph_measured[rk] or {}
                list[#list + 1] = {id = id, secs = secs, at = when}
                while #list > PH_MEASURE_KEEP do table.remove(list, 1) end
                state.ph_measured[rk] = list
                chat(string.format("[NMTimer] %s の PH(%s ID %s) が約%d分で再び湧きました(実測 %s)。", e.name, e.ph and e.ph[1] or "PH", id_tag(id),
                    math.floor(secs / 60 + 0.5), fmt_time(secs)))
            end
            if next(slots) == nil then state.ph_slots[rk] = nil end
        end
    end
    if changed then save_state() end
    if changed or stale then recount_pending() end
end

local function note_sighting(e, rec, rk, when)
    local secs = when - rec.at
    local list = state.measured[e.key] or {}
    list[#list + 1] = secs
    while #list > MEASURE_KEEP do table.remove(list, 1) end
    state.measured[e.key] = list
    state.records[rk] = nil
    save_state()
    recount_pending()
    chat(string.format("[NMTimer] %s が約%d分で現れました(実測 %s)。", e.name, math.floor(secs / 60 + 0.5), fmt_time(secs)))
end

-- -----------------------------------------------------------------------------
-- パケットの処理 (0x00E: 敵の更新)
-- -----------------------------------------------------------------------------
local seen_dead = {}      -- 倒れたと知った敵の ID → 時刻 (同じ敵を何度も数えない)
local alive_seen = {}  -- 生きている状態を見た敵の ID。倒れた状態で初めて届いた敵 (まだ出ていない NM が近づくと届く) は倒したことにしない
local alive_n = 0

-- 生きている状態を最後に見た時刻 (os.clock) から ALIVE_KEEP_SEC 以内か
local function alive_fresh(id)
    local t = alive_seen[id]
    return t ~= nil and os.clock() - t <= ALIVE_KEEP_SEC
end

-- 古い (ALIVE_KEEP_SEC を過ぎた) ものだけ捨てて、件数を数え直す
local function alive_prune(now_c)
    local n = 0
    for k, t in pairs(alive_seen) do
        if now_c - t > ALIVE_KEEP_SEC then alive_seen[k] = nil else n = n + 1 end
    end
    alive_n = n
end
local nm_ids = {}         -- "エリア:ID" → NM の key。出現のとき名前から覚える。ID は使い回されることがあるので、エリアを移ったら捨てる (保存しない)
local nm_id_count = 0

local function nm_id_key(zone, id)
    return tostring(zone) .. ":" .. tostring(id)
end

-- 受信側の観測 (倒れた・生きている・覚えた ID) を捨てる。ゾーン変更・ログイン・ログアウトのとき
local function reset_observed()
    seen_dead = {}
    alive_seen = {}
    alive_n = 0
    nm_ids = {}
    nm_id_count = 0
end

local function u32(data, offset)
    local a, b, c, d = data:byte(offset, offset + 3)
    if not d then return nil end
    return a + b * 256 + c * 65536 + d * 16777216
end

-- NM が現れたとき (名前つきの更新)、名前が登録済みの NM と一致したら、その敵の ID を覚える。
-- 同梱データには ID を持たせない (ID は出現のたびに、実際に見た敵から取る)。同じエリアで同じ名前が 2 つの項目にあるときは覚えない。
-- 同じ ID に別の名前が現れたら、覚えた ID は捨てる (list = nil は「登録外の名前」)
local NM_ID_LIMIT = 3000
-- 読める名前か (英字・数字・空白・' - . だけ)。NM の更新は名前の位置が違い、読めない文字が入ることがある
local function readable_name(name)
    return name ~= nil and name:find("^[%w][%w '%-%.]*$") ~= nil
end

local function learn_nm_id(list, id, name)
    if not list and next(nm_ids) == nil then return end     -- 登録外の名前で、覚えた ID も無い: 何もしない (文字列を作らない)
    local k = nm_id_key(current_zone, id)
    local match
    for _, e in ipairs(list or {}) do
        if zone_sets[e.key][current_zone] then
            if match then match = nil break end
            match = e
        end
    end
    if not match then
        local cur = by_key[nm_ids[k]]
        if cur then -- 更新の名前が読めないだけなら捨てない: 敵の一覧に名前があって同じ、または一覧に情報が無く名前も読めない
            local mob = windower.ffxi.get_mob_by_id(id)
            if mob and mob.name then
                if mob.name:lower() == cur.name:lower() then return end
            elseif not readable_name(name) then
                return
            end
        end
        if nm_ids[k] then -- 別の敵が同じ ID を使い回したら捨てる
            nm_ids[k] = nil
            nm_id_count = nm_id_count - 1
        end
        return
    end
    if nm_ids[k] == match.key then return end
    nm_ids[k] = match.key
    nm_id_count = nm_id_count + 1
    if settings.debug then chat(string.format("[NMTimer debug] ID を覚えました: %s (ID %s)", match.name, id_tag(id)), 160) end
    if nm_id_count > NM_ID_LIMIT then            -- 増えすぎたら捨てて覚え直す
        nm_ids = {[k] = match.key}
        nm_id_count = 1
    end
end

local function on_death(id)
    if alive_seen[id] then alive_seen[id] = nil; alive_n = alive_n - 1 end
    local now_c = os.clock()
    if seen_dead[id] and now_c - seen_dead[id] < 120 then return end   -- 倒れた敵の更新は何度も届くので、同じ敵は 1 回だけ
    seen_dead[id] = now_c
    local mob = windower.ffxi.get_mob_by_id(id)
    local known = by_key[nm_ids[nm_id_key(current_zone, id)]]   -- このエリアで現れたとき名前から覚えた ID
    if mob and mob.is_npc == false then return end
    if not mob or not mob.name then
        -- 名前が読めなくても、覚えた ID の NM なら記録する
        if known and zone_sets[known.key][current_zone] then record_kill(known, current_zone, nil, nil, nil, os.time()) end
        return
    end
    if settings.debug then chat(string.format("[NMTimer debug] 倒れた: %s (ID %s)", mob.name, id_tag(id)), 160) end
    local l = mob.name:lower()
    local when = os.time()
    learn_nm_id(name_index[l], id, mob.name)               -- 倒したとき名前から ID を覚える (次に現れたとき、名前を読めなくても出現と分かる)
    if settings.debug then
        -- 記録されない理由を出す (名前が登録されていない / エリアが違う / 追跡をやめている)
        local found = name_index[l]
        if not found and ph_index[l] then
            chat(string.format("[NMTimer debug]   → 「%s」は PH として登録されています (近くで倒れた PH の再湧きを数えます)", mob.name), 160)
        elseif not found then
            chat(string.format("[NMTimer debug]   → 「%s」は登録されていない名前です (今のエリア ID %d)", mob.name, current_zone), 160)
        else
            for _, e in ipairs(found) do
                local why = "記録します"
                if not zone_sets[e.key][current_zone] then why = "エリアが違います"
                elseif not tracked(e) then why = "追跡をやめています (//nmt on)" end
                chat(string.format("[NMTimer debug]   → 登録あり: %s (%s) / 今のエリア ID %d → %s", e.name, e.key, current_zone, why), 160)
            end
        end
    end
    for _, e in ipairs(name_index[l] or {}) do
        if zone_sets[e.key][current_zone] then
            record_kill(e, current_zone, mob.x, mob.y, mob.z, when)
        end
    end
    for _, e in ipairs(ph_index[l] or {}) do
        if zone_sets[e.key][current_zone] then
            -- //nmt ph で指定した PH があれば、その敵だけ。なければ、自分の近くで倒れた同じ名前の敵
            local marked = user.ph_ids[e.key]
            local counted
            if user.ph_excluded[id] then counted = false
            elseif marked and next(marked) then counted = marked[id]
            elseif e.quiet_ph then counted = false      -- BG-Wiki のデータの PH は一般の敵と同名が多い。//nmt ph で指定するまで数えない
            else counted = type(mob.distance) == "number" and mob.distance <= PH_NEAR_SQ end   -- 距離が分からなければ数えない
            if counted then record_ph(e, current_zone, id, mob.x, mob.y, when, mob.name) end
        end
    end
end

-- 離れていた (エリア移動・ログアウト・アンロード) あとに、出ているのを見た。いつ出たかは分からないので実測にも学習にもせず、記録だけ消して知らせる
local function note_returned(e, rec, rk, when)
    state.records[rk] = nil
    save_state()
    recount_pending()
    chat(string.format("[NMTimer] %s は、戻ったら出ていました(倒してから約%d分以内)。", e.name, math.floor((when - rec.at) / 60 + 0.5)))
end

-- hold: どの記録の再出現か決められない (同名の登録が 2 件以上)。実測を学習せず、記録もそのまま残す
local function sight_entry(e, when, hold)
    local rk = rec_key(e, current_zone)
    local rec = state.records[rk]
    if rec and future(rec.at, when) then
        -- 今より先の時刻の記録 (PC の時計を戻した): 再出現も学習も来ないので、記録を消す
        state.records[rk] = nil
        save_state()
        recount_pending()
        return
    end
    if rec and rec.sight and when - rec.at >= SIGHT_MIN_SEC then
        if rec.sight ~= true then note_returned(e, rec, rk, when)
        elseif not hold then note_sighting(e, rec, rk, when) end
    end
end

-- 今のエリアに、この名前の登録が 2 件以上あるか
local function ambiguous_here(list)
    local n = 0
    for _, e in ipairs(list) do
        if zone_sets[e.key][current_zone] then
            n = n + 1
            if n > 1 then return true end
        end
    end
    return false
end

local function on_sighted(name)
    local list = name_index[name:lower()]
    if not list then return end
    local when = os.time()
    local hold = ambiguous_here(list)
    for _, e in ipairs(list) do sight_entry(e, when, hold) end
end

-- 生きている状態の更新が初めて届いた (湧いた)。PH の再湧き・NM の再出現の判定はここで行う。
-- 名前つきの更新 (位置と名前だけ) は、まだ出ていない敵に近づいただけでも届くので、再出現とはみなさない (ゲーム内で確認 2026-10-31)
-- その名前 (別名を含む) が、この NM のものか
local function named_as(e, name)
    for _, x in ipairs(name_index[name:lower()] or {}) do
        if x == e then return true end
    end
    return false
end

local function on_alive(id, name)
    if ph_pending[id] then
        -- 今の個体の名前 (更新の名前が読めなければ敵の一覧から)。倒れたときの PH の名前と照合する
        local current = name and readable_name(name) and name or nil
        if not current then
            local mob = windower.ffxi.get_mob_by_id(id)
            if mob and mob.name and mob.name ~= "" then current = mob.name end
        end
        on_ph_respawn(id, os.time(), current)
    end
    if pending_sight then
        local known = by_key[nm_ids[nm_id_key(current_zone, id)]]
        if known then
            -- 倒したときに名前から覚えた ID。今の個体の名前が読めれば先に照合する (同じ ID を別の敵が使い回すことがある)。
            -- 名前が読めないときは、ID だけで出現とする (NM の更新は名前の位置が違うことがある)
            local current = name and readable_name(name) and name or nil
            if not current then
                local mob = windower.ffxi.get_mob_by_id(id)
                if mob and mob.name and mob.name ~= "" then current = mob.name end
            end
            if not current or named_as(known, current) then
                sight_entry(known, os.time())
                return
            end
            name = current                    -- 名前が違う: 覚えた ID では出現にせず、記録も消さない (今の名前で探すだけ)
        end
        if not name then
            local mob = windower.ffxi.get_mob_by_id(id)
            name = mob and mob.name
        end
        if name and name ~= "" then on_sighted(name) end
    end
end

-- 診断: //nmt watch で指定した ID に届く更新を、debug のとき全部表示する (保存しない)
local watch_ids = {}

local function on_npc_update(data)
    if #data < 0x20 then return end
    local mask = data:byte(0x0B)
    if not mask then return end
    if settings.debug and next(watch_ids) then
        local wid = u32(data, 0x05)
        if wid and watch_ids[wid] then
            chat(string.format("[NMTimer debug] 監視中の更新: ID %s / マスク %d / 状態 %s / 長さ %d", id_tag(wid), mask, mask % 8 >= 4 and tostring(data:byte(0x20)) or "-", #data), 160)
        end
    end
    local alive_id = nil                        -- HP が正の生存の更新だった敵の ID
    if mask % 8 >= 4 then                       -- ビット 2: HP (0x1E)・状態 (0x1F) が入っている
        local status = data:byte(0x20)
        if status and DEAD_STATUS[status] then
            local id = u32(data, 0x05)
            if id and alive_fresh(id) then on_death(id) end      -- 生きている状態を見た敵だけ数える (まだ出ていない NM が、近づいたときに倒れた状態で届くのを数えない)
        elseif status then
            -- 生きている側は HP (0x1E = HP の割合 0〜100。libs/packets/fields.lua) が正のときだけ。HP 0 の更新は生存とみなさない
            local hpp = data:byte(0x1F)
            local id = hpp and hpp > 0 and u32(data, 0x05)
            if id then
                alive_id = id
                local now_c = os.clock()
                local fresh = alive_seen[id] ~= nil and now_c - alive_seen[id] <= ALIVE_KEEP_SEC
                if alive_seen[id] == nil then alive_n = alive_n + 1 end
                alive_seen[id] = now_c
                if alive_n > ALIVE_LIMIT then alive_prune(now_c) end
                if not fresh then
                    local nm = mask % 16 >= 8 and #data >= 0x35 and data:sub(0x35):match("^[^%z]*") or nil
                    on_alive(id, nm)
                end
            end
        end
    end
    -- ビット 3 (名前) とビット 2 (HP が正の生存) がそろった更新 = 湧き直した。同じ敵がまた倒れたら、もう一度数える。
    -- 名前だけの更新 (HP の情報なし) は、まだ出ていない敵に近づいただけでも届くので、倒れた印を消さない
    if alive_id and mask % 16 >= 8 then
        seen_dead[alive_id] = nil
    end
    -- ビット 3: 名前が入っている (現れたとき)。登録 NM のいないエリアでは、名前を読まない (パケットごとの処理を増やさない)
    if mask % 16 >= 8 and #data >= 0x35 and nm_zones[current_zone] then
        local name = data:sub(0x35):match("^[^%z]*")
        if name and name ~= "" then
            if nm_zones[current_zone] then
                local id = u32(data, 0x05)
                if id then learn_nm_id(name_index[name:lower()], id, name) end
            end
        end
    end
end

-- 0x02D : 自分が経験値などを得たときに届く通知 (Target = 倒した敵の ID。RoE の更新では Target がプレイヤー)。
-- 全ての討伐が届くわけではない (他の人だけが倒した敵・経験値の入らない敵は届かない) ので、0x00E の補助として使う。
-- 本当に倒れているときだけ数える。数えた撃破の再通知 (経験値・リミットポイントなど) では、撃破時刻を上書きしない
-- (倒れた印 seen_dead は、湧き直した更新かゾーン変更で消える)
local EXP_MIN_LEN = 0x1A    -- Message (0x18〜0x19。libs/packets/fields.lua の 0x02D) まで届く長さ。短いものは捨てる
local function on_exp_message(data)
    if #data < EXP_MIN_LEN then return end
    local target = u32(data, 0x09)
    if not target or seen_dead[target] then return end
    local mob = windower.ffxi.get_mob_by_id(target)
    if mob and mob.is_npc ~= false and ((mob.hpp or 100) == 0 or DEAD_STATUS[mob.status or -1]) then
        on_death(target)
    end
end

windower.register_event("incoming chunk", function(id, data)
    if not logged_in then return end            -- ログアウト中に届いたものは使わない (保存もチャットもしない)
    local handler = id == 0x00E and on_npc_update or id == 0x02D and on_exp_message
    if not handler then return end
    local ok, err = pcall(handler, data)
    if not ok then report_error("パケット処理エラー", err) end
end)

-- -----------------------------------------------------------------------------
-- 状態の計算と HUD
-- -----------------------------------------------------------------------------
-- 1 件の記録を、表示用の {text, order, ready_at, done_at} にする
local function describe(rec, e, now)
    local min, max, approx, learned = timing(e)
    local elapsed = now - rec.at
    local mark = (learned and color_text("(学習)", 150, 150, 150)) or (approx and color_text("(目安)", 150, 150, 150)) or ""
    local state_text, order, done_at
    if not min then
        state_text = color_text("時間不明", 180, 180, 180) .. string.format(" 討伐 %s  //nmt time %s <分>", clock_text(rec.at), e.key)
        order = math.huge
        done_at = rec.at + UNKNOWN_KEEP_SEC
    else
        local first = min * 60
        local last = (max and max > min) and max * 60 or first
        done_at = rec.at + last + (settings.expire_min or 30) * 60
        order = rec.at + first
        local what = e.kind == "lottery" and "抽選開始" or "再出現"
        if elapsed < first then
            state_text = color_text(string.format("%sまで %s", what, fmt_time(first - elapsed)), 255, 220, 100) .. mark
        elseif elapsed < last then
            state_text = color_text(string.format("出現の可能性 あと%s", fmt_time(last - elapsed)), 255, 150, 60) .. mark
        else
            local ready = e.kind == "lottery" and "抽選できます" or "出ているかも"
            state_text = color_text(string.format("%s (+%s)", ready, fmt_time(elapsed - last)), 120, 255, 120)
        end
    end
    local where = ""
    if settings.coord and rec.x and rec.y then
        where = string.format("  (X:%d Y:%d", math.floor(rec.x + 0.5), math.floor(rec.y + 0.5))
        if rec.zone == current_zone then
            local me = windower.ffxi.get_mob_by_target("me")
            if me and me.x and me.y then
                where = where .. string.format(" 距離%dYm", math.floor(math.sqrt((me.x - rec.x) ^ 2 + (me.y - rec.y) ^ 2) + 0.5))
            end
        end
        where = where .. ")"
    end
    local job = e.job and ("〔" .. e.job .. "〕") or ""
    local text = string.format("%s %s%s %s%s", color_text("[" .. zone_label(rec.zone) .. "]", 150, 200, 255), e.name, job, state_text, where)
    return {text = text, order = order, done_at = done_at}
end

local function build_rows(now)
    local rows = {}
    for rk, rec in pairs(state.records) do
        local e = by_key[rec.key]
        if future(rec.at, now) then
            state.records[rk] = nil               -- 今より先の時刻 (PC の時計を戻した): 残り時間が大きく出るので消す
            state_dirty = true
        elseif e and tracked(e) then
            local row = describe(rec, e, now)
            if row.done_at and now >= row.done_at then
                state.records[rk] = nil           -- 出られるようになって十分たったら消す
                state_dirty = true
            else
                rows[#rows + 1] = row
            end
        end
    end
    for rk, slots in pairs(state.ph_slots) do
        local soonest, soonest_slot, soonest_id, count = nil, nil, nil, 0
        for id, slot in pairs(slots) do
            local e = by_key[slot.key]
            if not e or now - slot.at > PH_SLOT_KEEP_SEC or future(slot.at, now) then
                slots[id] = nil                       -- 古い記録 (実測にも使わない)・今より先の時刻の記録は捨てる
                state_dirty = true
            else
                local wait = ph_wait(e, slot.zone, id)
                local remain = wait and (slot.at + wait * 60 - now)
                if remain and remain > 0 then
                    count = count + 1
                    if not soonest or remain < soonest then soonest, soonest_slot, soonest_id = remain, slot, id end
                end
            end
        end
        if next(slots) == nil then state.ph_slots[rk] = nil; state_dirty = true end
        local e = soonest_slot and by_key[soonest_slot.key]
        if e and tracked(e) then
            local _, source = ph_wait(e, soonest_slot.zone, soonest_id)
            local note = (source == "id" or source == "area") and color_text("(実測)", 150, 150, 150) or ""
            local more = count > 1 and string.format(" ほか%d体", count - 1) or ""
            rows[#rows + 1] = {order = now + soonest, text = string.format("%s %s(%s) %s%s%s",
                color_text("[" .. zone_label(soonest_slot.zone) .. "]", 150, 200, 255), e.ph and e.ph[1] or "PH", e.name,
                color_text("PH再湧きまで " .. fmt_time(soonest), 255, 220, 100), note, more)}
        end
    end
    table.sort(rows, function(a, b) return a.order < b.order end)
    return rows
end

local hud = texts.new("", settings)
local last_hud_text = nil
local next_save_retry = 0   -- 消えた記録の保存に失敗したとき、次に試す時刻 (os.clock)

local function refresh_hud(now)
    local rows = build_rows(now)
    -- 消えた記録を保存し直す。失敗したら印 (state_dirty) を残し、SAVE_RETRY_SEC 秒ごとに試す
    if state_dirty and os.clock() >= next_save_retry and not save_state() then
        next_save_retry = os.clock() + SAVE_RETRY_SEC
    end
    if not settings.show then
        if last_hud_text ~= "" then hud:hide() end
        last_hud_text = ""
        return
    end
    -- 記録がないときも、動いていることが分かるように小さく出す
    local lines = {color_text("NMTimer", 255, 255, 255) .. (#rows == 0 and color_text("  記録なし(NM が倒れると表示します)", 150, 150, 150) or "")}
    for _, row in ipairs(rows) do lines[#lines + 1] = row.text end
    local text = table.concat(lines, "\n")
    if text ~= last_hud_text then
        hud:text(text)
        last_hud_text = text
    end
    hud:show()
end

-- -----------------------------------------------------------------------------
-- 知らせ (出られる少し前と、出られるようになったとき)
-- -----------------------------------------------------------------------------
local function play_sound()
    if settings.sound and windower.file_exists and windower.file_exists(SOUND_FILE) then
        windower.play_sound(SOUND_FILE)
    end
end

local function notify(text)
    if settings.chat then chat(text, 209) end
    play_sound()
end

local function check_alerts(now)
    for _, rec in pairs(state.records) do
        local e = by_key[rec.key]
        if e and tracked(e) then
            local min = timing(e)
            if min then
                local at = rec.at + min * 60
                local lead = (tonumber(settings.lead_min) or 0) * 60
                -- 起動した時にもう過ぎていたものは知らせない (30 秒以内に過ぎたものだけ)
                if lead > 0 and min * 60 > lead and not rec.lead_done and now >= at - lead then
                    rec.lead_done = true
                    if now < at then notify(string.format("[NMTimer] %s(%s) あと約%d分", e.name, zone_label(rec.zone), math.ceil((at - now) / 60))) end
                end
                if not rec.ready_done and now >= at then
                    rec.ready_done = true
                    if now - at < 30 then
                        notify(string.format("[NMTimer] %s(%s) %s", e.name, zone_label(rec.zone),
                            e.kind == "lottery" and "抽選できます" or "出ているかもしれません"))
                    end
                end
            end
        end
    end
end

local next_refresh = 0
local next_login_check = 0
local on_login                                 -- 下で定義する (login イベントと同じ処理)
windower.register_event("prerender", function()
    if not logged_in then
        -- 起動時にログアウト中だと、login イベントが来るまで止まる。毎秒 get_info を見直して、ログインしていたら戻す
        local check_c = os.clock()
        if check_c < next_login_check then return end
        next_login_check = check_c + LOGIN_CHECK_SEC
        local info = windower.ffxi.get_info()
        if not (info and info.logged_in) then return end
        on_login()
    end
    local now_c = os.clock()
    if now_c < next_refresh then return end
    next_refresh = now_c + REFRESH_SEC
    local ok, err = pcall(function()
        local now = os.time()
        check_alerts(now)
        refresh_hud(now)
    end)
    if not ok then
        next_refresh = now_c + 5
        report_error("表示エラー", err)
    end
end)

-- -----------------------------------------------------------------------------
-- ライフサイクル
-- -----------------------------------------------------------------------------
local function update_zone()
    local info = windower.ffxi.get_info()
    current_zone = info and info.zone or 0
end

-- 実測を取る待ち状態 (sight) を「離れていた」印にする。そのあと見えたら、記録だけ消して知らせる (実測・学習には使わない)
local function mark_returned()
    for _, rec in pairs(state.records) do if rec.sight then rec.sight = "returned" end end
    for _, slots in pairs(state.ph_slots) do
        for _, slot in pairs(slots) do if slot.sight then slot.sight = "returned" end end
    end
end

windower.register_event("zone change", function(new_id)
    reset_observed()                           -- 覚えた ID は、そのエリアにいるあいだだけ使う
    -- エリアを離れたら、実測は取らない (戻ってきたときに出ているのは、いつ出たか分からない)。見えたら記録だけ消す
    mark_returned()
    current_zone = tonumber(new_id) or current_zone
    recount_pending()
    save_state()
end)

on_login = function()
    logged_in = true
    update_zone()
    mark_returned()                            -- ログアウトや強制終了のあいだは見ていなかった
    reset_observed()
    recount_pending()
end
windower.register_event("login", function() on_login() end)

-- 設定 (data/settings.xml) を保存する。書き込めないときの libs/config.lua のエラーで、コマンドや終了の処理を止めない。
-- 戻り値: 保存できたか (失敗はチャットで知らせる)
local function save_settings()
    local ok, err = pcall(config.save, settings)
    if not ok then chat("[NMTimer] 設定を保存できませんでした (今回の起動中だけ有効です): " .. tostring(err), 123) end
    return ok
end

local function stop()
    save_state()
    save_settings()
    if hud then hud:hide() end
end

windower.register_event("logout", function()
    logged_in = false                          -- 次の prerender で HUD を出し直さない・知らせを出さない・パケットを使わない
    reset_observed()
    mark_returned()
    stop()
end)

windower.register_event("unload", function()
    mark_returned()
    stop()
    if hud then hud:destroy() end
end)

-- -----------------------------------------------------------------------------
-- コマンド (//nmt または //nmtimer)
-- -----------------------------------------------------------------------------
local function zone_entries()
    local list = {}
    for _, e in ipairs(entries) do
        if zone_sets[e.key][current_zone] then list[#list + 1] = e end
    end
    return list
end

-- 引数の先頭から NM を探す。数字 = 今のエリアの一覧の番号、そうでなければ key か名前。戻り値: NM, 残りの引数
local function resolve(args)
    if #args == 0 then return nil, args end
    local n = tonumber(args[1])
    if n then
        local e = zone_entries()[n]
        if e then return e, {unpack(args, 2)} end
    end
    for count = #args, 1, -1 do
        local candidate = table.concat(args, " ", 1, count):lower()
        for _, e in ipairs(entries) do
            if e.key:lower() == candidate or e.name:lower() == candidate then
                return e, {unpack(args, count + 1)}
            end
        end
    end
    return nil, args
end

local function kind_label(e)
    return e.kind == "lottery" and "抽選" or "時間"
end

local function cmd_list(all)
    local list = all and entries or zone_entries()
    if #list == 0 then
        chat(string.format("[NMTimer] %s には登録された NM がありません(//nmt add で足せます。//nmt list all で全部)", zone_label(current_zone)))
        return
    end
    chat(string.format("[NMTimer] %s の NM:", all and "全エリア" or zone_label(current_zone)))
    for i, e in ipairs(list) do
        local wait = describe_wait(e) or "時間不明"
        local flag = tracked(e) and "" or " [追跡なし]"
        local job = e.job and ("〔" .. e.job .. "〕") or ""
        chat(string.format("  %s%s %s%s %s %s%s", all and "" or (i .. ". "), e.name, job, "(" .. kind_label(e) .. ")", wait,
            e.hint and ("/ " .. e.hint) or "", flag))
        local m = state.measured[e.key]
        if m and #m > 0 then
            local parts = {}
            for _, s in ipairs(m) do parts[#parts + 1] = string.format("%d分", math.floor(s / 60 + 0.5)) end
            chat("      実測: " .. table.concat(parts, ", "))
        end
        if e.ph then
            local ph_minutes, source, n = ph_wait(e, current_zone)
            local label = ph_minutes and string.format("%.1f分", ph_minutes):gsub("%.0分", "分") or "不明"
            if source == "area" then label = label .. string.format("(実測 %d 回の中央値)", n)
            elseif source == "user" then label = label .. "(自分で決めた値)" end
            local marked = user.ph_ids[e.key] and next(user.ph_ids[e.key]) and " / 指定した PH あり" or ""
            chat(string.format("      PH: %s / 再湧き: %s%s", table.concat(e.ph, "・"), label, marked))
        end
    end
end

local function cmd_status()
    local now = os.time()
    local rows = build_rows(now)
    if #rows == 0 then chat("[NMTimer] 記録はありません") return end
    for _, row in ipairs(rows) do
        chat("  " .. (row.text:gsub("\\cs%(%d+,%d+,%d+%)", ""):gsub("\\cr", "")), 207)
    end
end

local function cmd_ph_list()
    local any = false
    local now = os.time()
    for _, e in ipairs(zone_entries()) do
        if e.ph then
            any = true
            local rk = rec_key(e, current_zone)
            chat(string.format("[NMTimer] %s / PH: %s", e.name, table.concat(e.ph, "・")))
            local ids = {}
            for id in pairs(user.ph_ids[e.key] or {}) do ids[#ids + 1] = id end
            table.sort(ids)
            if #ids > 0 then
                chat("      指定した PH: ID " .. table.concat(id_tags(ids), ", ID ") .. string.format(" (%d 体)", #ids))
            else
                chat("      指定した PH: なし (近くで倒れた同じ名前の敵をすべて数えます。//nmt ph で指定)")
            end
            local slot_ids = {}
            for id in pairs(state.ph_slots[rk] or {}) do slot_ids[#slot_ids + 1] = id end
            table.sort(slot_ids)
            for _, id in ipairs(slot_ids) do
                chat(string.format("      記録中: ID %s (%s前に倒した)", id_tag(id), fmt_time(now - state.ph_slots[rk][id].at)))
            end
            local per_id = {}
            for _, smp in ipairs(state.ph_measured[rk] or {}) do
                if type(smp) == "table" and smp.id then
                    per_id[#per_id + 1] = string.format("ID %s = %s", id_tag(smp.id), fmt_time(smp.secs))
                end
            end
            if #per_id > 0 then chat("      実測: " .. table.concat(per_id, ", ")) end
        end
    end
    local excluded = {}
    for id in pairs(user.ph_excluded) do excluded[#excluded + 1] = id end
    table.sort(excluded)
    if #excluded > 0 then chat("[NMTimer] PH から外した ID: " .. table.concat(id_tags(excluded), ", ")) end
    if not any then chat(string.format("[NMTimer] %s には PH のある NM がありません。", zone_label(current_zone))) end
end

local function clear_for(e)
    for rk, rec in pairs(state.records) do if rec.key == e.key then state.records[rk] = nil end end
    for rk, slots in pairs(state.ph_slots) do
        for _, slot in pairs(slots) do
            if slot.key == e.key then state.ph_slots[rk] = nil break end
        end
    end
    recount_pending()
    return save_state(true)                    -- コマンドから呼ぶ: 失敗はその場で知らせる
end

local function need_entry(args, usage)
    local e, rest = resolve(args)
    if not e then
        chat("[NMTimer] NM が分かりません。" .. usage .. " (名前・key・//nmt list の番号)", 123)
        return nil
    end
    return e, rest
end

local function make_key(name)
    local base = name:lower():gsub("[^%w]+", "_"):gsub("^_+", ""):gsub("_+$", "")
    if base == "" or base:find("[\128-\255]") then base = "nm" end
    local key, n = "u_" .. base, 1
    while by_key[key] do n = n + 1; key = "u_" .. base .. n end
    return key
end

local function target_name()
    local t = windower.ffxi.get_mob_by_target("t")
    return t and t.name or nil
end

local function utf8_name(raw)
    if raw:find("[\128-\255]") and windower.from_shift_jis then return windower.from_shift_jis(raw) end
    return raw
end

-- //nmt scan : 敵の一覧 (windower.ffxi.get_mob_array) を読むだけの調べもの。
-- 姿が見えない敵 (アビセアンなど) が一覧に載っていて、名前と座標が読めるかを確かめる。
--   //nmt scan           : 登録されている NM のうち、今のエリアの名前に一致するもの (見えなくても)
--   //nmt scan all        : 描画されていない (valid_target が偽の) 敵をすべて (名前が空の敵も含む)
--   //nmt scan near [m]   : 自分から m ヤルム以内の敵をすべて (見えるか・名前があるかに関係なく。初期値 60)
--   //nmt scan <名前>     : 名前の一部に一致する敵 (大文字小文字は区別しない)
-- 結果は data/scan.log にも追記する (あとで調べるため)
local SCAN_LIMIT = 25
local function cmd_scan(args)
    local text = args[1] and table.concat(args, " "):lower() or nil
    local mode = "nm"
    local near_sq
    if text == "all" then mode = "hidden"
    elseif args[1] and args[1]:lower() == "near" then
        mode = "near"
        local m = tonumber(args[2]) or 60
        near_sq = m * m
    elseif text then mode = "text" end
    local array = windower.ffxi.get_mob_array() or {}
    local me = windower.ffxi.get_mob_by_target("me") or {}
    local found, total, hidden, nameless = {}, 0, 0, 0
    for _, mob in pairs(array) do
        if type(mob) == "table" and mob.is_npc ~= false then
            total = total + 1
            if mob.valid_target == false then hidden = hidden + 1 end
            local has_name = mob.name and mob.name ~= ""
            if not has_name then nameless = nameless + 1 end
            local hit = false
            if mode == "hidden" then
                hit = mob.valid_target == false
            elseif mode == "near" then
                hit = (mob.distance or math.huge) <= near_sq
            elseif has_name then
                local l = mob.name:lower()
                if mode == "text" then
                    hit = l:find(text, 1, true) ~= nil
                else
                    for _, e in ipairs(name_index[l] or {}) do
                        if zone_sets[e.key][current_zone] then hit = true end
                    end
                end
            end
            if hit then found[#found + 1] = mob end
        end
    end
    table.sort(found, function(a, b) return (a.distance or math.huge) < (b.distance or math.huge) end)

    local lines = {}
    lines[#lines + 1] = string.format("[NMTimer scan] %s ID %d / 敵の一覧 %d 体 (うち描画されていない %d 体・名前なし %d 体) / 一致 %d 体",
        zone_label(current_zone), current_zone, total, hidden, nameless, #found)
    if me.x then
        lines[#lines + 1] = string.format("  自分: X %.1f Y %.1f Z %.1f 向き %s", me.x, me.y or 0, me.z or 0, tostring(me.heading))
    end
    for i, mob in ipairs(found) do
        if i > SCAN_LIMIT then
            lines[#lines + 1] = string.format("  …ほか %d 体 (多いので省略。名前で絞れます: //nmt scan <名前>)", #found - SCAN_LIMIT)
            break
        end
        lines[#lines + 1] = string.format("  %s ID %s 距離 %s X %s Y %s Z %s 描画ターゲット可=%s 状態=%s HP=%s%%",
            (mob.name and mob.name ~= "") and utf8_name(mob.name) or "(名前なし)", tostring(mob.id),
            mob.distance and string.format("%.1fYm", math.sqrt(mob.distance)) or "?",
            mob.x and string.format("%.1f", mob.x) or "?", mob.y and string.format("%.1f", mob.y) or "?",
            mob.z and string.format("%.1f", mob.z) or "?",
            tostring(mob.valid_target), tostring(mob.status), tostring(mob.hpp))
    end
    if #found == 0 then
        lines[#lines + 1] = "  一致する敵は、敵の一覧にありません。"
        if mode == "nm" then lines[#lines + 1] = "  (見えない NM が一覧に載っていない可能性があります。ジェイドで光った方向の近くで、もう一度試してください)" end
    else
        -- 最初の 1 体の、一覧で読める項目を全部出す (どんな項目が使えるかを調べるため)
        local keys = {}
        for k, v in pairs(found[1]) do
            if type(v) ~= "table" and type(v) ~= "function" then keys[#keys + 1] = tostring(k) .. "=" .. tostring(v) end
        end
        table.sort(keys)
        lines[#lines + 1] = "  項目 (先頭の 1 体): " .. table.concat(keys, ", ")
    end
    for _, line in ipairs(lines) do chat(line, 207) end
    ensure_dir()
    local f = io.open(DATA_DIR .. "scan.log", "a")
    if f then
        f:write(os.date("%Y-%m-%d %H:%M:%S") .. "\n")
        for _, line in ipairs(lines) do f:write(line .. "\n") end
        f:write("\n")
        f:close()
    end
end

local function print_help()
    chat("[NMTimer] //nmt list [all]        : 今のエリア(または全部)の NM の一覧")
    chat("[NMTimer] //nmt off/on <NM>       : 追跡をやめる / 再開する (HUD から消える)")
    chat("[NMTimer] //nmt tod <NM> [分前]    : 倒された時刻を手で記録 (見ていなかった討伐用)")
    chat("[NMTimer] //nmt time <NM> <分> [最大分] : 再出現の時間を決める(reset で戻す)")
    chat("[NMTimer] //nmt add [名前] [分]    : 今ターゲットしている敵(または名前)を追加")
    chat("[NMTimer] //nmt alias <NM>         : ターゲットの敵の名前を、その NM の別名にする")
    chat("[NMTimer] //nmt remove <NM>        : 自分で足した NM を消す")
    chat("[NMTimer] //nmt clear [NM]         : 記録を消す")
    chat("[NMTimer] //nmt ph                : ターゲットした敵を PH に加える (何体でも)。ph list / ph del [ID] / ph clear <NM>")
    chat("[NMTimer] //nmt phtime <NM> <分>   : PH の再湧き時間を決める (reset で実測に戻す)")
    chat("[NMTimer] //nmt scan [all|near [m]|名前] : 敵の一覧を調べる (見えない NM が一覧にあるか。読むだけ)")
    chat("[NMTimer] //nmt lead <分>          : 出られる何分前に知らせるか (0 で無し)")
    chat("[NMTimer] //nmt sound|chat|hud|coord on|off, //nmt pos X Y, //nmt size N, //nmt expire <分>")
    chat("[NMTimer] //nmt status             : 今の記録  /  //nmt debug : 倒れた敵の名前を表示")
end

local function on_off(arg, current)
    if arg == "on" then return true end
    if arg == "off" then return false end
    return not current
end

windower.register_event("addon command", function(cmd, ...)
    local ok, err = pcall(function(...)
        local args = {...}
        cmd = cmd and cmd:lower() or "help"

        if cmd == "list" then
            cmd_list(args[1] and args[1]:lower() == "all")

        elseif cmd == "status" or cmd == "s" then
            cmd_status()

        elseif cmd == "off" or cmd == "on" then
            local e = need_entry(args, "//nmt " .. cmd .. " <NM>")
            if not e then return end
            if cmd == "off" then
                user.ignored[e.key] = true
                clear_for(e)
                local saved = save_user()
                chat(string.format("[NMTimer] %s の追跡をやめました。戻すには //nmt on %s%s", e.name, e.key, unsaved_note(saved)))
            else
                user.ignored[e.key] = nil
                local saved = save_user()
                chat(string.format("[NMTimer] %s の追跡を再開しました。%s", e.name, unsaved_note(saved)))
            end

        elseif cmd == "tod" then
            local e, rest = need_entry(args, "//nmt tod <NM> [何分前]")
            if not e then return end
            local ago = (tonumber(rest[1]) or 0) * 60
            if not finite(ago) or ago < 0 then        -- 負の値・無限大は、倒した時刻が未来になる
                chat("[NMTimer] 何分前かは 0 以上の数で書いてください。 //nmt tod <NM> [何分前]", 123)
                return
            end
            record_kill(e, current_zone, nil, nil, nil, os.time() - ago, true)

        elseif cmd == "time" then
            local e, rest = need_entry(args, "//nmt time <NM> <分> [最大分]")
            if not e then return end
            if rest[1] and rest[1]:lower() == "reset" then
                user.times[e.key] = nil
                local saved = save_user()
                chat(string.format("[NMTimer] %s の時間を元に戻しました。%s", e.name, unsaved_note(saved)))
                return
            end
            local min, max = tonumber(rest[1]), tonumber(rest[2])
            if not min or min <= 0 then
                chat("[NMTimer] //nmt time <NM> <分> [最大分]  (例: //nmt time shoggoth 60)", 123)
                return
            end
            user.times[e.key] = {min = min, max = max and max > min and max or nil}
            local saved = save_user()
            chat(string.format("[NMTimer] %s の時間を %s にしました。%s", e.name, describe_wait(e), unsaved_note(saved)))

        elseif cmd == "add" then
            local name = target_name()
            local nums, words = {}, {}
            for _, a in ipairs(args) do
                if tonumber(a) then nums[#nums + 1] = tonumber(a) else words[#words + 1] = a end
            end
            local raw = #words > 0 and table.concat(words, " ") or name
            if not raw or raw == "" then
                chat("[NMTimer] 追加する敵をターゲットするか、名前を書いてください。 //nmt add [名前] [分]", 123)
                return
            end
            local e = {key = make_key(utf8_name(raw)), name = utf8_name(raw), alias = {raw}, kind = "timed",
                zone_ids = {current_zone}, min = nums[1], max = nums[2], user = true}
            user.entries[#user.entries + 1] = e
            local saved = save_user()
            rebuild_index()
            chat(string.format("[NMTimer] %s を追加しました(%s / %s)。倒れたら記録します。%s", e.name, zone_label(current_zone), describe_wait(e) or "時間不明", unsaved_note(saved)))

        elseif cmd == "alias" then
            local e = need_entry(args, "//nmt alias <NM>  (別名にしたい敵をターゲットしておく)")
            if not e then return end
            local name = target_name()
            if not name then chat("[NMTimer] 別名にする敵をターゲットしてください。", 123) return end
            user.alias[e.key] = user.alias[e.key] or {}
            table.insert(user.alias[e.key], name)
            local saved = save_user()
            rebuild_index()
            chat(string.format("[NMTimer] %s の別名に「%s」を足しました。%s", e.name, utf8_name(name), unsaved_note(saved)))

        elseif cmd == "remove" then
            local e = need_entry(args, "//nmt remove <NM>")
            if not e then return end
            if not e.user then chat("[NMTimer] 同梱の NM は消せません。追跡をやめるには //nmt off", 123) return end
            for i, ue in ipairs(user.entries) do
                if ue.key == e.key then table.remove(user.entries, i) break end
            end
            clear_for(e)
            local saved = save_user()
            rebuild_index()
            chat(string.format("[NMTimer] %s を消しました。%s", e.name, unsaved_note(saved)))

        elseif cmd == "clear" then
            if #args == 0 then
                state.records, state.ph_slots = {}, {}
                recount_pending()
                local saved = save_state(true)
                chat("[NMTimer] 記録を全部消しました。" .. unsaved_note(saved))
            else
                local e = need_entry(args, "//nmt clear [NM]")
                if not e then return end
                local saved = clear_for(e)
                chat(string.format("[NMTimer] %s の記録を消しました。%s", e.name, unsaved_note(saved)))
            end

        elseif cmd == "ph" then
            -- //nmt ph [add] : ターゲットした敵を PH に加える (何体でも)。//nmt ph del [ID] : PH から外す。//nmt ph list : 一覧
            local sub = args[1] and args[1]:lower()
            local function target_mob()
                local t = windower.ffxi.get_mob_by_target("t")
                if t and t.name and t.id then return t end
            end
            if sub == "list" then
                cmd_ph_list()

            elseif sub == "clear" then
                local e = need_entry({unpack(args, 2)}, "//nmt ph clear <NM>")
                if not e then return end
                user.ph_ids[e.key] = nil
                local saved = save_user()
                chat(string.format("[NMTimer] %s の PH の指定を全部消しました。近くで倒れた同じ名前の敵を数えます。%s", e.name, unsaved_note(saved)))

            elseif sub == "del" or sub == "remove" then
                -- 倒れた敵はターゲットできないので、ID の数字でも指定できる (//nmt ph list や記録の知らせに ID が出る)
                local id = tonumber(args[2])
                if not id then
                    local t = target_mob()
                    id = t and t.id
                end
                if not id then
                    chat("[NMTimer] 外す敵をターゲットするか、ID を書いてください。 //nmt ph del [ID]", 123)
                    return
                end
                for _, marked in pairs(user.ph_ids) do marked[id] = nil end
                for rk, slots in pairs(state.ph_slots) do
                    slots[id] = nil
                    if next(slots) == nil then state.ph_slots[rk] = nil end
                end
                for _, list in pairs(state.ph_measured) do
                    for i = #list, 1, -1 do
                        if type(list[i]) == "table" and list[i].id == id then table.remove(list, i) end
                    end
                end
                user.ph_excluded[id] = true
                ph_pending[id] = nil
                local saved_user = save_user()
                local saved = save_state(true) and saved_user
                recount_pending()
                chat(string.format("[NMTimer] ID %s を PH から外しました(記録と実測も消しました)。戻すには、その敵をターゲットして //nmt ph%s", id_tag(id), unsaved_note(saved)))

            else
                local t = target_mob()
                if not t then
                    chat("[NMTimer] 抽選の対象の PH をターゲットして //nmt ph と打ってください(何体でも登録できます)。", 123)
                    return
                end
                local hit = {}
                for _, e in ipairs(ph_index[t.name:lower()] or {}) do
                    if zone_sets[e.key][current_zone] then hit[#hit + 1] = e end
                end
                if #hit == 0 then
                    chat(string.format("[NMTimer] 「%s」は、このエリアの NM の PH として登録されていません。", utf8_name(t.name)), 123)
                    return
                end
                user.ph_excluded[t.id] = nil
                for _, e in ipairs(hit) do
                    user.ph_ids[e.key] = user.ph_ids[e.key] or {}
                    user.ph_ids[e.key][t.id] = true
                    local n = 0
                    for _ in pairs(user.ph_ids[e.key]) do n = n + 1 end
                    chat(string.format("[NMTimer] %s の PH に、この %s(ID %s)を加えました(指定は %d 体)。指定がある間は、指定した敵だけ数えます。",
                        e.name, utf8_name(t.name), id_tag(t.id), n))
                end
                if not save_user() then chat("[NMTimer] " .. unsaved_note(false), 123) end
            end

        elseif cmd == "scan" then
            cmd_scan(args)

        elseif cmd == "phtime" then
            local e, rest = need_entry(args, "//nmt phtime <NM> <分>")
            if not e then return end
            if rest[1] and rest[1]:lower() == "reset" then
                user.ph_times[e.key] = nil
                local saved = save_user()
                chat(string.format("[NMTimer] %s の PH の再湧き時間を元に戻しました(実測があればそれを使います)。%s", e.name, unsaved_note(saved)))
                return
            end
            local minutes = tonumber(rest[1])
            if not minutes or minutes <= 0 then
                chat("[NMTimer] //nmt phtime <NM> <分>  (例: //nmt phtime golden_bat 5。reset で戻す)", 123)
                return
            end
            user.ph_times[e.key] = minutes
            local saved = save_user()
            chat(string.format("[NMTimer] %s の PH の再湧き時間を %s分にしました。%s", e.name, tostring(minutes), unsaved_note(saved)))

        elseif cmd == "lead" then
            local n = tonumber(args[1])
            if not n or n < 0 then chat(string.format("[NMTimer] 今は %d分前です。 //nmt lead <分>", settings.lead_min)) return end
            settings.lead_min = n
            if save_settings() then chat(string.format("[NMTimer] 出られる %d分前に知らせます。", n)) end

        elseif cmd == "expire" then
            local n = tonumber(args[1])
            if not n or n < 0 then chat(string.format("[NMTimer] 今は %d分です。 //nmt expire <分>", settings.expire_min)) return end
            settings.expire_min = n
            if save_settings() then chat(string.format("[NMTimer] 出られるようになってから %d分で HUD から消します。", n)) end

        elseif cmd == "sound" or cmd == "chat" or cmd == "hud" or cmd == "coord" then
            local field = cmd == "hud" and "show" or cmd
            settings[field] = on_off(args[1] and args[1]:lower(), settings[field])
            if save_settings() then chat(string.format("[NMTimer] %s: %s", cmd, settings[field] and "オン" or "オフ")) end
            last_hud_text = nil

        elseif cmd == "pos" and tonumber(args[1]) and tonumber(args[2]) then
            settings.pos.x, settings.pos.y = tonumber(args[1]), tonumber(args[2])
            hud:pos(settings.pos.x, settings.pos.y)
            save_settings()

        elseif cmd == "size" and tonumber(args[1]) then
            local size = math.max(6, math.min(40, tonumber(args[1])))
            settings.text.size = size
            hud:size(size)
            save_settings()

        elseif cmd == "debug" then
            settings.debug = on_off(args[1] and args[1]:lower(), settings.debug)
            if save_settings() then chat(string.format("[NMTimer] debug: %s(倒れた敵の名前を表示します。別名を探すときに使います)", settings.debug and "オン" or "オフ")) end

        elseif cmd == "watch" then
            local wid = tonumber(args[1])
            if wid then
                watch_ids[wid] = not watch_ids[wid] or nil
                chat(string.format("[NMTimer] ID %s の更新を%s(//nmt debug on のときに表示します)", id_tag(wid), watch_ids[wid] and "監視します" or "監視しません"))
            else
                watch_ids = {}
                chat("[NMTimer] 監視を全部やめました。使い方: //nmt watch <敵のID> (調査用。保存しません)")
            end

        else
            print_help()
        end
    end, ...)
    if not ok then report_error("コマンドエラー", err) end
end)

-- -----------------------------------------------------------------------------
-- 起動
-- -----------------------------------------------------------------------------
ensure_dir()
update_zone()
do
    local info = windower.ffxi.get_info()
    logged_in = info and info.logged_in and true or false
end
load_all()
mark_returned()                                -- 読み込み直したり起動し直したあいだは見ていなかった
recount_pending()
