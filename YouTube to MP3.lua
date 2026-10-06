--[[
YouTube to MP3 for DaVinci Resolve
Workspace > Scripts > YouTube to MP3

Paste one or more YouTube links, convert them to MP3 (or WAV), save them to a folder,
and import them into a "YouTube Audio" bin in the Media Pool.

Uses the standalone tools that install.sh puts in ~/Library/Application Support/YTtoMP3/bin.
Only download audio you have the rights to use.
]]

local resolve = resolve or bmd.scriptapp("Resolve")
local fusion = fu or fusion or resolve:Fusion()

local HOME = os.getenv("HOME")
local APP_DIR = HOME .. "/Library/Application Support/YTtoMP3"
local BIN = APP_DIR .. "/bin"
local JOBS_DIR = APP_DIR .. "/jobs"
local SETTINGS_FILE = APP_DIR .. "/settings.txt"
local LAST_LOG = APP_DIR .. "/last-log.txt"
local DEFAULT_FOLDER = HOME .. "/Music/Resolve YouTube Audio"
local MEDIA_POOL_BIN = "YouTube Audio"
local REQUIRED_TOOLS = { "yt-dlp", "ffmpeg", "ffprobe", "deno" }

-- Everything is resampled to 48 kHz, the standard rate for video projects.
local FORMATS = {
  { label = "MP3 - 320 kbps", args = { "--audio-format", "mp3", "--audio-quality", "320K" } },
  { label = "WAV - 48 kHz, 16-bit (best for editing)", args = { "--audio-format", "wav" } },
}

------------------------------------------------------------------------------
-- Helpers

local function q(s)
  return "'" .. (tostring(s):gsub("'", [['\'']])) .. "'"
