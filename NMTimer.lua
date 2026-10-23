-- =============================================================================
-- NMTimer.lua : NM の再出現タイマー (v0.5.2)
-- =============================================================================
-- 【目的】
-- メイジャンの試練 (エンピリアン武器) に出る NM などが倒されたとき、その時刻と場所を覚え、
-- 次に出られるまでの残り時間を HUD に出す。先に誰かに倒されて間に合わなかった NM も、
-- 倒された時刻と場所が分かれば次を狙える。
--
-- 【覚えるもの】
--   - 抽選型 (lottery) : PH を倒すと NM が出る型。NM を倒してから、一定時間は抽選が始まらない。その時間を数える
--   - 時間型 (timed)   : 倒してから一定時間で再出現する型 (アビセアンなど)
--   ※ 同梱の NM は nm_data.lua。自分で足した NM は data/user.lua に保存する (//nmt add)
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
--
-- 【文字コード】
--   - HUD (libs/texts.lua) : UTF-8
--   - チャット (windower.add_to_chat) : Shift-JIS (windower.to_shift_jis)
-- =============================================================================

_addon.name     = "NMTimer"
_addon.author   = "hikaruoshino"
_addon.version  = "0.5.2"
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

local function write_table(path, tbl)
    local f = io.open(path, "w")
    if not f then return false end
    f:write("return " .. serialize(tbl) .. "\n")
    f:close()
    return true
end

local function read_table(path)
    local chunk = loadfile(path)
    if not chunk then return nil end
    setfenv(chunk, {})
    local ok, tbl = pcall(chunk)
    if ok and type(tbl) == "table" then return tbl end
    return nil
end

local last_error_at = -100
local function report_error(where, err)
    local now = os.clock()
    if now - last_error_at < 10 then return end   -- 同じエラーで画面を埋めない
    last_error_at = now
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
local zone_by_en = nil
local current_zone = 0
local state_dirty = false  -- 画面の更新で記録が消えたとき、保存し直すための印
local pending_sight = false -- 再出現の実測を待っている記録があるか (パケットごとの確認を軽くするため)
local ph_pending = {}       -- 再湧きの実測を待っている PH の ID → 記録の key のつづき (rk)
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
    entries, by_key, name_index, ph_index, zone_sets = {}, {}, {}, {}, {}
    local function add_entry(e)
        if by_key[e.key] then return end
        local set = {}
        for _, z in ipairs(e.zone_ids or {}) do set[z] = true end
        for _, zname in ipairs(e.zones or {}) do
            local id = zone_id_of(zname)
            if id then set[id] = true end
        end
        zone_sets[e.key] = set
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

local function save_state()
    ensure_dir()
    write_table(STATE_FILE, state)
end

local function save_user()
    ensure_dir()
    write_table(USER_FILE, user)
end

local function load_all()
    local chunk = loadfile(windower.addon_path .. "nm_data.lua")
    builtin = {}
    if chunk then
        local ok, tbl = pcall(chunk)
        if ok and type(tbl) == "table" then builtin = tbl end
    end
    local u = read_table(USER_FILE) or {}
    user = {entries = u.entries or {}, alias = u.alias or {}, times = u.times or {}, ignored = u.ignored or {},
            ph_ids = u.ph_ids or {}, ph_times = u.ph_times or {}, ph_excluded = u.ph_excluded or {}}
    local s = read_table(STATE_FILE) or {}
    state = {records = s.records or {}, ph_slots = s.ph_slots or {}, ph_measured = s.ph_measured or {}, measured = s.measured or {}}
    rebuild_index()
end

-- 実際に使う時間 (分)。ユーザーが決めた値が先。戻り値: 最短, 最長, 目安か
local function timing(e)
    local u = user.times[e.key]
    if u and u.min then return u.min, u.max, false end
    return e.min, e.max, e.approx and true or false
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
            if slot.sight and slot.zone == current_zone then ph_pending[id] = rk end
        end
    end
end

local function median(list)
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
    local min, max, approx = timing(e)
    if not min then return nil end
    local text
    if max and max > min then text = string.format("%d〜%d分", min, max) else text = string.format("%d分", min) end
    if approx then text = text .. "(目安)" end
    return text
end

local function record_kill(e, zone, x, y, z, when)
    if not tracked(e) then return end
    local rk = rec_key(e, zone)
    state.records[rk] = {key = e.key, zone = zone, at = when, x = x, y = y, z = z, sight = (zone == current_zone)}
    save_state()
    recount_pending()
    local wait = describe_wait(e)
    local label = e.kind == "lottery" and "抽選の開始" or "再出現"
    if wait then
        chat(string.format("[NMTimer] %s を記録しました(%s)。%sまで %s", e.name, zone_label(zone), label, wait))
    else
        chat(string.format("[NMTimer] %s を記録しました(%s)。再出現の時間は不明です。//nmt time %s <分> で決められます", e.name, zone_label(zone), e.key), 167)
    end
end

local function record_ph(e, zone, id, x, y, when)
    if not tracked(e) then return end
    local rk = rec_key(e, zone)
    local slots = state.ph_slots[rk] or {}
    slots[id] = {key = e.key, zone = zone, at = when, x = x, y = y, sight = (zone == current_zone)}
    state.ph_slots[rk] = slots
    save_state()
    recount_pending()
    if settings.chat and not ph_told[id] then
        ph_told[id] = true
        chat(string.format("[NMTimer] PH(%s ID %d)を記録しました(%s)。この敵が PH でなければ //nmt ph del %d", e.ph and e.ph[1] or "PH", id, e.name, id), 160)
    end
end

-- PH が再び現れた (同じ ID)。倒してから見続けていたときだけ、かかった時間を実測として覚える
local function on_ph_respawn(id, when)
    local rk = ph_pending[id]
    if not rk then return end
    local slots = state.ph_slots[rk]
    local slot = slots and slots[id]
    if not slot then ph_pending[id] = nil return end
    local secs = when - slot.at
    if secs < PH_SIGHT_MIN_SEC then return end              -- 倒れる途中の更新かもしれない
    slots[id] = nil
    local e = by_key[slot.key]
    if e and slot.sight and secs <= PH_SLOT_KEEP_SEC then
        local list = state.ph_measured[rk] or {}
        list[#list + 1] = {id = id, secs = secs, at = when}
        while #list > 10 do table.remove(list, 1) end
        state.ph_measured[rk] = list
        chat(string.format("[NMTimer] %s の PH(%s ID %d) が約%d分で再び湧きました(実測 %s)。", e.name, e.ph and e.ph[1] or "PH", id,
            math.floor(secs / 60 + 0.5), fmt_time(secs)))
    end
    if next(slots) == nil then state.ph_slots[rk] = nil end
    save_state()
    recount_pending()
end

local function note_sighting(e, rec, rk, when)
    local secs = when - rec.at
    local list = state.measured[e.key] or {}
    list[#list + 1] = secs
    while #list > 5 do table.remove(list, 1) end
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

local function u32(data, offset)
    local a, b, c, d = data:byte(offset, offset + 3)
    if not d then return nil end
    return a + b * 256 + c * 65536 + d * 16777216
end

local function on_death(id)
    local now_c = os.clock()
    if seen_dead[id] and now_c - seen_dead[id] < 120 then return end   -- 倒れた敵の更新は何度も届くので、同じ敵は 1 回だけ
    seen_dead[id] = now_c
    local mob = windower.ffxi.get_mob_by_id(id)
    if not mob or not mob.name or mob.is_npc == false then return end
    if settings.debug then chat(string.format("[NMTimer debug] 倒れた: %s (ID %d)", mob.name, id), 160) end
    local l = mob.name:lower()
    local when = os.time()
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
            else counted = (mob.distance or 0) <= PH_NEAR_SQ end
            if counted then record_ph(e, current_zone, id, mob.x, mob.y, when) end
        end
    end
end

local function on_sighted(name)
    local when = os.time()
    for _, e in ipairs(name_index[name:lower()] or {}) do
        local rk = rec_key(e, current_zone)
        local rec = state.records[rk]
        if rec and rec.sight and when - rec.at >= SIGHT_MIN_SEC then
            note_sighting(e, rec, rk, when)
        end
    end
end

local function on_npc_update(data)
    if #data < 0x20 then return end
    local mask = data:byte(0x0B)
    if not mask then return end
    local dead = false
    if mask % 8 >= 4 then                       -- ビット 2: HP・状態が入っている
        local status = data:byte(0x20)
        if status and DEAD_STATUS[status] then
            dead = true
            local id = u32(data, 0x05)
            if id then on_death(id) end
        end
    end
    if mask % 16 >= 8 and not dead then         -- ビット 3: 名前が入っている = 現れた (湧き直した)
        local id = u32(data, 0x05)
        if id then
            seen_dead[id] = nil                 -- 同じ敵がまた倒れたら、もう一度数える
            if ph_pending[id] then on_ph_respawn(id, os.time()) end
        end
    end
    if pending_sight and mask % 16 >= 8 and #data >= 0x35 then   -- ビット 3: 名前が入っている (現れたとき)
        local name = data:sub(0x35):match("^[^%z]*")
        if name and name ~= "" then on_sighted(name) end
    end
end

-- 0x02D : 自分が経験値などを得たときに届く通知 (Target = 倒した敵の ID。RoE の更新では Target がプレイヤー)。
-- 全ての討伐が届くわけではない (他の人だけが倒した敵・経験値の入らない敵は届かない) ので、0x00E の補助として使う。
-- 本当に倒れているときだけ数える (二重の記録は seen_dead が防ぐ)
local function on_exp_message(data)
    if #data < 0x0C then return end
    local target = u32(data, 0x09)
    if not target then return end
    local mob = windower.ffxi.get_mob_by_id(target)
    if mob and mob.is_npc ~= false and ((mob.hpp or 100) == 0 or DEAD_STATUS[mob.status or -1]) then
        on_death(target)
    end
end

windower.register_event("incoming chunk", function(id, data)
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
    local min, max, approx = timing(e)
    local elapsed = now - rec.at
    local mark = approx and color_text("(目安)", 150, 150, 150) or ""
    local state_text, order, done_at
    if not min then
        state_text = color_text("時間不明", 180, 180, 180) .. string.format(" 討伐 %s  //nmt time %s <分>", clock_text(rec.at), e.key)
        order = math.huge
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
        if e and tracked(e) then
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
            if not e or now - slot.at > PH_SLOT_KEEP_SEC then
                slots[id] = nil                       -- 古い記録 (実測にも使わない) は捨てる
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

local function refresh_hud(now)
    local rows = build_rows(now)
    if state_dirty then state_dirty = false; save_state() end
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
windower.register_event("prerender", function()
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

windower.register_event("zone change", function(new_id)
    seen_dead = {}
    -- エリアを離れたら、実測はもう取れない (戻ってきたときに出ているのは、いつ出たか分からない)
    for _, rec in pairs(state.records) do rec.sight = false end
    for _, slots in pairs(state.ph_slots) do
        for _, slot in pairs(slots) do slot.sight = false end
    end
    current_zone = tonumber(new_id) or current_zone
    recount_pending()
    save_state()
end)

windower.register_event("login", function()
    update_zone()
    seen_dead = {}
    recount_pending()
end)

local function stop()
    save_state()
    config.save(settings)
    if hud then hud:hide() end
end

windower.register_event("logout", function()
    seen_dead = {}
    stop()
end)

windower.register_event("unload", function()
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
                chat("      指定した PH: ID " .. table.concat(ids, ", ID ") .. string.format(" (%d 体)", #ids))
            else
                chat("      指定した PH: なし (近くで倒れた同じ名前の敵をすべて数えます。//nmt ph で指定)")
            end
            local slot_ids = {}
            for id in pairs(state.ph_slots[rk] or {}) do slot_ids[#slot_ids + 1] = id end
            table.sort(slot_ids)
            for _, id in ipairs(slot_ids) do
                chat(string.format("      記録中: ID %d (%s前に倒した)", id, fmt_time(now - state.ph_slots[rk][id].at)))
            end
            local per_id = {}
            for _, smp in ipairs(state.ph_measured[rk] or {}) do
                if type(smp) == "table" and smp.id then
                    per_id[#per_id + 1] = string.format("ID %d = %s", smp.id, fmt_time(smp.secs))
                end
            end
            if #per_id > 0 then chat("      実測: " .. table.concat(per_id, ", ")) end
        end
    end
    local excluded = {}
    for id in pairs(user.ph_excluded) do excluded[#excluded + 1] = id end
    table.sort(excluded)
    if #excluded > 0 then chat("[NMTimer] PH から外した ID: " .. table.concat(excluded, ", ")) end
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
    save_state()
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
                chat(string.format("[NMTimer] %s の追跡をやめました。戻すには //nmt on %s", e.name, e.key))
            else
                user.ignored[e.key] = nil
                chat(string.format("[NMTimer] %s の追跡を再開しました。", e.name))
            end
            save_user()

        elseif cmd == "tod" then
            local e, rest = need_entry(args, "//nmt tod <NM> [何分前]")
            if not e then return end
            local ago = (tonumber(rest[1]) or 0) * 60
            record_kill(e, current_zone, nil, nil, nil, os.time() - ago)

        elseif cmd == "time" then
            local e, rest = need_entry(args, "//nmt time <NM> <分> [最大分]")
            if not e then return end
            if rest[1] and rest[1]:lower() == "reset" then
                user.times[e.key] = nil
                save_user()
                chat(string.format("[NMTimer] %s の時間を元に戻しました。", e.name))
                return
            end
            local min, max = tonumber(rest[1]), tonumber(rest[2])
            if not min or min <= 0 then
                chat("[NMTimer] //nmt time <NM> <分> [最大分]  (例: //nmt time shoggoth 60)", 123)
                return
            end
            user.times[e.key] = {min = min, max = max and max > min and max or nil}
            save_user()
            chat(string.format("[NMTimer] %s の時間を %s にしました。", e.name, describe_wait(e)))

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
            save_user()
            rebuild_index()
            chat(string.format("[NMTimer] %s を追加しました(%s / %s)。倒れたら記録します。", e.name, zone_label(current_zone), describe_wait(e) or "時間不明"))

        elseif cmd == "alias" then
            local e = need_entry(args, "//nmt alias <NM>  (別名にしたい敵をターゲットしておく)")
            if not e then return end
            local name = target_name()
            if not name then chat("[NMTimer] 別名にする敵をターゲットしてください。", 123) return end
            user.alias[e.key] = user.alias[e.key] or {}
            table.insert(user.alias[e.key], name)
            save_user()
            rebuild_index()
            chat(string.format("[NMTimer] %s の別名に「%s」を足しました。", e.name, utf8_name(name)))

        elseif cmd == "remove" then
            local e = need_entry(args, "//nmt remove <NM>")
            if not e then return end
            if not e.user then chat("[NMTimer] 同梱の NM は消せません。追跡をやめるには //nmt off", 123) return end
            for i, ue in ipairs(user.entries) do
                if ue.key == e.key then table.remove(user.entries, i) break end
            end
            clear_for(e)
            save_user()
            rebuild_index()
            chat(string.format("[NMTimer] %s を消しました。", e.name))

        elseif cmd == "clear" then
            if #args == 0 then
                state.records, state.ph_slots = {}, {}
                recount_pending()
                save_state()
                chat("[NMTimer] 記録を全部消しました。")
            else
                local e = need_entry(args, "//nmt clear [NM]")
                if not e then return end
                clear_for(e)
                chat(string.format("[NMTimer] %s の記録を消しました。", e.name))
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
                save_user()
                chat(string.format("[NMTimer] %s の PH の指定を全部消しました。近くで倒れた同じ名前の敵を数えます。", e.name))

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
                save_user()
                save_state()
                recount_pending()
                chat(string.format("[NMTimer] ID %d を PH から外しました(記録と実測も消しました)。戻すには、その敵をターゲットして //nmt ph", id))

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
                    chat(string.format("[NMTimer] %s の PH に、この %s(ID %d)を加えました(指定は %d 体)。指定がある間は、指定した敵だけ数えます。",
                        e.name, utf8_name(t.name), t.id, n))
                end
                save_user()
            end

        elseif cmd == "scan" then
            cmd_scan(args)

        elseif cmd == "phtime" then
            local e, rest = need_entry(args, "//nmt phtime <NM> <分>")
            if not e then return end
            if rest[1] and rest[1]:lower() == "reset" then
                user.ph_times[e.key] = nil
                save_user()
                chat(string.format("[NMTimer] %s の PH の再湧き時間を元に戻しました(実測があればそれを使います)。", e.name))
                return
            end
            local minutes = tonumber(rest[1])
            if not minutes or minutes <= 0 then
                chat("[NMTimer] //nmt phtime <NM> <分>  (例: //nmt phtime golden_bat 5。reset で戻す)", 123)
                return
            end
            user.ph_times[e.key] = minutes
            save_user()
            chat(string.format("[NMTimer] %s の PH の再湧き時間を %s分にしました。", e.name, tostring(minutes)))

        elseif cmd == "lead" then
            local n = tonumber(args[1])
            if not n or n < 0 then chat(string.format("[NMTimer] 今は %d分前です。 //nmt lead <分>", settings.lead_min)) return end
            settings.lead_min = n
            config.save(settings)
            chat(string.format("[NMTimer] 出られる %d分前に知らせます。", n))

        elseif cmd == "expire" then
            local n = tonumber(args[1])
            if not n or n < 0 then chat(string.format("[NMTimer] 今は %d分です。 //nmt expire <分>", settings.expire_min)) return end
            settings.expire_min = n
            config.save(settings)
            chat(string.format("[NMTimer] 出られるようになってから %d分で HUD から消します。", n))

        elseif cmd == "sound" or cmd == "chat" or cmd == "hud" or cmd == "coord" then
            local field = cmd == "hud" and "show" or cmd
            settings[field] = on_off(args[1] and args[1]:lower(), settings[field])
            config.save(settings)
            chat(string.format("[NMTimer] %s: %s", cmd, settings[field] and "オン" or "オフ"))
            last_hud_text = nil

        elseif cmd == "pos" and tonumber(args[1]) and tonumber(args[2]) then
            settings.pos.x, settings.pos.y = tonumber(args[1]), tonumber(args[2])
            hud:pos(settings.pos.x, settings.pos.y)
            config.save(settings)

        elseif cmd == "size" and tonumber(args[1]) then
            local size = math.max(6, math.min(40, tonumber(args[1])))
            settings.text.size = size
            hud:size(size)
            config.save(settings)

        elseif cmd == "debug" then
            settings.debug = on_off(args[1] and args[1]:lower(), settings.debug)
            config.save(settings)
            chat(string.format("[NMTimer] debug: %s(倒れた敵の名前を表示します。別名を探すときに使います)", settings.debug and "オン" or "オフ"))

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
load_all()
recount_pending()
