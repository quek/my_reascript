--[[
   口パク画像貼り付け
   クリップ名を歌詞として使う。
   VOICEVOX の API で歌唱時の発音とタイミングを取得する。
   対応した口画像をタイムラインに貼り付ける。
]]

-- 共通ライブラリ読み込み
local script_dir = debug.getinfo(1, "S").source:match("@(.+[\\/])")
local common = dofile(script_dir .. "common.lua")

local CONFIG = common.CONFIG
local log = common.log
local show_log = common.show_log
local read_file = common.read_file
local write_file = common.write_file
local frames_to_seconds = common.frames_to_seconds

--------------------------------------------------------------------------------
-- 口パク固有設定
--------------------------------------------------------------------------------

local MOUTH_DIR = "C:\\Users\\ancient\\Pictures\\素材\\中国うさぎ立ち絵素材2.0\\中国うさぎ立ち絵素材2.0\\!口\\"

-- phoneme → 口画像ファイル名のマッピング
local MOUTH_MAP = {
    -- 母音
    a = "_おあー.png",
    i = "_えあー.png",    -- 横に開く
    u = "_お.png",        -- 唇をすぼめる
    e = "_にへ.png",
    o = "_お.png",
    -- 特殊
    N = "_ん.png",        -- ん
    cl = "_ほほえみ.png", -- 促音（閉じた口）
    pau = "_ほほえみ.png", -- ポーズ
    -- デフォルト（閉じた口）
    default = "_ほほえみ.png",
}

-- 母音セット（子音の場合は次の母音の口形状を使う）
local VOWELS = { a = true, i = true, u = true, e = true, o = true, N = true }

local FILES = {
    query = CONFIG.TEMP_DIR .. "pakupaku_query.json",
    response = CONFIG.TEMP_DIR .. "pakupaku_response.json",
}

--------------------------------------------------------------------------------
-- JSONパース（phoneme配列の抽出）
--------------------------------------------------------------------------------

local function parse_phonemes(json)
    local phonemes = {}

    local phonemes_start = json:find('"phonemes"%s*:%s*%[')
    if not phonemes_start then return {} end

    local depth = 0
    local in_array = false
    local array_start = json:find('%[', phonemes_start)

    for i = array_start, #json do
        local c = json:sub(i, i)
        if c == '[' then
            depth = depth + 1
            in_array = true
        elseif c == ']' then
            depth = depth - 1
            if depth == 0 and in_array then
                local phonemes_json = json:sub(array_start, i)

                for phoneme_block in phonemes_json:gmatch('%{[^%}]+%}') do
                    local phoneme = phoneme_block:match('"phoneme"%s*:%s*"([^"]+)"')
                    local frame_length = phoneme_block:match('"frame_length"%s*:%s*(%d+)')

                    if phoneme and frame_length then
                        table.insert(phonemes, {
                            phoneme = phoneme,
                            frame_length = tonumber(frame_length)
                        })
                    end
                end
                break
            end
        end
    end

    return phonemes
end

--------------------------------------------------------------------------------
-- VOICEVOX API
--------------------------------------------------------------------------------

local function voicevox_sing_query(json_body)
    write_file(FILES.query, json_body)

    local cmd = string.format(
        'curl.exe -s -X POST "%s/sing_frame_audio_query?speaker=%d" -H "Content-Type: application/json" --data-binary "@%s" -o "%s"',
        CONFIG.VOICEVOX_URL, CONFIG.QUERY_SPEAKER, FILES.query, FILES.response
    )
    reaper.ExecProcess(cmd, 30000)

    local content = read_file(FILES.response)
    if not content or content:find('"detail"') then
        return nil
    end

    return content
end

--------------------------------------------------------------------------------
-- REAPER操作（画像挿入）
--------------------------------------------------------------------------------

