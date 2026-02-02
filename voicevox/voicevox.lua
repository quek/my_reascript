--[[
  VOICEVOX 歌唱/トーク合成スクリプト for REAPER
  - 歌唱モード: MIDIノート + 歌詞 → 歌声生成
  - トークモード: テキスト → 音声生成
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

--------------------------------------------------------------------------------
-- ファイルパス
--------------------------------------------------------------------------------

local FILES = {
    query = CONFIG.TEMP_DIR .. "sing_query.json",
    response = CONFIG.TEMP_DIR .. "sing_response.json",
    modified = CONFIG.TEMP_DIR .. "sing_modified.json",
    list = CONFIG.TEMP_DIR .. "voicevox_list.json",
    last_singer = CONFIG.TEMP_DIR .. "voicevox_last_singer.txt",
    last_speaker = CONFIG.TEMP_DIR .. "voicevox_last_speaker.txt",
}

-- 外部から設定可能なフラグ（voicevox_select.lua用）
VOICEVOX_FORCE_SELECT = VOICEVOX_FORCE_SELECT or false

--------------------------------------------------------------------------------
-- キャラクター選択
--------------------------------------------------------------------------------

local function fetch_character_list(endpoint)
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
    local pos = 1

    while true do
        local name_start = json:find('"name":', pos)
        if not name_start then break end

        local char_name = json:match('"name":"([^"]+)"', name_start)
        if not char_name then break end

        local styles_start = json:find('"styles":%s*%[', name_start)
        if not styles_start then break end

        local styles_end = json:find('%]', styles_start)
        if not styles_end then break end

        local styles_json = json:sub(styles_start, styles_end)
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

local function show_menu(items)
    gfx.init("", 0, 0)
    local choice = gfx.showmenu(table.concat(items, "|"))
    gfx.quit()
    return choice
end

local function select_character(characters, title, last_file, force_select)
    if #characters == 0 then
        log("エラー: キャラクターが見つかりません")
        return nil, nil, nil
    end

    -- 前回選択を使用（強制選択でない場合）
    if not force_select then
        local content = read_file(last_file)
        local last_id = content and tonumber(content)
        if last_id then
            local char_name, style_name = find_character_by_id(characters, last_id)
            if char_name then
                log(string.format("%s: %s - %s (ID: %d)", title, char_name, style_name, last_id))
                return last_id, char_name, style_name
            end
        end
    end

    -- キャラクター選択
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

    -- スタイル選択（複数ある場合のみ）
    local style
    if #char.styles == 1 then
        style = char.styles[1]
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
        style = char.styles[style_choice]
    end

    log(string.format("スタイル: %s (ID: %d)", style.name, style.id))

    -- 選択を保存
    write_file(last_file, tostring(style.id))

    return style.id, char.name, style.name
end

--------------------------------------------------------------------------------
-- VOICEVOX API
--------------------------------------------------------------------------------

local function modify_sample_rate(content)
    return content:gsub(
        '"outputSamplingRate":%s*%d+',
        '"outputSamplingRate":' .. CONFIG.OUTPUT_SAMPLE_RATE
    )
end

local function voicevox_sing_query(json_body)
    write_file(FILES.query, json_body)

    local cmd = string.format(
        'curl.exe -s -X POST "%s/sing_frame_audio_query?speaker=%d" -H "Content-Type: application/json" --data-binary "@%s" -o "%s"',
        CONFIG.VOICEVOX_URL, CONFIG.QUERY_SPEAKER, FILES.query, FILES.response
    )
    reaper.ExecProcess(cmd, 30000)

    local content = read_file(FILES.response)
    if not content or content:find('"detail"') then
        return false
    end

    write_file(FILES.modified, modify_sample_rate(content))
    return true
end

local function voicevox_sing_synthesis(output_path, speaker_id)
    local cmd = string.format(
        'curl.exe -s -X POST "%s/frame_synthesis?speaker=%d" -H "Content-Type: application/json" --data-binary "@%s" -o "%s"',
        CONFIG.VOICEVOX_URL, speaker_id, FILES.modified, output_path
    )
    reaper.ExecProcess(cmd, 60000)
    return true
end

local function voicevox_talk(text, output_path, speaker_id)
    -- audio_query
    local cmd = string.format(
        'curl.exe -s -X POST "%s/audio_query?speaker=%d&text=%s" -o "%s"',
        CONFIG.VOICEVOX_URL, speaker_id, url_encode(text), FILES.response
    )
    reaper.ExecProcess(cmd, 30000)

    local content = read_file(FILES.response)
    if not content or content:find('"detail"') then
        return false
    end

    write_file(FILES.modified, modify_sample_rate(content))

    -- synthesis
    cmd = string.format(
        'curl.exe -s -X POST "%s/synthesis?speaker=%d" -H "Content-Type: application/json" --data-binary "@%s" -o "%s"',
        CONFIG.VOICEVOX_URL, speaker_id, FILES.modified, output_path
    )
    reaper.ExecProcess(cmd, 60000)
    return true
end

--------------------------------------------------------------------------------
-- REAPER操作
--------------------------------------------------------------------------------

local function get_target_track(source_track)
    local track_idx = reaper.GetMediaTrackInfo_Value(source_track, "IP_TRACKNUMBER")
    local target = reaper.GetTrack(0, track_idx)

    if not target then
        reaper.InsertTrackAtIndex(track_idx, true)
        target = reaper.GetTrack(0, track_idx)
    end

    return target
end

local function delete_item_at_position(track, position)
    local tolerance = 0.001
    for i = reaper.CountTrackMediaItems(track) - 1, 0, -1 do
        local item = reaper.GetTrackMediaItem(track, i)
        local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
        if math.abs(item_pos - position) < tolerance then
            reaper.DeleteTrackMediaItem(track, item)
        end
    end
end

local function insert_wav(wav_path, position, track, apply_offset, restore_items)
    local orig_cursor = reaper.GetCursorPosition()
    local insert_pos = apply_offset and position - frames_to_seconds(CONFIG.REST_FRAMES) or position

    delete_item_at_position(track, insert_pos)
    reaper.SetEditCurPos(insert_pos, false, false)
    reaper.SetOnlyTrackSelected(track)

    -- ピークダイアログを一時的に無効化
    local orig_showpeaks = reaper.SNM_GetIntConfigVar("showpeaksbuild", 1)
    reaper.SNM_SetIntConfigVar("showpeaksbuild", 0)

    reaper.InsertMedia(wav_path, 0)

    -- 設定を復元
    reaper.SNM_SetIntConfigVar("showpeaksbuild", orig_showpeaks)

    -- 選択状態を復元
    reaper.SelectAllMediaItems(0, false)
    for _, item in ipairs(restore_items) do
        reaper.SetMediaItemSelected(item, true)
    end
    reaper.SetEditCurPos(orig_cursor, false, false)
end

--------------------------------------------------------------------------------
-- 歌唱モード処理
--------------------------------------------------------------------------------

local function process_sing_mode(take, item_name, bpm, ppq_per_qn, notes)
    local lyrics = common.split_lyrics(item_name)
    log(string.format("ノート数: %d, 歌詞: %s", #notes, table.concat(lyrics, "")))

    -- シンガー選択
    log("シンガー一覧を取得中...")
    local json = fetch_character_list("singers")
    local singers = parse_characters(json)
    local speaker_id, char_name, style_name = select_character(
        singers, "シンガー", FILES.last_singer, VOICEVOX_FORCE_SELECT
    )
    if not speaker_id then return nil end

    local output_path = string.format("%s%s_%s.wav", CONFIG.TEMP_DIR, char_name, style_name)

    -- クエリ生成
    local query_json = common.build_sing_query_json(notes, lyrics, bpm, ppq_per_qn)
    log("送信JSON: " .. query_json)

    log("歌唱クエリ生成中...")
    if not voicevox_sing_query(query_json) then
        log("エラー: 歌唱クエリ生成に失敗しました")
        return false
    end

    -- 合成
    log("WAV生成中...")
    voicevox_sing_synthesis(output_path, speaker_id)

    return output_path
end

--------------------------------------------------------------------------------
-- トークモード処理
--------------------------------------------------------------------------------

local function process_talk_mode(item_name)
    log("トークモード: " .. item_name)

    -- スピーカー選択
    log("スピーカー一覧を取得中...")
    local json = fetch_character_list("speakers")
    local speakers = parse_characters(json)
    local speaker_id, char_name, style_name = select_character(
        speakers, "スピーカー", FILES.last_speaker, VOICEVOX_FORCE_SELECT
    )
    if not speaker_id then return nil end

    local output_path = string.format("%svoicevox_%s_%s.wav", CONFIG.TEMP_DIR, char_name, style_name)

    -- 合成
    if not voicevox_talk(item_name, output_path, speaker_id) then
        log("エラー: トーク生成に失敗しました")
        return false
    end

    return output_path
end

--------------------------------------------------------------------------------
-- メイン処理
--------------------------------------------------------------------------------

local function main()
    common.clear_log()
    log("=== VOICEVOX合成 ===")

    -- VOICEVOX起動確認
    if not common.ensure_voicevox_running() then
        return false
    end

    -- MIDIアイテム取得
    local item, take, item_name = common.get_selected_midi_item()
    if not item then return false end

    -- モード判定と処理
    local bpm, ppq_per_qn = common.get_project_info(take)
    local notes = common.get_midi_notes(take)
    local is_sing = #notes > 0

    log(string.format("BPM: %.1f, モード: %s", bpm, is_sing and "歌唱" or "トーク"))

    local output_path
    if is_sing then
        output_path = process_sing_mode(take, item_name, bpm, ppq_per_qn, notes)
    else
        output_path = process_talk_mode(item_name)
    end

    -- キャンセルまたはエラー
    if output_path == nil then return end
    if output_path == false then return false end

    -- REAPERに挿入
    log("REAPERに挿入...")
    local item_start = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local item_track = reaper.GetMediaItem_Track(item)
    local target_track = get_target_track(item_track)
    local selected_items = common.get_selected_items()

    local insert_pos = item_start
    if is_sing and #notes > 0 then
        insert_pos = reaper.MIDI_GetProjTimeFromPPQPos(take, notes[1].startppq)
    end

    insert_wav(output_path, insert_pos, target_track, is_sing, selected_items)

    log("完了！")
    return true
end

-- 実行（エラー時のみログ表示）
if main() == false then
    show_log()
end
