--[[
   口パク画像貼り付け
   クリップ名を歌詞として使う。
   VOICEVOX の API で歌唱時の発音とタイミングを取得する。
   対応した口画像をタイムラインに貼り付ける。
]]

--------------------------------------------------------------------------------
-- 設定
--------------------------------------------------------------------------------

local CONFIG = {
    VOICEVOX_URL = "http://localhost:50021",
    VOICEVOX_EXE = "C:\\Program Files\\VOICEVOX\\VOICEVOX.exe",
    QUERY_SPEAKER = 6000,       -- 波音リツ（歌唱クエリ生成用・固定）
    FRAME_RATE = 93.75,         -- 24000Hz / 256サンプル
    TEMP_DIR = "C:\\tmp\\",
    REST_FRAMES = 10,           -- 前後の休符フレーム数

    -- 口画像設定
    MOUTH_DIR = "C:\\Users\\ancient\\Pictures\\素材\\中国うさぎ立ち絵素材2.0\\中国うさぎ立ち絵素材2.0\\!口\\",
}

-- phoneme → 口画像ファイル名のマッピング
local MOUTH_MAP = {
    -- 母音
    a = "_おあー.png",
    i = "_へひひ.png",      -- 横に開く
    u = "_お.png",        -- 唇をすぼめる
    e = "_えあー.png",
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
-- ユーティリティ
--------------------------------------------------------------------------------

local log_buffer = {}

local function log(msg)
    table.insert(log_buffer, msg)
end

local function show_log()
    reaper.ShowConsoleMsg(table.concat(log_buffer, "\n") .. "\n")
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

--------------------------------------------------------------------------------
-- MIDI処理
--------------------------------------------------------------------------------

local function get_project_info(take)
    local bpm = reaper.Master_GetTempo()
    local ppq_at_0 = reaper.MIDI_GetPPQPosFromProjQN(take, 0)
    local ppq_at_1 = reaper.MIDI_GetPPQPosFromProjQN(take, 1)
    return bpm, ppq_at_1 - ppq_at_0
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

local function ppq_to_seconds(ppq, bpm, ppq_per_qn)
    return ppq / ppq_per_qn * (60 / bpm)
end

local function seconds_to_frames(seconds)
    return math.max(math.floor(seconds * CONFIG.FRAME_RATE + 0.5), 1)
end

local function frames_to_seconds(frames)
    return frames / CONFIG.FRAME_RATE
end

--------------------------------------------------------------------------------
-- JSON生成（voicevox.luaと同じ形式）
--------------------------------------------------------------------------------

local function build_sing_query_json(notes, lyrics, bpm, ppq_per_qn)
    local parts = {}

    -- 開始休符
    table.insert(parts, string.format(
        '{"id":"rest_start","key":null,"frame_length":%d,"lyric":""}',
        CONFIG.REST_FRAMES
    ))

    local base_ppq = notes[1].startppq
    local prev_frame = 0

    for i, note in ipairs(notes) do
        local note_start_sec = ppq_to_seconds(note.startppq - base_ppq, bpm, ppq_per_qn)
        local note_start_frame = seconds_to_frames(note_start_sec)
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

        local note_end_sec = ppq_to_seconds(note.endppq - base_ppq, bpm, ppq_per_qn)
        local note_end_frame = seconds_to_frames(note_end_sec)
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
        CONFIG.REST_FRAMES
    ))

    return '{"notes":[' .. table.concat(parts, ",") .. ']}'
end

--------------------------------------------------------------------------------
-- JSONパース（phoneme配列の抽出）
--------------------------------------------------------------------------------

local function parse_phonemes(json)
    local phonemes = {}

    -- "phonemes":[...]の部分を抽出
    local phonemes_start = json:find('"phonemes"%s*:%s*%[')
    if not phonemes_start then return {} end

    -- phonemes配列の終端を見つける
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

                -- 各phonemeオブジェクトを抽出
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
-- VOICEVOX 起動確認
--------------------------------------------------------------------------------

local function is_voicevox_running()
    local check_file = CONFIG.TEMP_DIR .. "voicevox_check.txt"
    -- 古いキャッシュを削除
    os.remove(check_file)

    local cmd = string.format(
        'curl.exe -s --max-time 2 "%s/version" -o "%s"',
        CONFIG.VOICEVOX_URL, check_file
    )
    reaper.ExecProcess(cmd, 5000)
    local content = read_file(check_file)
    return content and content:match('^"[%d%.]+') ~= nil
end

local function ensure_voicevox_running()
    if is_voicevox_running() then
        return true
    end

    log("VOICEVOXを起動中...")
    os.execute('start "" "' .. CONFIG.VOICEVOX_EXE .. '"')

    for i = 1, 30 do
        reaper.defer(function() end)
        os.execute("ping -n 2 127.0.0.1 > nul")
        if is_voicevox_running() then
            log("VOICEVOX起動完了")
            return true
        end
    end

    log("エラー: VOICEVOXの起動に失敗しました")
    return false
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

local function get_selected_items()
    local items = {}
    for i = 0, reaper.CountSelectedMediaItems(0) - 1 do
        table.insert(items, reaper.GetSelectedMediaItem(0, i))
    end
    return items
end

local function get_or_create_mouth_track()
    local track_name = "!口"

    -- 既存のトラックを検索
    for i = 0, reaper.CountTracks(0) - 1 do
        local track = reaper.GetTrack(0, i)
        local _, name = reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
        if name == track_name then
            return track
        end
    end

    -- なければ最後に新規作成
    local track_count = reaper.CountTracks(0)
    reaper.InsertTrackAtIndex(track_count, true)
    local new_track = reaper.GetTrack(0, track_count)
    reaper.GetSetMediaTrackInfo_String(new_track, "P_NAME", track_name, true)

    return new_track
