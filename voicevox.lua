--[[
  VOICEVOX 歌唱合成スクリプト for REAPER
  MIDIノートと歌詞から歌声を生成し、トラックに挿入する
]]

-- 設定
local CONFIG = {
    VOICEVOX_URL = "http://localhost:50021",
    QUERY_SPEAKER = 6000,   -- 波音リツ（歌唱クエリ生成用・固定）
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
    list = CONFIG.TEMP_DIR .. "voicevox_list.json",
    last_singer = CONFIG.TEMP_DIR .. "voicevox_last_singer.txt",
    last_speaker = CONFIG.TEMP_DIR .. "voicevox_last_speaker.txt",
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
-- キャラクター選択UI
--------------------------------------------------------------------------------

local function fetch_voicevox_list(endpoint)
    local cmd = string.format(
        'curl.exe -s "%s/%s" -o "%s"',
        CONFIG.VOICEVOX_URL, endpoint, FILES.list
    )
    reaper.ExecProcess(cmd, 10000)
    return read_file(FILES.list)
end

local function parse_characters(json)
    if not json then return {} end

    local characters = {}
    -- キャラクター単位でパース（"styles":[ で区切る）
    local pos = 1
    while true do
        -- 次のキャラクターブロックを探す
        local name_start = json:find('"name":', pos)
        if not name_start then break end

        -- キャラクター名を取得
        local char_name = json:match('"name":"([^"]+)"', name_start)
        if not char_name then break end

        -- stylesを探す
        local styles_start = json:find('"styles":%s*%[', name_start)
        if not styles_start then break end

        -- stylesの終わりを探す
        local styles_end = json:find('%]', styles_start)
        if not styles_end then break end

        local styles_json = json:sub(styles_start, styles_end)

        -- スタイルをパース
        local styles = {}
        for style_block in styles_json:gmatch('%{[^%}]+%}') do
            local style_name = style_block:match('"name":"([^"]+)"')
            local style_id = style_block:match('"id":(%d+)')
            if style_name and style_id then
                table.insert(styles, {name = style_name, id = tonumber(style_id)})
            end
        end

        if #styles > 0 then
            table.insert(characters, {name = char_name, styles = styles})
        end

        pos = styles_end + 1
    end

    return characters
end

local function show_menu(items)
    gfx.init("", 0, 0)
    local choice = gfx.showmenu(table.concat(items, "|"))
    gfx.quit()
    return choice
end

local function find_character_by_id(characters, id)
    for _, char in ipairs(characters) do
        for _, style in ipairs(char.styles) do
            if style.id == id then
                return char.name, style.name
            end
        end
    end
    return nil, nil
end

local function load_last_selection(file_path)
    local content = read_file(file_path)
    if content then
        return tonumber(content)
    end
    return nil
end

local function save_last_selection(file_path, id)
    write_file(file_path, tostring(id))
end

local function select_character_and_style(characters, title, last_file, force_select)
    if #characters == 0 then
        log("エラー: キャラクターが見つかりません")
        return nil, nil, nil
    end

    -- 前回選択を確認（強制選択でない場合）
    if not force_select then
        local last_id = load_last_selection(last_file)
        if last_id then
            local last_char_name, last_style_name = find_character_by_id(characters, last_id)
            if last_char_name then
                log(string.format("%s: %s - %s (ID: %d)", title, last_char_name, last_style_name, last_id))
                return last_id, last_char_name, last_style_name
            end
        end
    end

    -- キャラクター選択メニュー
    -- 1. キャラクター選択
    local char_names = {}
    for _, c in ipairs(characters) do
        table.insert(char_names, c.name)
    end

    log(title .. "を選択してください...")
    local char_choice = show_menu(char_names)
    if char_choice == 0 then
        log("キャンセルされました")
        return nil, nil, nil
    end

    local char = characters[char_choice]
    log("選択: " .. char.name)

    -- 2. スタイル選択（複数ある場合）
    local selected_id, selected_style_name
    if #char.styles == 1 then
        selected_id = char.styles[1].id
        selected_style_name = char.styles[1].name
        log("スタイル: " .. selected_style_name .. " (ID: " .. selected_id .. ")")
    else
        local style_names = {}
        for _, s in ipairs(char.styles) do
            table.insert(style_names, s.name)
        end

        log("スタイルを選択してください...")
        local style_choice = show_menu(style_names)
        if style_choice == 0 then
            log("キャンセルされました")
            return nil, nil, nil
        end

        selected_id = char.styles[style_choice].id
        selected_style_name = char.styles[style_choice].name
        log("スタイル: " .. selected_style_name .. " (ID: " .. selected_id .. ")")
    end

    -- 選択を保存
    save_last_selection(last_file, selected_id)
    return selected_id, char.name, selected_style_name
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

local function call_voicevox_query(json_body, query_speaker)
    write_file(FILES.query, json_body)

    local cmd = string.format(
        'curl.exe -s -X POST "%s/sing_frame_audio_query?speaker=%d" -H "Content-Type: application/json" --data-binary "@%s" -o "%s"',
        CONFIG.VOICEVOX_URL,
        query_speaker,
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

local function call_voicevox_synthesis(output_path, synth_speaker)
    local cmd = string.format(
        'curl.exe -s -X POST "%s/frame_synthesis?speaker=%d" -H "Content-Type: application/json" --data-binary "@%s" -o "%s"',
        CONFIG.VOICEVOX_URL,
        synth_speaker,
        FILES.modified,
        output_path
    )
    reaper.ExecProcess(cmd, 60000)
    return true
end

local function call_voicevox_talk(text, output_path, talk_speaker)
    -- audio_query
    local cmd = string.format(
        'curl.exe -s -X POST "%s/audio_query?speaker=%d&text=%s" -o "%s"',
        CONFIG.VOICEVOX_URL,
        talk_speaker,
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
        talk_speaker,
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

-- 外部から設定可能なフラグ
VOICEVOX_FORCE_SELECT = VOICEVOX_FORCE_SELECT or false

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

    local output_path
    if is_sing then
        -- 歌唱モード
        local lyrics = split_lyrics(item_name)
        log(string.format("ノート数: %d, 歌詞: %s", #notes, table.concat(lyrics, "")))

        -- シンガー選択
        log("シンガー一覧を取得中...")
        local singers_json = fetch_voicevox_list("singers")
        local singers = parse_characters(singers_json)
        local synth_speaker, singer_name, style_name = select_character_and_style(singers, "シンガー", FILES.last_singer, VOICEVOX_FORCE_SELECT)
        if not synth_speaker then return end

        output_path = string.format("%svoicevox_%s_%s.wav", CONFIG.TEMP_DIR, singer_name, style_name)

        local json_body = build_notes_json(notes, lyrics, bpm, ppq_per_qn)
        log("送信JSON: " .. json_body)

        log("歌唱クエリ生成中...")
        -- sing_frame_audio_query: 波音リツ(6000)固定
        if not call_voicevox_query(json_body, CONFIG.QUERY_SPEAKER) then
            log("エラー: 歌唱クエリ生成に失敗しました")
            return
        end

        log("WAV生成中...")
        call_voicevox_synthesis(output_path, synth_speaker)
    else
        -- トークモード
        log("トークモード: " .. item_name)

        -- スピーカー選択
        log("スピーカー一覧を取得中...")
        local speakers_json = fetch_voicevox_list("speakers")
        local speakers = parse_characters(speakers_json)
        local talk_speaker, speaker_name, style_name = select_character_and_style(speakers, "スピーカー", FILES.last_speaker, VOICEVOX_FORCE_SELECT)
        if not talk_speaker then return end

        output_path = string.format("%svoicevox_%s_%s.wav", CONFIG.TEMP_DIR, speaker_name, style_name)

        if not call_voicevox_talk(item_name, output_path, talk_speaker) then
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

    -- 歌唱モードの場合、最初のノートの位置を基準にする
    local insert_position = item_start
    if is_sing and #notes > 0 then
        insert_position = reaper.MIDI_GetProjTimeFromPPQPos(take, notes[1].startppq)
    end

    insert_wav(output_path, insert_position, target_track, is_sing, selected_items)

    log("完了！")
end

main()
