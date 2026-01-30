--[[
  ループ中であれば解除、そうでなければ選択アイテムをループ再生
  ただしループ中でも選択範囲が現在のループ範囲と異なる場合は再ループ
]]

local function get_selected_items_range()
    local count = reaper.CountSelectedMediaItems(0)
    if count == 0 then return nil, nil end

    local start_min, end_max = math.huge, -math.huge
    for i = 0, count - 1 do
        local item = reaper.GetSelectedMediaItem(0, i)
        local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
        local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
        start_min = math.min(start_min, pos)
        end_max = math.max(end_max, pos + len)
    end
    return start_min, end_max
end

local function loop_selected_items()
    local cmd_id = reaper.NamedCommandLookup("_XENAKIOS_LOOPANDPLAYSELITEMS")
    if cmd_id ~= 0 then
        reaper.Main_OnCommand(cmd_id, 0)
    else
        reaper.ShowMessageBox("SWS Extension が必要です", "エラー", 0)
    end
end

local function main()
    local repeat_state = reaper.GetSetRepeat(-1)

    if repeat_state == 1 then
        local sel_start, sel_end = get_selected_items_range()
        local loop_start, loop_end = reaper.GetSet_LoopTimeRange(false, true, 0, 0, false)

        -- 選択範囲がループ範囲と異なる場合は再ループ
        if sel_start and (math.abs(sel_start - loop_start) > 0.0001 or math.abs(sel_end - loop_end) > 0.0001) then
            loop_selected_items()
        else
            -- ループ解除
            reaper.GetSetRepeat(0)
        end
    else
        loop_selected_items()
    end
end

main()