end

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function readFile(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

local function writeFile(path, s)
  local f = assert(io.open(path, "w"))
  f:write(s)
  f:close()
end

local function fileExists(path)
  local f = io.open(path, "r")
  if f then f:close() end
  return f ~= nil
end

local function mkdirp(path)
  os.execute("mkdir -p " .. q(path))
end

local function expandHome(path)
  if path:sub(1, 1) == "~" then return HOME .. path:sub(2) end
  return path
end

local function prettyPath(path)
  if path:sub(1, #HOME) == HOME then return "~" .. path:sub(#HOME + 1) end
  return path
end

local function lines(s)
  local out = {}
  for line in (s or ""):gmatch("[^\r\n]+") do out[#out + 1] = line end
  return out
end

local function missingTools()
  local missing = {}
  for _, tool in ipairs(REQUIRED_TOOLS) do
    if not fileExists(BIN .. "/" .. tool) then missing[#missing + 1] = tool end
  end
  return missing
end

-- Pull every link out of pasted text (any whitespace separates links).
local function parseUrls(text)
  local urls, seen = {}, {}
  for token in (text or ""):gmatch("%S+") do
    if not token:match("^https?://") and token:match("^[%w%.]*youtu%.?be") then
      token = "https://" .. token
    end
    if token:match("^https?://") and not seen[token] then
      seen[token] = true
      urls[#urls + 1] = token
    end
  end
  return urls
end

-- Some networks reach youtube.com over IPv6 but stall on its media servers, so use IPv4
-- whenever the Mac has it. IPv6-only networks (no IPv4 route) are left to yt-dlp's default.
local function hasIPv4Route()
  local result = os.execute("/sbin/route -n get -inet default >/dev/null 2>&1")
  return result == 0 or result == true
end

local function currentProject()
  return resolve:GetProjectManager():GetCurrentProject()
end

local function projectFolderName()
  local project = currentProject()
  local name = project and project:GetName() or "Untitled Project"
  name = trim(name:gsub("[/:]", "-"))
  return name ~= "" and name or "Untitled Project"
end

------------------------------------------------------------------------------
-- Settings (remembered between runs)

local settings = {
  folder = DEFAULT_FOLDER,
  format = 0,
  perProject = true,
  import = true,
  playlist = false,
}

local function loadSettings()
  for _, line in ipairs(lines(readFile(SETTINGS_FILE))) do
    local key, value = line:match("^(%w+)=(.*)$")
    if key == "folder" and value ~= "" then
      settings.folder = value
    elseif key == "format" then
      settings.format = math.max(0, math.min(#FORMATS - 1, tonumber(value) or 0))
    elseif key == "perProject" or key == "import" or key == "playlist" then
      settings[key] = value == "1"
    end
  end
end

local function saveSettings()
  local function b(v) return v and "1" or "0" end
  mkdirp(APP_DIR)
  writeFile(SETTINGS_FILE, table.concat({
    "folder=" .. settings.folder,
    "format=" .. settings.format,
    "perProject=" .. b(settings.perProject),
    "import=" .. b(settings.import),
    "playlist=" .. b(settings.playlist),
  }, "\n") .. "\n")
end

------------------------------------------------------------------------------
-- Media Pool

-- Imports the files into the "YouTube Audio" bin, skipping any already there.
-- Returns the number of clips added, or nil and an error message.
local function importToMediaPool(paths)
  local project = currentProject()
  if not project then return nil, "no project is open" end
  local mediaPool = project:GetMediaPool()
  local root = mediaPool:GetRootFolder()

  -- Resolve's Lua lists also carry a "__flags" key, so walk them with ipairs.
  local bin
  for _, folder in ipairs(root:GetSubFolderList() or {}) do
    if folder:GetName() == MEDIA_POOL_BIN then bin = folder break end
  end
  bin = bin or mediaPool:AddSubFolder(root, MEDIA_POOL_BIN)
  if not bin then return nil, "couldn't create the \"" .. MEDIA_POOL_BIN .. "\" bin" end

  local existing = {}
  for _, clip in ipairs(bin:GetClipList() or {}) do
    local props = clip:GetClipProperty() or {}
    if props["File Path"] then existing[props["File Path"]] = true end
  end

  local infos = {}
  for _, path in ipairs(paths) do
    if not existing[path] then infos[#infos + 1] = { media = path } end
  end
  if #infos == 0 then return 0 end

  -- Adds to the current Media Pool folder. (MediaPool:ImportMedia's {FilePath=...} form returns nil from Lua in 21.1.)
  mediaPool:SetCurrentFolder(bin)
  local added = #(resolve:GetMediaStorage():AddItemListToMediaPool(infos) or {})
  if added == 0 then return nil, "Resolve didn't accept the file(s)" end
  return added
end

------------------------------------------------------------------------------
-- UI

local ui = fusion.UIManager
local disp = bmd.UIDispatcher(ui)

local win = disp:AddWindow({
  ID = "YTtoMP3",
  WindowTitle = "YouTube to MP3",
  Geometry = { 200, 150, 660, 560 },
  ui:VGroup{
    Spacing = 8,
    ui:HGroup{
      Weight = 0,
      ui:Label{ Text = "YouTube links (one per line):", Weight = 1 },
      ui:Button{ ID = "Paste", Text = "Paste from Clipboard", Weight = 0 },
      ui:Button{ ID = "Clear", Text = "Clear", Weight = 0 },
    },
    ui:TextEdit{
      ID = "URLs", Weight = 1, AcceptRichText = false,
      PlaceholderText = "https://www.youtube.com/watch?v=...",
    },
    ui:HGroup{
      Weight = 0,
      ui:Label{ Text = "Format:", Weight = 0, MinimumSize = { 60, 0 } },
      ui:ComboBox{ ID = "Format", Weight = 1 },
    },
    ui:HGroup{
      Weight = 0,
      ui:Label{ Text = "Save to:", Weight = 0, MinimumSize = { 60, 0 } },
      ui:LineEdit{ ID = "Folder", Weight = 1 },
      ui:Button{ ID = "Browse", Text = "Browse...", Weight = 0 },
      ui:Button{ ID = "Reveal", Text = "Show in Finder", Weight = 0 },
    },
    ui:CheckBox{ ID = "PerProject", Weight = 0, Text = "Save into a subfolder named after the current project" },
    ui:CheckBox{ ID = "Import", Weight = 0, Text = "Import into the Media Pool (\"" .. MEDIA_POOL_BIN .. "\" bin)" },
    ui:CheckBox{ ID = "Playlist", Weight = 0, Text = "If a link is part of a playlist, download the whole playlist" },
    ui:HGroup{
      Weight = 0,
      ui:Button{ ID = "Convert", Text = "Convert", Weight = 1, MinimumSize = { 0, 30 } },
      ui:Button{ ID = "Cancel", Text = "Cancel", Weight = 0, MinimumSize = { 0, 30 } },
    },
    ui:Label{ ID = "Status", Weight = 0, WordWrap = true, Text = "" },
    ui:TextEdit{ ID = "Log", Weight = 1, ReadOnly = true, Font = ui:Font{ Family = "Menlo", PixelSize = 11 } },
    ui:HGroup{
      Weight = 0,
      ui:Label{ Text = "Log of the last run: " .. prettyPath(LAST_LOG), Weight = 1 },
      ui:Button{ ID = "Update", Text = "Update yt-dlp", Weight = 0 },
    },
  },
})

local itm = win:GetItems()
local timer = ui:Timer{ ID = "Poll", Interval = 500 }
local job -- the running yt-dlp process, if any

for _, format in ipairs(FORMATS) do itm.Format:AddItem(format.label) end

local function setStatus(text)
  itm.Status.Text = text
end

local function setBusy(busy)
  itm.Convert.Enabled = not busy
  itm.Update.Enabled = not busy
  itm.Cancel.Enabled = busy
end

local function readSettingsFromUI()
  local folder = trim(itm.Folder.Text)
  settings.folder = folder ~= "" and expandHome(folder):gsub("/+$", "") or DEFAULT_FOLDER
  settings.format = itm.Format.CurrentIndex
  settings.perProject = itm.PerProject.Checked
  settings.import = itm.Import.Checked
  settings.playlist = itm.Playlist.Checked
  itm.Folder.Text = prettyPath(settings.folder)
end

local function outputFolder()
  if settings.perProject then return settings.folder .. "/" .. projectFolderName() end
  return settings.folder
end

------------------------------------------------------------------------------
-- Running yt-dlp in the background (so Resolve stays responsive)

local function newJobDir()
  local dir = ("%s/%d-%d"):format(JOBS_DIR, os.time(), math.random(100000, 999999))
  mkdirp(dir)
  return dir
end

local function launch(kind, dir, argv, workDir)
  local quoted = {}
  for i, arg in ipairs(argv) do quoted[i] = q(arg) end
  writeFile(dir .. "/run.sh", table.concat({
    "export PATH=" .. q(BIN) .. ":/usr/bin:/bin:/usr/sbin:/sbin",
    "cd " .. q(workDir),
    table.concat(quoted, " "),
    "echo $? > " .. q(dir .. "/exit.tmp") .. " && mv " .. q(dir .. "/exit.tmp") .. " " .. q(dir .. "/exit"),
  }, "\n") .. "\n")
  os.execute("/bin/sh " .. q(dir .. "/run.sh") .. " > " .. q(dir .. "/log") .. " 2>&1 < /dev/null & echo $! > " .. q(dir .. "/pid"))

  job = { kind = kind, dir = dir, log = dir .. "/log", files = dir .. "/files.txt", lastShown = nil }
  setBusy(true)
  timer:Start()
  return job
end

-- Collapse runs of "[download] 42.0% ..." lines so the log stays readable.
local function tidyLog(text)
  local out = {}
  local lastWasProgress = false
  for _, line in ipairs(lines(text)) do
    local isProgress = line:match("^%[download%]%s+[%d%.]+%%") ~= nil
    if isProgress and lastWasProgress then
      out[#out] = line
    else
      out[#out + 1] = line
    end
    lastWasProgress = isProgress
  end
  return out
end

local function showLog(text)
  local all = tidyLog(text)
  local tail = {}
  for i = math.max(1, #all - 14), #all do tail[#tail + 1] = all[i] end
  local shown = table.concat(tail, "\n")
  if shown ~= job.lastShown then
    job.lastShown = shown
    itm.Log.PlainText = shown
  end
end

local function progressText(text)
  local item, count = nil, nil
  for i, n in text:gmatch("Downloading item (%d+) of (%d+)") do item, count = i, n end
  local percent
  for p in text:gmatch("\n%[download%]%s+([%d%.]+)%%") do percent = tonumber(p) end
  local lastTag = nil
  for tag in text:gmatch("\n%[(%w+)%]") do lastTag = tag end

  local prefix = item and ("Item %s of %s: "):format(item, count) or ""
  if lastTag == "ExtractAudio" or lastTag == "Metadata" or lastTag == "MoveFiles" then
    return prefix .. "Converting..."
  elseif percent and lastTag == "download" then
    local filled = math.floor(percent / 5 + 0.5)
    return ("%sDownloading  %s%s  %.0f%%"):format(prefix, ("#"):rep(filled), ("-"):rep(20 - filled), percent)
  end
  return prefix .. "Working..."
end

local function firstError(text)
  for _, line in ipairs(lines(text)) do
    local message = line:match("^ERROR:%s*(.*)")
    if message then return message end
  end
end

local function finish(exitCode, cancelled)
  timer:Stop()
  local finished = job
  job = nil
  local log = readFile(finished.log) or ""
  writeFile(LAST_LOG, log)
  itm.Log.PlainText = table.concat(tidyLog(log), "\n")

  if finished.kind == "update" then
    local all = lines(log)
    setStatus(exitCode == 0 and (all[#all] or "yt-dlp is up to date.") or ("Update failed: " .. (firstError(log) or "see the log above.")))
  elseif cancelled then
    setStatus("Cancelled.")
  else
    local files, seen = {}, {}
    for _, path in ipairs(lines(readFile(finished.files))) do
      if not seen[path] and fileExists(path) then
        seen[path] = true
        files[#files + 1] = path
      end
    end

    local parts = {}
    if #files > 0 then
      parts[#parts + 1] = ("Saved %d file%s to %s."):format(#files, #files == 1 and "" or "s", prettyPath(finished.outDir))
      if finished.import then
        local ok, added, err = pcall(importToMediaPool, files)
        if not ok then added, err = nil, tostring(added) end
        if added == 0 then
          parts[#parts + 1] = "Already in the \"" .. MEDIA_POOL_BIN .. "\" bin."
        elseif added then
          parts[#parts + 1] = ("Added %d clip%s to the \"%s\" bin."):format(added, added == 1 and "" or "s", MEDIA_POOL_BIN)
        else
          parts[#parts + 1] = "Couldn't import into the Media Pool: " .. err .. "."
        end
      end
    end
    if exitCode ~= 0 then
      parts[#parts + 1] = "Error: " .. (firstError(log) or "yt-dlp stopped unexpectedly. See the log above.")
    elseif #files == 0 then
      parts[#parts + 1] = "Nothing was downloaded. See the log above."
    else
      itm.URLs.PlainText = ""
    end
    setStatus(table.concat(parts, " "))
  end

  os.execute("rm -rf " .. q(finished.dir))
  setBusy(false)
end

local function poll()
  if not job then return end
  local log = readFile(job.log) or ""
  showLog(log)
  if job.kind == "convert" then setStatus(progressText("\n" .. log)) end
  local code = readFile(job.dir .. "/exit")
  if code then finish(tonumber(trim(code)) or 1) end
end

local function cancel()
  if not job then return end
  local pid = tonumber(trim(readFile(job.dir .. "/pid") or ""))
  if pid then
    -- Stop the whole process tree (shell -> yt-dlp -> ffmpeg).
    os.execute(("kt() { for c in $(pgrep -P $1); do kt $c; done; kill $1 2>/dev/null; }; kt %d"):format(pid))
  end
  finish(nil, true)
end

local function startConvert()
  if job then return end
  local urls = parseUrls(itm.URLs.PlainText)
  if #urls == 0 then
    setStatus("Paste a YouTube link first.")
    return
  end
  local missing = missingTools()
  if #missing > 0 then
    setStatus("Missing tools (" .. table.concat(missing, ", ") .. "). Run install.sh again.")
    return
  end

  readSettingsFromUI()
  saveSettings()
  local outDir = outputFolder()
  mkdirp(outDir)
  local dir = newJobDir()

  local argv = {
    BIN .. "/yt-dlp",
    "--newline", "--no-colors", "--no-mtime", "--embed-metadata",
    "--ffmpeg-location", BIN,
    settings.playlist and "--yes-playlist" or "--no-playlist",
    "-x",
  }
  if hasIPv4Route() then argv[#argv + 1] = "--force-ipv4" end
  for _, arg in ipairs(FORMATS[settings.format + 1].args) do argv[#argv + 1] = arg end
  for _, arg in ipairs({
    "--postprocessor-args", "ExtractAudio:-ar 48000",
    "-P", outDir,
    "-P", "temp:" .. dir .. "/tmp",
    "-o", "%(title).150B.%(ext)s",
    "--print-to-file", "after_move:filepath", dir .. "/files.txt",
    "--",
  }) do argv[#argv + 1] = arg end
  for _, url in ipairs(urls) do argv[#argv + 1] = url end

  local launched = launch("convert", dir, argv, outDir)
  launched.outDir = outDir
  launched.import = settings.import
  setStatus(("Starting %d link%s..."):format(#urls, #urls == 1 and "" or "s"))
end

------------------------------------------------------------------------------
-- Events

function win.On.Convert.Clicked(ev) startConvert() end
function win.On.Cancel.Clicked(ev) cancel() end

function win.On.Update.Clicked(ev)
  if job then return end
  if not fileExists(BIN .. "/yt-dlp") then
    setStatus("yt-dlp isn't installed. Run install.sh again.")
    return
  end
  setStatus("Checking for a newer yt-dlp...")
  launch("update", newJobDir(), { BIN .. "/yt-dlp", "-U" }, APP_DIR)
end

function win.On.Paste.Clicked(ev)
  local pipe = io.popen("LANG=en_US.UTF-8 /usr/bin/pbpaste")
  local clip = pipe and pipe:read("*a") or ""
  if pipe then pipe:close() end
  local current = trim(itm.URLs.PlainText)
  local pasted = trim(clip)
  if pasted == "" then return end
  itm.URLs.PlainText = current == "" and pasted or (current .. "\n" .. pasted)
end

function win.On.Clear.Clicked(ev)
  itm.URLs.PlainText = ""
end

function win.On.Browse.Clicked(ev)
  local start = expandHome(trim(itm.Folder.Text))
  local chosen = fusion:RequestDir(start ~= "" and start or DEFAULT_FOLDER)
  if chosen and chosen ~= "" then
    itm.Folder.Text = prettyPath((chosen:gsub("/+$", "")))
    readSettingsFromUI()
    saveSettings()
  end
end

function win.On.Reveal.Clicked(ev)
  readSettingsFromUI()
  local dir = outputFolder()
  mkdirp(dir)
  os.execute("open " .. q(dir))
end

function disp.On.Timeout(ev)
  if ev.who == "Poll" then poll() end
end

function win.On.YTtoMP3.Close(ev)
  if job then cancel() end
  disp:ExitLoop()
end

------------------------------------------------------------------------------
-- Start

math.randomseed(os.time())
loadSettings()
mkdirp(JOBS_DIR)
-- Clear out job folders left behind if Resolve quit mid-download.
os.execute("find " .. q(JOBS_DIR) .. " -mindepth 1 -maxdepth 1 -mtime +1 -exec rm -rf {} + 2>/dev/null")

itm.Folder.Text = prettyPath(settings.folder)
itm.Format.CurrentIndex = settings.format
itm.PerProject.Checked = settings.perProject
itm.Import.Checked = settings.import
itm.Playlist.Checked = settings.playlist
setBusy(false)

local missing = missingTools()
if #missing > 0 then
  setStatus("Missing tools (" .. table.concat(missing, ", ") .. "). Run install.sh from the YTtoMP3 folder.")
else
  setStatus("Paste a link and click Convert.")
end

win:Show()
disp:RunLoop()
win:Hide()