local function get_or_create_mouth_track()
    local track_name = "!口"

    for i = 0, reaper.CountTracks(0) - 1 do
        local track = reaper.GetTrack(0, i)
        local _, name = reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
        if name == track_name then
            return track
        end
    end

    local track_count = reaper.CountTracks(0)
    reaper.InsertTrackAtIndex(track_count, true)
    local new_track = reaper.GetTrack(0, track_count)
    reaper.GetSetMediaTrackInfo_String(new_track, "P_NAME", track_name, true)

    return new_track
end

local function delete_items_in_range(track, start_time, end_time)
    for i = reaper.CountTrackMediaItems(track) - 1, 0, -1 do
        local item = reaper.GetTrackMediaItem(track, i)
        local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
        local item_end = item_pos + reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
        if item_pos < end_time and item_end > start_time then
            reaper.DeleteTrackMediaItem(track, item)
        end
    end
end

local function insert_mouth_image(image_path, position, duration, track)
    local item = reaper.AddMediaItemToTrack(track)
    reaper.SetMediaItemInfo_Value(item, "D_POSITION", position)
    reaper.SetMediaItemInfo_Value(item, "D_LENGTH", duration)

    local take = reaper.AddTakeToMediaItem(item)
    local source = reaper.PCM_Source_CreateFromFile(image_path)
    reaper.SetMediaItemTake_Source(take, source)

    local filename = image_path:match("([^\\]+)$")
    reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", filename, true)

    return item
end

local function get_mouth_image(phoneme)
    local filename = MOUTH_MAP[phoneme] or MOUTH_MAP.default
    return MOUTH_DIR .. filename
end

local function fill_gaps_with_default(track, start_time, end_time)
    local default_image = MOUTH_DIR .. MOUTH_MAP.default

    -- 範囲内でend_timeを超えるアイテムを短縮
    for i = reaper.CountTrackMediaItems(track) - 1, 0, -1 do
        local item = reaper.GetTrackMediaItem(track, i)
        local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
        local item_len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
        local item_end = item_pos + item_len

        if item_pos >= start_time and item_pos < end_time and item_end > end_time then
            reaper.SetMediaItemInfo_Value(item, "D_LENGTH", end_time - item_pos)
        end
    end

    -- トラック上のアイテムを時間順に取得
    local items = {}
    for i = 0, reaper.CountTrackMediaItems(track) - 1 do
        local item = reaper.GetTrackMediaItem(track, i)
        local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
        local item_len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
        if item_pos < end_time and item_pos + item_len > start_time then
            table.insert(items, { pos = item_pos, len = item_len, item_end = item_pos + item_len })
        end
    end

    table.sort(items, function(a, b) return a.pos < b.pos end)

    -- ギャップを検出してデフォルト画像で埋める
    local current_pos = start_time

    for _, item_info in ipairs(items) do
        if item_info.pos > current_pos + 0.001 then
            local gap_duration = item_info.pos - current_pos
            insert_mouth_image(default_image, current_pos, gap_duration, track)
        end
        current_pos = math.max(current_pos, item_info.item_end)
    end

    -- 最後のアイテムの後にギャップがあれば埋める
    if current_pos < end_time - 0.001 then
        local gap_duration = end_time - current_pos
        insert_mouth_image(default_image, current_pos, gap_duration, track)
    end

    -- 最終確認: 範囲内でend_timeを超えるアイテムを短縮
    for i = reaper.CountTrackMediaItems(track) - 1, 0, -1 do
        local item = reaper.GetTrackMediaItem(track, i)
        local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
        local item_len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
        local item_end = item_pos + item_len

        if item_pos >= start_time and item_pos < end_time and item_end > end_time then
            reaper.SetMediaItemInfo_Value(item, "D_LENGTH", end_time - item_pos)
        end
    end
end

--------------------------------------------------------------------------------
-- メイン処理
--------------------------------------------------------------------------------

