-- Common FX utility functions
-- Requires: SWS Extension

local M = {}

-- マウスカーソル下のトラックでFXを開く（なければ挿入）
function M.open_fx_under_mouse(fx_name)
  -- マウスカーソル位置のトラックを取得 (SWS)
  local track, context = reaper.BR_TrackAtMouseCursor()

  if not track then
    reaper.MB("マウスカーソルの下にトラックがありません。", "エラー", 0)
    return
  end

  -- トラック上のFXから対象を探す
  local fx_count = reaper.TrackFX_GetCount(track)
  local fx_idx = -1
  local search_name = fx_name:lower()

  for i = 0, fx_count - 1 do
    local _, name = reaper.TrackFX_GetFXName(track, i)
    if name:lower():find(search_name) then
      fx_idx = i
      break
    end
  end

  -- 見つからなければ挿入
  if fx_idx < 0 then
    fx_idx = reaper.TrackFX_AddByName(track, fx_name, false, -1)
    if fx_idx < 0 then
      reaper.MB(fx_name .. " の追加に失敗しました。", "エラー", 0)
      return
    end
  end

  -- FXウィンドウを開く (3 = floating window)
  reaper.TrackFX_Show(track, fx_idx, 3)
end

return M
