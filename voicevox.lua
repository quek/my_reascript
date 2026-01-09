--[[
  VOICEVOX 歌唱合成スクリプト for REAPER
  MIDIノートと歌詞から歌声を生成し、トラックに挿入する
]]

-- 設定
local CONFIG = {
    VOICEVOX_URL = "http://localhost:50021",
    QUERY_SPEAKER = 6000,   -- 波音リツ（歌唱クエリ生成用）
    SYNTH_SPEAKER = 3061,   -- 中国うさぎ（音声合成用）
    TALK_SPEAKER = 61,      -- 中国うさぎ（トーク用）
    FRAME_RATE = 93.75,     -- 24000Hz / 256サンプル
    OUTPUT_SAMPLE_RATE = 48000,
    TEMP_DIR = "C:\\tmp\\",
    REST_FRAMES = 10,       -- 前後の休符フレーム数
}

-- ファイルパス
local FILES = {
    query = CONFIG.TEMP_DIR .. "sing_query.json",
    response = CONFIG.TEMP_DIR .. "sing_response.json",
    modified = CONFIG.TEMP_DIR .. "sing_modified.json",
    output = CONFIG.TEMP_DIR .. "voicevox_sing_output.wav",
}

--------------------------------------------------------------------------------
-- ユーティリティ関数
--------------------------------------------------------------------------------

local function log(msg)
    reaper.ShowConsoleMsg(msg .. "\n")
end