end

local function delete_items_in_range(track, start_time, end_time)
    -- 範囲内のアイテムを削除（逆順で削除）
    for i = reaper.CountTrackMediaItems(track) - 1, 0, -1 do
        local item = reaper.GetTrackMediaItem(track, i)
        local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
        local item_end = item_pos + reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
        -- アイテムが範囲と重なっていれば削除
        if item_pos < end_time and item_end > start_time then
            reaper.DeleteTrackMediaItem(track, item)
        end
    end
end

local function insert_mouth_image(image_path, position, duration, track)
    local orig_cursor = reaper.GetCursorPosition()

    reaper.SetEditCurPos(position, false, false)
    reaper.SetOnlyTrackSelected(track)

    -- ピークダイアログを一時的に無効化
    local orig_showpeaks = reaper.SNM_GetIntConfigVar("showpeaksbuild", 1)
    reaper.SNM_SetIntConfigVar("showpeaksbuild", 0)

    reaper.InsertMedia(image_path, 0)

    -- 設定を復元
    reaper.SNM_SetIntConfigVar("showpeaksbuild", orig_showpeaks)

    -- 挿入されたアイテムの長さを調整
    local item = reaper.GetTrackMediaItem(track, reaper.CountTrackMediaItems(track) - 1)
    if item then
        reaper.SetMediaItemInfo_Value(item, "D_LENGTH", duration)
    end

    reaper.SetEditCurPos(orig_cursor, false, false)

    return item
end

local function get_mouth_image(phoneme)
    local filename = MOUTH_MAP[phoneme] or MOUTH_MAP.default
    return CONFIG.MOUTH_DIR .. filename
end

--------------------------------------------------------------------------------
-- メイン処理
--------------------------------------------------------------------------------

local function main()
    log("=== 口パク画像貼り付け ===")

    -- VOICEVOX起動確認
    if not ensure_voicevox_running() then
        return false
    end

    -- MIDIアイテム取得
    local item = reaper.GetSelectedMediaItem(0, 0)
    if not item then
        log("エラー: MIDIアイテムを選択してください")
        return false
    end

    local take = reaper.GetActiveTake(item)
    if not take then
        log("エラー: アクティブテイクがありません")
        return false
    end

    local _, item_name = reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
    if item_name == "" then
        log("エラー: アイテム名（歌詞）が空です")
        return false
    end

    -- MIDI情報取得
    local bpm, ppq_per_qn = get_project_info(take)
    local notes = get_midi_notes(take)

    if #notes == 0 then
        log("エラー: MIDIノートがありません")
        return false
    end

    local lyrics = split_lyrics(item_name)
    log(string.format("BPM: %.1f, ノート数: %d, 歌詞: %s", bpm, #notes, table.concat(lyrics, "")))

    -- クエリJSON生成
    local query_json = build_sing_query_json(notes, lyrics, bpm, ppq_per_qn)
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

    -- 開始位置（最初のノートの位置）
    local start_time = reaper.MIDI_GetProjTimeFromPPQPos(take, notes[1].startppq)
    -- REST_FRAMESの分を引く
    start_time = start_time - frames_to_seconds(CONFIG.REST_FRAMES)

    -- 終了位置を計算（phonemesの合計時間）
    local total_frames = 0
    for _, p in ipairs(phonemes) do
        total_frames = total_frames + p.frame_length
    end
    local end_time = start_time + frames_to_seconds(total_frames)

    -- 口パクトラック取得
    local video_track = get_or_create_mouth_track()

    -- 選択状態を保存
    local selected_items = get_selected_items()

    -- Undo開始
    reaper.Undo_BeginBlock()

    -- 既存の口パク画像を削除
    delete_items_in_range(video_track, start_time, end_time)

    -- 口画像を配置
    local current_time = start_time
    local prev_phoneme = nil
    local prev_item = nil

    for i, p in ipairs(phonemes) do
        local duration = frames_to_seconds(p.frame_length)

        -- 子音の場合は次の母音の口形状を使う
        local effective_phoneme = p.phoneme
        if not VOWELS[p.phoneme] and p.phoneme ~= "pau" and p.phoneme ~= "cl" then
            -- 次のphonemeを探して母音なら使う
            for j = i + 1, #phonemes do
                if VOWELS[phonemes[j].phoneme] then
                    effective_phoneme = phonemes[j].phoneme
                    break
                elseif phonemes[j].phoneme == "pau" or phonemes[j].phoneme == "cl" then
                    break  -- 休符に到達したら停止
                end
            end
        end

        -- 同じ口形状が連続する場合は結合
        local mouth_file = get_mouth_image(effective_phoneme)
        local prev_mouth_file = prev_phoneme and get_mouth_image(prev_phoneme) or nil

        if prev_item and mouth_file == prev_mouth_file then
            -- 前のアイテムを延長
            local prev_duration = reaper.GetMediaItemInfo_Value(prev_item, "D_LENGTH")
            reaper.SetMediaItemInfo_Value(prev_item, "D_LENGTH", prev_duration + duration)
        else
            -- 新しいアイテムを挿入
            prev_item = insert_mouth_image(mouth_file, current_time, duration, video_track)
        end

        prev_phoneme = effective_phoneme
        current_time = current_time + duration
    end

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
