-- jsfx-server.lua — REAPER background script for jsfx-mode
--
-- Auto-reloads JSFX when source files change on disk.
-- Scans all tracks for loaded JSFX, watches their files, and
-- reloads (offline/online toggle) when content changes.
--
-- Install:
--   1. Actions > Show action list > New action > Load ReaScript...
--   2. Select this script and run it (re-run to stop)
--   3. (Optional) Add to SWS Startup Actions for auto-start

local _, _, sectionID, cmdID = reaper.get_action_context()

-- Toggle action (re-run to stop)
reaper.set_action_options(1)

reaper.SetToggleCommandState(sectionID, cmdID, 1)
reaper.RefreshToolbar2(sectionID, cmdID)
reaper.atexit(function()
  reaper.SetToggleCommandState(sectionID, cmdID, 0)
  reaper.RefreshToolbar2(sectionID, cmdID)
end)

----------------------------------------------------------------
-- File watching — auto-reload JSFX on file change
----------------------------------------------------------------

local effects_dir = reaper.GetResourcePath() .. "/Effects/"
local watched = {}          -- path -> content hash
local loaded_jsfx = nil     -- path -> { {track, fx}, ... }
local last_scan = 0
local last_check = 0
local SCAN_INTERVAL = 2     -- rebuild watch list (seconds)
local CHECK_INTERVAL = 1    -- check file content (seconds)

local function resolve_path(rel)
  rel = rel:gsub("\\", "/")
  for _, path in ipairs({
    effects_dir .. rel,
    effects_dir .. rel .. ".jsfx",
  }) do
    if reaper.file_exists(path) then return path end
  end
end

local function file_hash(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  -- FNV-1a inspired hash
  local h = 2166136261
  for i = 1, #content do
    h = ((h ~ content:byte(i)) * 16777619) % 4294967296
  end
  return h
end

local function scan_loaded_jsfx()
  local result = {}
  local function scan(track)
    for fx = 0, reaper.TrackFX_GetCount(track) - 1 do
      local _, name = reaper.TrackFX_GetFXName(track, fx, "")
      if name and name:sub(1, 3) == "JS:" then
        local ok, ident = reaper.TrackFX_GetNamedConfigParm(track, fx, "fx_ident")
        if ok then
          local path = resolve_path(ident)
          if path then
            if not result[path] then result[path] = {} end
            result[path][#result[path] + 1] = { track = track, fx = fx }
          end
        end
      end
    end
  end
  for t = 0, reaper.CountTracks(0) - 1 do
    scan(reaper.GetTrack(0, t))
  end
  scan(reaper.GetMasterTrack(0))
  return result
end

local function check_file_changes()
  if not loaded_jsfx then return end
  for path, fxlist in pairs(loaded_jsfx) do
    local h = file_hash(path)
    if h then
      if watched[path] == nil then
        watched[path] = h
      elseif watched[path] ~= h then
        watched[path] = h
        for _, info in ipairs(fxlist) do
          reaper.TrackFX_SetOffline(info.track, info.fx, true)
          reaper.TrackFX_SetOffline(info.track, info.fx, false)
        end
      end
    end
  end
  -- Clean up unloaded FX
  for path in pairs(watched) do
    if not loaded_jsfx[path] then watched[path] = nil end
  end
end

----------------------------------------------------------------
-- Main loop
----------------------------------------------------------------

local function main()
  local now = reaper.time_precise()

  -- Scan loaded JSFX
  if now - last_scan >= SCAN_INTERVAL then
    last_scan = now
    loaded_jsfx = scan_loaded_jsfx()
  end

  -- Check for file changes
  if now - last_check >= CHECK_INTERVAL then
    last_check = now
    check_file_changes()
  end

  reaper.defer(main)
end

main()
