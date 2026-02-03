-- 再生位置のエンプティーアイテムのノートをトラック名に設定する
-- 「字幕」という名前の FX が挿入されているトラックを監視（複数対応）
-- 再度実行で停止（トグル動作）

local FX_NAME = "字幕"
local last_notes = {}  -- トラックGUIDをキーにしたノートのキャッシュ

-- トグルアクションとして登録（再実行で自動終了）
reaper.set_action_options(1)

--------------------------------------------------------------------------------
-- トラック検索
--------------------------------------------------------------------------------

local function find_subtitle_tracks()
    local tracks = {}
    local track_count = reaper.CountTracks(0)

    for i = 0, track_count - 1 do
        local track = reaper.GetTrack(0, i)
        local fx_count = reaper.TrackFX_GetCount(track)

        for fx = 0, fx_count - 1 do
            local _, fx_name = reaper.TrackFX_GetFXName(track, fx, "")
            if fx_name:find(FX_NAME, 1, true) then
                table.insert(tracks, track)
                break
            end
        end
    end

    return tracks
end

--------------------------------------------------------------------------------
-- エンプティアイテム検索
--------------------------------------------------------------------------------

local function is_empty_item(item)
    return reaper.CountTakes(item) == 0
end

local function get_empty_item_at_position(track, position)
    local item_count = reaper.CountTrackMediaItems(track)

    for i = 0, item_count - 1 do
        local item = reaper.GetTrackMediaItem(track, i)

        if is_empty_item(item) then
            local item_start = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
            local item_length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
            local item_end = item_start + item_length

            if position >= item_start and position < item_end then
                return item
            end
        end
    end

    return nil
end

--------------------------------------------------------------------------------
-- メインループ
--------------------------------------------------------------------------------

local function update_subtitle()
    local tracks = find_subtitle_tracks()

    local play_state = reaper.GetPlayState()
    local position

    if play_state & 1 == 1 then  -- 再生中
        position = reaper.GetPlayPosition()
    else
        position = reaper.GetCursorPosition()
    end

    for _, track in ipairs(tracks) do
        local guid = reaper.GetTrackGUID(track)
        local item = get_empty_item_at_position(track, position)
        local note = ""

        if item then
            _, note = reaper.GetSetMediaItemInfo_String(item, "P_NOTES", "", false)
        end

        -- ノートが変わった場合のみトラック名を更新
        if note ~= last_notes[guid] then
            reaper.GetSetMediaTrackInfo_String(track, "P_NAME", note, true)
            last_notes[guid] = note
        end
    end

    reaper.defer(update_subtitle)
end

--------------------------------------------------------------------------------
-- 起動
--------------------------------------------------------------------------------

local tracks = find_subtitle_tracks()
if #tracks == 0 then
    reaper.ShowConsoleMsg("エラー: 「字幕」FX が見つかりません\n")
    return
end

reaper.defer(update_subtitle)