local function main()
    common.clear_log()
    log("=== 口パク画像貼り付け ===")

    -- VOICEVOX起動確認
    if not common.ensure_voicevox_running() then
        return false
    end

    -- MIDIアイテム取得
    local item, take, item_name = common.get_selected_midi_item()
    if not item then return false end

    -- MIDI情報取得
    local bpm, ppq_per_qn = common.get_project_info(take)
    local notes = common.get_midi_notes(take)

    if #notes == 0 then
        log("エラー: MIDIノートがありません")
        return false
    end

    local lyrics = common.split_lyrics(item_name)
    log(string.format("BPM: %.1f, ノート数: %d, 歌詞: %s", bpm, #notes, table.concat(lyrics, "")))

    -- クエリJSON生成
    local query_json = common.build_sing_query_json(notes, lyrics, bpm, ppq_per_qn)
    log("クエリ送信中...")

    -- VOICEVOXでphoneme情報取得
    local response = voicevox_sing_query(query_json)
    if not response then
        log("エラー: VOICEVOX APIエラー")
        return false
    end

    -- phoneme解析
    local phonemes = parse_phonemes(response)
    if #phonemes == 0 then
        log("エラー: phoneme情報が取得できませんでした")
        return false
    end

    log(string.format("phoneme数: %d", #phonemes))

    -- MIDIアイテムの開始・終了位置
    local item_start = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local item_length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    local item_end = item_start + item_length

    -- phonemesの配置開始位置（最初のノートの位置からREST_FRAMESを引く）
    local first_note_time = reaper.MIDI_GetProjTimeFromPPQPos(take, notes[1].startppq)
    local phoneme_start_time = first_note_time - frames_to_seconds(CONFIG.REST_FRAMES)

    -- phonemesの合計時間
    local total_frames = 0
    for _, p in ipairs(phonemes) do
        total_frames = total_frames + p.frame_length
    end

    -- 口パクトラック取得
    local video_track = get_or_create_mouth_track()

    -- 選択状態を保存
    local selected_items = common.get_selected_items()

    -- Undo開始
    reaper.Undo_BeginBlock()

    -- 既存の口パク画像を削除（MIDIアイテム全体の範囲）
    delete_items_in_range(video_track, item_start, item_end)

    -- 口画像を配置（phonemesの開始位置から）
    local current_time = phoneme_start_time
    local prev_phoneme = nil
    local prev_item = nil

    for i, p in ipairs(phonemes) do
        local duration = frames_to_seconds(p.frame_length)

        -- MIDIアイテムの終端を超えないようにする
        if current_time >= item_end then
            break
        end
        if current_time + duration > item_end then
            duration = item_end - current_time
        end

        -- 子音の場合は次の母音の口形状を使う
        local effective_phoneme = p.phoneme
        if not VOWELS[p.phoneme] and p.phoneme ~= "pau" and p.phoneme ~= "cl" then
            for j = i + 1, #phonemes do
                if VOWELS[phonemes[j].phoneme] then
                    effective_phoneme = phonemes[j].phoneme
                    break
                elseif phonemes[j].phoneme == "pau" or phonemes[j].phoneme == "cl" then
                    break
                end
            end
        end

        -- 同じ口形状が連続する場合は結合
        local mouth_file = get_mouth_image(effective_phoneme)
        local prev_mouth_file = prev_phoneme and get_mouth_image(prev_phoneme) or nil

        if prev_item and mouth_file == prev_mouth_file then
            local prev_duration = reaper.GetMediaItemInfo_Value(prev_item, "D_LENGTH")
            reaper.SetMediaItemInfo_Value(prev_item, "D_LENGTH", prev_duration + duration)
        else
            prev_item = insert_mouth_image(mouth_file, current_time, duration, video_track)
        end

        prev_phoneme = effective_phoneme
        current_time = current_time + duration
    end

    -- ギャップをデフォルト画像で埋める（MIDIアイテム全体の範囲）
    fill_gaps_with_default(video_track, item_start, item_end)

    -- Undo終了
    reaper.Undo_EndBlock("口パク画像貼り付け", -1)

    -- 選択状態を復元
    reaper.SelectAllMediaItems(0, false)
    for _, sel_item in ipairs(selected_items) do
        reaper.SetMediaItemSelected(sel_item, true)
    end

    reaper.UpdateArrange()

    log("完了！")
    return true
end

-- 実行（エラー時のみログ表示）
if main() == false then
    show_log()
end
