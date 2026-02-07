-- 歌詞を一括で配置するスクリプトです。
-- 選択しているアイテムのノートを1行ずつ分割。
-- 空行は無視。
-- 1行目だけ残し、他の行は1行ずつとなりのアイテムのノートに設定していく。

--------------------------------------------------------------------------------
-- 選択アイテムの確認
--------------------------------------------------------------------------------

local selected_count = reaper.CountSelectedMediaItems(0)
if selected_count == 0 then
    reaper.ShowMessageBox("アイテムを選択してください。", "歌詞アイテム", 0)
    return
end

local item = reaper.GetSelectedMediaItem(0, 0)
local track = reaper.GetMediaItemTrack(item)

-- ノートを取得
local _, notes = reaper.GetSetMediaItemInfo_String(item, "P_NOTES", "", false)
if notes == "" then
    reaper.ShowMessageBox("選択アイテムにノートがありません。", "歌詞アイテム", 0)
    return
end

--------------------------------------------------------------------------------
-- 歌詞を行に分割（空行を除外）
--------------------------------------------------------------------------------

local lines = {}
for line in notes:gmatch("[^\r\n]+") do
    if line:match("%S") then
        table.insert(lines, line)
    end
end

if #lines <= 1 then
    reaper.ShowMessageBox("分割する歌詞がありません。", "歌詞アイテム", 0)
    return
end

--------------------------------------------------------------------------------
-- トラック上のアイテムインデックスを特定
--------------------------------------------------------------------------------

local track_item_count = reaper.CountTrackMediaItems(track)
local item_index = -1
for i = 0, track_item_count - 1 do
    if reaper.GetTrackMediaItem(track, i) == item then
        item_index = i
        break
    end
end

local remaining_items = track_item_count - item_index - 1
local lines_to_distribute = #lines - 1

if remaining_items < lines_to_distribute then
    reaper.ShowMessageBox(
        "アイテムが足りません。\n歌詞: " .. #lines .. "行\n利用可能なアイテム: " .. (remaining_items + 1),
        "歌詞アイテム", 0)
    return
end

--------------------------------------------------------------------------------
-- 歌詞を分配
--------------------------------------------------------------------------------

reaper.Undo_BeginBlock()

-- 1行目を元のアイテムに設定
reaper.GetSetMediaItemInfo_String(item, "P_NOTES", lines[1], true)

-- 2行目以降を隣のアイテムに順番に設定
for i = 2, #lines do
    local next_item = reaper.GetTrackMediaItem(track, item_index + i - 1)
    reaper.GetSetMediaItemInfo_String(next_item, "P_NOTES", lines[i], true)
end

reaper.UpdateArrange()
reaper.Undo_EndBlock("歌詞を分配", -1)
