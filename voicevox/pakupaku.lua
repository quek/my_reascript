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
local url_encode = common.url_encode
local frames_to_seconds = common.frames_to_seconds
local seconds_to_frames = common.seconds_to_frames

--------------------------------------------------------------------------------
-- 口パク固有設定
--------------------------------------------------------------------------------

-- phoneme → 口画像ファイル名のマッピング
local MOUTH_MAP = {
    -- 母音
    a = "_おあー.png",
    i = "_えあー.png",    -- 横に開く
    u = "_お.png",        -- 唇をすぼめる
    e = "_にへ.png",
    o = "_あは.png",
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
    last_speaker = CONFIG.TEMP_DIR .. "voicevox_last_speaker.txt",
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

local function parse_talk_phonemes(json)
    local phonemes = {}

    -- prePhonemeLength
    local pre = tonumber(json:match('"prePhonemeLength"%s*:%s*([%d%.]+)'))
    if pre and pre > 0 then
        table.insert(phonemes, {phoneme = "pau", frame_length = seconds_to_frames(pre)})
    end

    -- accent_phrases配列を取得
    local ap_array_start = json:find('"accent_phrases"%s*:%s*%[')
    if ap_array_start then
        local bracket_pos = json:find('%[', ap_array_start)
        local depth = 0
        local ap_array_end
        for i = bracket_pos, #json do
            local c = json:sub(i, i)
            if c == '[' then depth = depth + 1
            elseif c == ']' then
                depth = depth - 1
                if depth == 0 then ap_array_end = i; break end
            end
        end

        if ap_array_end then
            local ap_json = json:sub(bracket_pos + 1, ap_array_end - 1)
            local pos = 1

            while pos <= #ap_json do
                -- moras配列を探す
                local moras_start = ap_json:find('"moras"%s*:%s*%[', pos)
                if not moras_start then break end

                local moras_bracket = ap_json:find('%[', moras_start)
                depth = 0
                local moras_end
                for i = moras_bracket, #ap_json do
                    local c = ap_json:sub(i, i)
                    if c == '[' then depth = depth + 1
                    elseif c == ']' then
                        depth = depth - 1
                        if depth == 0 then moras_end = i; break end
                    end
                end
                if not moras_end then break end

                -- 各moraオブジェクトを処理
                local moras_content = ap_json:sub(moras_bracket + 1, moras_end - 1)
                for mora_block in moras_content:gmatch('%{[^%}]+%}') do
                    local consonant = mora_block:match('"consonant"%s*:%s*"([^"]+)"')
                    local consonant_length = tonumber(mora_block:match('"consonant_length"%s*:%s*([%d%.]+)'))
                    local vowel = mora_block:match('"vowel"%s*:%s*"([^"]+)"')
                    local vowel_length = tonumber(mora_block:match('"vowel_length"%s*:%s*([%d%.]+)'))

                    if consonant and consonant_length then
                        table.insert(phonemes, {phoneme = consonant, frame_length = seconds_to_frames(consonant_length)})
                    end
                    if vowel and vowel_length then
                        table.insert(phonemes, {phoneme = vowel, frame_length = seconds_to_frames(vowel_length)})
                    end
                end

                -- pause_moraを探す（moras配列の後、次のaccent_phraseの前）
                local next_moras = ap_json:find('"moras"%s*:', moras_end + 1)
                local search_end = next_moras and next_moras - 1 or #ap_json
                local pause_region = ap_json:sub(moras_end + 1, search_end)

                local pause_match = pause_region:match('"pause_mora"%s*:%s*(%{[^%}]+%})')
                if pause_match then
                    local pause_vowel_length = tonumber(pause_match:match('"vowel_length"%s*:%s*([%d%.]+)'))
                    if pause_vowel_length then
                        table.insert(phonemes, {phoneme = "pau", frame_length = seconds_to_frames(pause_vowel_length)})
                    end
                end

                pos = moras_end + 1
            end
        end
    end

    -- postPhonemeLength
    local post = tonumber(json:match('"postPhonemeLength"%s*:%s*([%d%.]+)'))
    if post and post > 0 then
        table.insert(phonemes, {phoneme = "pau", frame_length = seconds_to_frames(post)})
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

local function get_talk_speaker_id()
    local content = read_file(FILES.last_speaker)
    local id = content and tonumber(content)
    return id or 3
end

local function voicevox_talk_query(text, speaker_id)
    local cmd = string.format(
        'curl.exe -s -X POST "%s/audio_query?speaker=%d&text=%s" -o "%s"',
        CONFIG.VOICEVOX_URL, speaker_id, url_encode(text), FILES.response
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
    return CONFIG.MOUTH_DIR .. filename
end

local function trim_items_at_boundary(track, start_time, end_time)
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

local function fill_gaps_with_default(track, start_time, end_time)
    local default_image = CONFIG.MOUTH_DIR .. MOUTH_MAP.default

    trim_items_at_boundary(track, start_time, end_time)

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

    trim_items_at_boundary(track, start_time, end_time)
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
    local is_sing = #notes > 0

    log(string.format("BPM: %.1f, モード: %s", bpm, is_sing and "歌唱" or "トーク"))

    -- MIDIアイテムの開始・終了位置
    local item_start = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local item_length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    local item_end = item_start + item_length

    local phonemes, phoneme_start_time

    if is_sing then
        -- 歌唱モード
        local lyrics = common.split_lyrics(item_name)
        log(string.format("ノート数: %d, 歌詞: %s", #notes, table.concat(lyrics, "")))

        local query_json = common.build_sing_query_json(notes, lyrics, bpm, ppq_per_qn)
        log("歌唱クエリ送信中...")

        local response = voicevox_sing_query(query_json)
        if not response then
            log("エラー: VOICEVOX APIエラー")
            return false
        end

        phonemes = parse_phonemes(response)
        local first_note_time = reaper.MIDI_GetProjTimeFromPPQPos(take, notes[1].startppq)
        phoneme_start_time = first_note_time - frames_to_seconds(CONFIG.REST_FRAMES)
    else
        -- トークモード
        local speaker_id = get_talk_speaker_id()
        log(string.format("テキスト: %s, スピーカーID: %d", item_name, speaker_id))
        log("トーククエリ送信中...")

        local response = voicevox_talk_query(item_name, speaker_id)
        if not response then
            log("エラー: VOICEVOX APIエラー")
            return false
        end

        phonemes = parse_talk_phonemes(response)
        phoneme_start_time = item_start
    end

    if #phonemes == 0 then
        log("エラー: phoneme情報が取得できませんでした")
        return false
    end

    log(string.format("phoneme数: %d", #phonemes))

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

        -- MIDIアイテムの範囲外はスキップ
        if current_time + duration <= item_start then
            current_time = current_time + duration
            goto continue
        end
        if current_time >= item_end then
            break
        end

        -- 範囲にクランプ
        local actual_start = math.max(current_time, item_start)
        local actual_end = math.min(current_time + duration, item_end)
        duration = actual_end - actual_start

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
            prev_item = insert_mouth_image(mouth_file, actual_start, duration, video_track)
        end

        prev_phoneme = effective_phoneme
        current_time = current_time + frames_to_seconds(p.frame_length)
        ::continue::
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
reaper.defer(function()
    if main() == false then
        show_log()
    end
end)