local function read_file(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    return content
end

local function write_file(path, content)
    local f = io.open(path, "w")
    if not f then return false end
    f:write(content)
    f:close()
    return true
end

local function url_encode(str)
    return str:gsub("([^%w%-_%.~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
end

--------------------------------------------------------------------------------
-- MIDI処理
--------------------------------------------------------------------------------

local function get_project_info(take)
    local bpm = reaper.Master_GetTempo()
    local ppq_at_0 = reaper.MIDI_GetPPQPosFromProjQN(take, 0)
    local ppq_at_1 = reaper.MIDI_GetPPQPosFromProjQN(take, 1)
    local ppq_per_qn = ppq_at_1 - ppq_at_0
    return bpm, ppq_per_qn
end

local function get_midi_notes(take)
    local _, note_count = reaper.MIDI_CountEvts(take)
    local notes = {}

    for i = 0, note_count - 1 do
        local retval, _, _, startppq, endppq, _, pitch, _ = reaper.MIDI_GetNote(take, i)
        if retval then
            table.insert(notes, {
                pitch = pitch,
                startppq = startppq,
                endppq = endppq,
                length = endppq - startppq
            })
        end
    end

    table.sort(notes, function(a, b) return a.startppq < b.startppq end)
    return notes
end

local function split_lyrics(text)
    local small_kana = "ぁぃぅぇぉゃゅょっァィゥェォャュョッ"
    local lyrics = {}
    for char in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        if #lyrics > 0 and small_kana:find(char, 1, true) then
            lyrics[#lyrics] = lyrics[#lyrics] .. char
        else
            table.insert(lyrics, char)
        end
    end
    return lyrics
end

--------------------------------------------------------------------------------
-- フレーム計算
--------------------------------------------------------------------------------

local function ppq_to_frames(ppq, bpm, ppq_per_qn)
    local seconds = ppq / ppq_per_qn * (60 / bpm)
    return math.max(math.floor(seconds * CONFIG.FRAME_RATE + 0.5), 1)
end

local function frames_to_seconds(frames)
    return frames / CONFIG.FRAME_RATE
end

--------------------------------------------------------------------------------
-- JSON生成
--------------------------------------------------------------------------------

local function build_notes_json(notes, lyrics, bpm, ppq_per_qn)
    local json_parts = {}

    -- 開始休符
    table.insert(json_parts, string.format(
        '{"id":"rest_start","key":null,"frame_length":%d,"lyric":""}',
        CONFIG.REST_FRAMES
    ))

    for i, note in ipairs(notes) do
        -- ノート間の休符
        if i > 1 then
            local gap = note.startppq - notes[i - 1].endppq
            if gap > 0 then
                table.insert(json_parts, string.format(
                    '{"id":"rest%d","key":null,"frame_length":%d,"lyric":""}',
                    i, ppq_to_frames(gap, bpm, ppq_per_qn)
                ))
            end
        end

        -- ノート
        table.insert(json_parts, string.format(
            '{"id":"note%d","key":%d,"frame_length":%d,"lyric":"%s"}',
            i,
            note.pitch,
            ppq_to_frames(note.length, bpm, ppq_per_qn),
            lyrics[i] or "ん"
        ))
    end

    -- 終了休符
    table.insert(json_parts, string.format(
        '{"id":"rest_end","key":null,"frame_length":%d,"lyric":""}',
        CONFIG.REST_FRAMES
    ))

    return '{"notes":[' .. table.concat(json_parts, ",") .. ']}'
end

--------------------------------------------------------------------------------
-- VOICEVOX API
--------------------------------------------------------------------------------

local function call_voicevox_query(json_body)
    write_file(FILES.query, json_body)

    local cmd = string.format(
        'curl.exe -s -X POST "%s/sing_frame_audio_query?speaker=%d" -H "Content-Type: application/json" --data-binary "@%s" -o "%s"',
        CONFIG.VOICEVOX_URL,
        CONFIG.QUERY_SPEAKER,
        FILES.query,
        FILES.response
    )
    reaper.ExecProcess(cmd, 30000)

    local content = read_file(FILES.response)
    if not content or content:find('"detail"') then
        return nil
    end

    -- サンプリングレート変更
    content = content:gsub(
        '"outputSamplingRate":%s*%d+',
        '"outputSamplingRate":' .. CONFIG.OUTPUT_SAMPLE_RATE
    )
    write_file(FILES.modified, content)

    return true
end

local function call_voicevox_synthesis(output_path)
    local cmd = string.format(
        'curl.exe -s -X POST "%s/frame_synthesis?speaker=%d" -H "Content-Type: application/json" --data-binary "@%s" -o "%s"',
        CONFIG.VOICEVOX_URL,
        CONFIG.SYNTH_SPEAKER,
        FILES.modified,
        output_path
    )
    reaper.ExecProcess(cmd, 60000)
    return true
end

local function call_voicevox_talk(text, output_path)
    -- audio_query
    local cmd = string.format(
        'curl.exe -s -X POST "%s/audio_query?speaker=%d&text=%s" -o "%s"',
        CONFIG.VOICEVOX_URL,
        CONFIG.TALK_SPEAKER,
        url_encode(text),
        FILES.response
    )
    reaper.ExecProcess(cmd, 30000)

    local content = read_file(FILES.response)
    if not content or content:find('"detail"') then
        return false
    end

    -- サンプリングレート変更
    content = content:gsub(
        '"outputSamplingRate":%s*%d+',
        '"outputSamplingRate":' .. CONFIG.OUTPUT_SAMPLE_RATE
    )
    write_file(FILES.modified, content)

    -- synthesis
    cmd = string.format(
        'curl.exe -s -X POST "%s/synthesis?speaker=%d" -H "Content-Type: application/json" --data-binary "@%s" -o "%s"',
        CONFIG.VOICEVOX_URL,
        CONFIG.TALK_SPEAKER,
        FILES.modified,
        output_path
    )
    reaper.ExecProcess(cmd, 60000)
    return true
end

--------------------------------------------------------------------------------
-- REAPER操作
--------------------------------------------------------------------------------

local function get_target_track(source_track)
    local track_idx = reaper.GetMediaTrackInfo_Value(source_track, "IP_TRACKNUMBER")
    local target_track = reaper.GetTrack(0, track_idx)

    if not target_track then
        reaper.InsertTrackAtIndex(track_idx, true)
        target_track = reaper.GetTrack(0, track_idx)
    end

    return target_track
end

local function delete_item_at_position(track, start_pos)
    local tolerance = 0.001  -- 1ms許容
    for i = reaper.CountTrackMediaItems(track) - 1, 0, -1 do
        local item = reaper.GetTrackMediaItem(track, i)
        local item_start = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
        if math.abs(item_start - start_pos) < tolerance then
            reaper.DeleteTrackMediaItem(track, item)
        end
    end
end

local function insert_wav(wav_path, position, track, use_offset, selected_items)
    local orig_pos = reaper.GetCursorPosition()
    local start_pos = position
    if use_offset then
        start_pos = position - frames_to_seconds(CONFIG.REST_FRAMES)
    end
    delete_item_at_position(track, start_pos)
    reaper.SetEditCurPos(start_pos, false, false)
    reaper.SetOnlyTrackSelected(track)
    reaper.InsertMedia(wav_path, 0)
    reaper.SelectAllMediaItems(0, false)
    for _, item in ipairs(selected_items) do
        reaper.SetMediaItemSelected(item, true)
    end
    reaper.SetEditCurPos(orig_pos, false, false)
end

--------------------------------------------------------------------------------
-- メイン処理
--------------------------------------------------------------------------------

local function main()
    log("=== VOICEVOX歌唱合成 ===")

    -- MIDIアイテム取得
    local item = reaper.GetSelectedMediaItem(0, 0)
    if not item then
        log("エラー: MIDIアイテムを選択してください")
        return
    end

    local take = reaper.GetActiveTake(item)
    if not take then
        log("エラー: アクティブテイクがありません")
        return
    end

    -- アイテム名から歌詞取得
    local _, item_name = reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
    if item_name == "" then
        log("エラー: アイテム名（歌詞）が空です")
        return
    end

    -- プロジェクト情報取得
    local bpm, ppq_per_qn = get_project_info(take)
    log(string.format("BPM: %.1f, PPQ/QN: %.0f", bpm, ppq_per_qn))

    -- MIDIノート取得
    local notes = get_midi_notes(take)
    local is_sing = #notes > 0

    if is_sing then
        -- 歌唱モード
        local lyrics = split_lyrics(item_name)
        log(string.format("ノート数: %d, 歌詞: %s", #notes, table.concat(lyrics, "")))

        local json_body = build_notes_json(notes, lyrics, bpm, ppq_per_qn)
        log("送信JSON: " .. json_body)

        log("歌唱クエリ生成中...")
        if not call_voicevox_query(json_body) then
            log("エラー: 歌唱クエリ生成に失敗しました")
            return
        end

        log("WAV生成中...")
        call_voicevox_synthesis(FILES.output)
    else
        -- トークモード
        log("トークモード: " .. item_name)
        if not call_voicevox_talk(item_name, FILES.output) then
            log("エラー: トーク生成に失敗しました")
            return
        end
    end

    -- REAPERに挿入
    log("REAPERに挿入...")
    local item_start = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local item_track = reaper.GetMediaItem_Track(item)
    local target_track = get_target_track(item_track)

    -- 選択中のアイテムを保存
    local selected_items = {}
    for i = 0, reaper.CountSelectedMediaItems(0) - 1 do
        table.insert(selected_items, reaper.GetSelectedMediaItem(0, i))
    end

    insert_wav(FILES.output, item_start, target_track, is_sing, selected_items)

    log("完了！")
end

main()
