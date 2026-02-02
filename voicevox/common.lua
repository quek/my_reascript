--[[
  VOICEVOX 共通ライブラリ for REAPER
  voicevox.lua, pakupaku.lua から共有される関数・設定
]]

local M = {}

--------------------------------------------------------------------------------
-- 設定
--------------------------------------------------------------------------------

M.CONFIG = {
    VOICEVOX_URL = "http://localhost:50021",
    VOICEVOX_EXE = "C:\\Program Files\\VOICEVOX\\VOICEVOX.exe",
    QUERY_SPEAKER = 6000,       -- 波音リツ（歌唱クエリ生成用・固定）
    FRAME_RATE = 93.75,         -- 24000Hz / 256サンプル
    OUTPUT_SAMPLE_RATE = 48000,
    TEMP_DIR = "C:\\tmp\\",
    REST_FRAMES = 10,           -- 前後の休符フレーム数
}

--------------------------------------------------------------------------------
-- ロギング
--------------------------------------------------------------------------------

M.log_buffer = {}

function M.log(msg)
    table.insert(M.log_buffer, msg)
end

function M.show_log()
    reaper.ShowConsoleMsg(table.concat(M.log_buffer, "\n") .. "\n")
end

function M.clear_log()
    M.log_buffer = {}
end

--------------------------------------------------------------------------------
-- ファイル操作
--------------------------------------------------------------------------------

function M.read_file(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    return content
end

function M.write_file(path, content)
    local f = io.open(path, "w")
    if not f then return false end
    f:write(content)
    f:close()
    return true
end

--------------------------------------------------------------------------------
-- URL エンコード
--------------------------------------------------------------------------------

function M.url_encode(str)
    return str:gsub("([^%w%-_%.~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
end

--------------------------------------------------------------------------------
-- MIDI処理
--------------------------------------------------------------------------------

function M.get_project_info(take)
    local bpm = reaper.Master_GetTempo()
    local ppq_at_0 = reaper.MIDI_GetPPQPosFromProjQN(take, 0)
    local ppq_at_1 = reaper.MIDI_GetPPQPosFromProjQN(take, 1)
    return bpm, ppq_at_1 - ppq_at_0
end

function M.get_midi_notes(take)
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

function M.split_lyrics(text)
    local small_kana = "ぁぃぅぇぉゃゅょっァィゥェォャュョッ"
    local lyrics = {}

    for char in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        if char == " " or char == "　" then
            -- skip spaces
        elseif #lyrics > 0 and small_kana:find(char, 1, true) then
            lyrics[#lyrics] = lyrics[#lyrics] .. char
        else
            table.insert(lyrics, char)
        end
    end

    return lyrics
end

--------------------------------------------------------------------------------
-- フレーム・時間変換
--------------------------------------------------------------------------------

function M.ppq_to_seconds(ppq, bpm, ppq_per_qn)
    return ppq / ppq_per_qn * (60 / bpm)
end

function M.seconds_to_frames(seconds)
    return math.max(math.floor(seconds * M.CONFIG.FRAME_RATE + 0.5), 1)
end

function M.frames_to_seconds(frames)
    return frames / M.CONFIG.FRAME_RATE
end

--------------------------------------------------------------------------------
-- JSON生成
--------------------------------------------------------------------------------

function M.build_sing_query_json(notes, lyrics, bpm, ppq_per_qn)
    local parts = {}

    -- 開始休符
    table.insert(parts, string.format(
        '{"id":"rest_start","key":null,"frame_length":%d,"lyric":""}',
        M.CONFIG.REST_FRAMES
    ))

    local base_ppq = notes[1].startppq
    local prev_frame = 0

    for i, note in ipairs(notes) do
        local note_start_sec = M.ppq_to_seconds(note.startppq - base_ppq, bpm, ppq_per_qn)
        local note_start_frame = M.seconds_to_frames(note_start_sec)
        if i == 1 then note_start_frame = 0 end

        if i > 1 then
            local gap_frames = note_start_frame - prev_frame
            if gap_frames > 0 then
                table.insert(parts, string.format(
                    '{"id":"rest%d","key":null,"frame_length":%d,"lyric":""}',
                    i, gap_frames
                ))
            end
        end

        local note_end_sec = M.ppq_to_seconds(note.endppq - base_ppq, bpm, ppq_per_qn)
        local note_end_frame = M.seconds_to_frames(note_end_sec)
        local note_frames = math.max(note_end_frame - note_start_frame, 1)

        table.insert(parts, string.format(
            '{"id":"note%d","key":%d,"frame_length":%d,"lyric":"%s"}',
            i, note.pitch, note_frames, lyrics[i] or "ら"
        ))

        prev_frame = note_end_frame
    end

    -- 終了休符
    table.insert(parts, string.format(
        '{"id":"rest_end","key":null,"frame_length":%d,"lyric":""}',
        M.CONFIG.REST_FRAMES
    ))

    return '{"notes":[' .. table.concat(parts, ",") .. ']}'
end

--------------------------------------------------------------------------------
-- VOICEVOX 起動確認
--------------------------------------------------------------------------------

function M.is_voicevox_running()
    local check_file = M.CONFIG.TEMP_DIR .. "voicevox_check.txt"
    os.remove(check_file)

    local cmd = string.format(
        'curl.exe -s --max-time 2 "%s/version" -o "%s"',
        M.CONFIG.VOICEVOX_URL, check_file
    )
    reaper.ExecProcess(cmd, 5000)
    local content = M.read_file(check_file)
    return content and content:match('^"[%d%.]+') ~= nil
end

function M.ensure_voicevox_running()
    if M.is_voicevox_running() then
        return true
    end

    M.log("VOICEVOXを起動中...")
    os.execute('start "" "' .. M.CONFIG.VOICEVOX_EXE .. '"')

    for i = 1, 30 do
        reaper.defer(function() end)
        os.execute("ping -n 2 127.0.0.1 > nul")
        if M.is_voicevox_running() then
            M.log("VOICEVOX起動完了")
            return true
        end
    end

    M.log("エラー: VOICEVOXの起動に失敗しました")
    return false
end

--------------------------------------------------------------------------------
-- REAPER操作
--------------------------------------------------------------------------------

function M.get_selected_items()
    local items = {}
    for i = 0, reaper.CountSelectedMediaItems(0) - 1 do
        table.insert(items, reaper.GetSelectedMediaItem(0, i))
    end
    return items
end

function M.get_selected_midi_item()
    local item = reaper.GetSelectedMediaItem(0, 0)
    if not item then
        M.log("エラー: MIDIアイテムを選択してください")
        return nil, nil, nil
    end

    local take = reaper.GetActiveTake(item)
    if not take then
        M.log("エラー: アクティブテイクがありません")
        return nil, nil, nil
    end

    local _, item_name = reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
    if item_name == "" then
        M.log("エラー: アイテム名（歌詞/テキスト）が空です")
        return nil, nil, nil
    end

    return item, take, item_name
end

return M
