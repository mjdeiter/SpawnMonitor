-- SpawnMonitor.lua
-- v1.7.0 (UX Polish: disabled dropdown when armed, unsaved changes highlight, profile loaded banner)
-- Full featured named camp monitor

local mq = require('mq')
local ImGui = require('ImGui')

local VERSION = 'v1.7.0'
local INI_FILE = mq.configDir .. '/SpawnMonitor.ini'

-- FSM States for individual nameds
local STATUS_DETECTED = 'detected'
local STATUS_MONITORING = 'monitoring'

local state = {
    armed = false,
    radius = 500,        -- Increased default for zone-wide detection
    zRange = 50,         -- Increased default for multi-floor zones
    audioAlert = 'beep',
    soundFile = 'exclamation.wav',
    currentZone = '',
    currentProfile = 'default',
    profiles = {
        default = {
            exactList = {},
            partialList = {}
        }
    },
    trackedNameds = {},
    exactInput = '',
    partialInput = '',
    profileInput = '',
    scanCooldown = 0,
    debugLog = {},
    
    -- HUD Alert Queue (FIFO, bounded)
    hudQueue = {},           -- pending alerts
    activeHUD = nil,         -- currently displayed alert {msg, color, expiresAt}
    hudDisplayTime = 4,      -- seconds per alert
    hudMaxQueue = 5,         -- max queued alerts
    
    -- UX polish
    unsavedChanges = false,  -- Track if settings changed since last save
    profileLoadedTime = 0,   -- Timestamp when profile was loaded (for banner)
}

local openGUI = true

-- ============================================================================
-- UTILITY FUNCTIONS
-- ============================================================================

local function addDebugLog(msg)
    table.insert(state.debugLog, 1, os.date('%H:%M:%S') .. ' - ' .. msg)
    if #state.debugLog > 10 then
        table.remove(state.debugLog)
    end
    print('[DEBUG] ' .. msg)
end

local function trim(s)
    if type(s) ~= 'string' then return '' end
    return s:match('^%s*(.-)%s*$')
end

local function tooltip(text)
    if ImGui.IsItemHovered() then
        ImGui.BeginTooltip()
        ImGui.Text(text)
        ImGui.EndTooltip()
    end
end

-- Robust InputText wrapper (from working v1.0.2)
local function InputTextValue(label, current, maxlen)
    maxlen = maxlen or 64
    local a, b = ImGui.InputText(label, current, maxlen)

    if type(a) == "boolean" then
        -- (changed, value)
        return b or current
    end

    -- (value) or (value, changed)
    if type(a) == "string" then
        return a
    end

    return current
end

-- ============================================================================
-- INI PERSISTENCE
-- ============================================================================

local function saveAllToINI()
    local lines = {}
    
    table.insert(lines, '[Settings]')
    table.insert(lines, 'Radius=' .. tostring(state.radius))
    table.insert(lines, 'ZRange=' .. tostring(state.zRange))
    table.insert(lines, 'AudioAlert=' .. state.audioAlert)
    table.insert(lines, 'SoundFile=' .. state.soundFile)
    table.insert(lines, 'CurrentProfile=' .. state.currentProfile)
    table.insert(lines, 'HUDDisplayTime=' .. tostring(state.hudDisplayTime))
    table.insert(lines, 'HUDMaxQueue=' .. tostring(state.hudMaxQueue))
    table.insert(lines, '')
    
    for profileName, profile in pairs(state.profiles) do
        table.insert(lines, '[Profile_' .. profileName .. ']')
        table.insert(lines, 'ExactList=' .. table.concat(profile.exactList, '|'))
        table.insert(lines, 'PartialList=' .. table.concat(profile.partialList, '|'))
        table.insert(lines, '')
    end
    
    local file = io.open(INI_FILE, 'w')
    if file then
        file:write(table.concat(lines, '\n'))
        file:close()
        state.unsavedChanges = false  -- Clear unsaved changes flag
        addDebugLog('Settings saved to INI')
        return true
    else
        print('ERROR: Could not write to ' .. INI_FILE)
        return false
    end
end

local function loadSettings()
    local radius = mq.TLO.Ini.File(INI_FILE).Section('Settings').Key('Radius').Value()
    if radius and radius ~= 'NULL' then
        state.radius = tonumber(radius) or 500
    end
    
    local zRange = mq.TLO.Ini.File(INI_FILE).Section('Settings').Key('ZRange').Value()
    if zRange and zRange ~= 'NULL' then
        state.zRange = tonumber(zRange) or 50
    end
    
    local audio = mq.TLO.Ini.File(INI_FILE).Section('Settings').Key('AudioAlert').Value()
    if audio and audio ~= 'NULL' then
        state.audioAlert = audio
    end
    
    local sound = mq.TLO.Ini.File(INI_FILE).Section('Settings').Key('SoundFile').Value()
    if sound and sound ~= 'NULL' then
        state.soundFile = sound
    end
    
    local profile = mq.TLO.Ini.File(INI_FILE).Section('Settings').Key('CurrentProfile').Value()
    if profile and profile ~= 'NULL' then
        state.currentProfile = profile
    end
    
    local hudTime = mq.TLO.Ini.File(INI_FILE).Section('Settings').Key('HUDDisplayTime').Value()
    if hudTime and hudTime ~= 'NULL' then
        state.hudDisplayTime = tonumber(hudTime) or 4
    end
    
    local hudMax = mq.TLO.Ini.File(INI_FILE).Section('Settings').Key('HUDMaxQueue').Value()
    if hudMax and hudMax ~= 'NULL' then
        state.hudMaxQueue = tonumber(hudMax) or 5
    end
end

local function loadProfile(profileName)
    local section = 'Profile_' .. profileName
    
    if not state.profiles[profileName] then
        state.profiles[profileName] = {
            exactList = {},
            partialList = {}
        }
    end
    
    local profile = state.profiles[profileName]
    
    local exactStr = mq.TLO.Ini.File(INI_FILE).Section(section).Key('ExactList').Value()
    if exactStr and exactStr ~= 'NULL' and exactStr ~= '' then
        profile.exactList = {}
        for name in string.gmatch(exactStr, '[^|]+') do
            table.insert(profile.exactList, trim(name))
        end
    end
    
    local partialStr = mq.TLO.Ini.File(INI_FILE).Section(section).Key('PartialList').Value()
    if partialStr and partialStr ~= 'NULL' and partialStr ~= '' then
        profile.partialList = {}
        for name in string.gmatch(partialStr, '[^|]+') do
            table.insert(profile.partialList, trim(name))
        end
    end
end

local function loadAllProfiles()
    -- Read INI file directly to discover all profiles
    local file = io.open(INI_FILE, 'r')
    if not file then
        addDebugLog('No INI file found, using defaults')
        return
    end
    
    local discoveredProfiles = {}
    for line in file:lines() do
        local profileName = line:match('^%[Profile_(.+)%]')
        if profileName then
            table.insert(discoveredProfiles, profileName)
        end
    end
    file:close()
    
    -- Load each discovered profile
    for _, profileName in ipairs(discoveredProfiles) do
        loadProfile(profileName)
        addDebugLog('Loaded profile from INI: ' .. profileName)
    end
    
    -- Ensure default profile exists
    if not state.profiles['default'] then
        state.profiles['default'] = {
            exactList = {},
            partialList = {}
        }
        addDebugLog('Created default profile')
    end
end

-- ============================================================================
-- HUD ALERT QUEUE (bounded FIFO, one-at-a-time display)
-- ============================================================================

-- Enqueue a new alert (with duplicate suppression)
local function enqueueHUDAlert(msg, color)
    color = color or {1.0, 0.0, 0.0, 1.0}
    
    -- Check if already active
    if state.activeHUD and state.activeHUD.msg == msg then
        return
    end
    
    -- Check if already queued
    for _, alert in ipairs(state.hudQueue) do
        if alert.msg == msg then
            return
        end
    end
    
    -- Enforce queue limit (drop oldest if full)
    if #state.hudQueue >= state.hudMaxQueue then
        table.remove(state.hudQueue, 1)
        addDebugLog('HUD queue full, dropped oldest alert')
    end
    
    -- Add to queue
    table.insert(state.hudQueue, {msg = msg, color = color})
    addDebugLog(string.format('Enqueued HUD alert: %s (queue size: %d)', msg, #state.hudQueue))
end

-- Update HUD state (call from main loop)
local function updateHUDQueue()
    local now = os.time()
    
    -- Clear expired active HUD
    if state.activeHUD and now >= state.activeHUD.expiresAt then
        addDebugLog('HUD alert expired: ' .. state.activeHUD.msg)
        state.activeHUD = nil
    end
    
    -- Activate next queued alert if none active
    if not state.activeHUD and #state.hudQueue > 0 then
        local nextAlert = table.remove(state.hudQueue, 1)
        state.activeHUD = {
            msg = nextAlert.msg,
            color = nextAlert.color,
            expiresAt = now + state.hudDisplayTime
        }
        addDebugLog(string.format('Activated HUD alert: %s (remaining in queue: %d)', nextAlert.msg, #state.hudQueue))
    end
end

-- ============================================================================
-- AUDIO ALERTS
-- ============================================================================

local function playAlert(namedName)
    -- Audio
    if state.audioAlert == 'beep' then
        mq.cmd('/beep')
    elseif state.audioAlert == 'sound' and state.soundFile ~= '' then
        mq.cmdf('/playsound %s', state.soundFile)
    end
    
    -- Enqueue HUD alert (does not overwrite active/queued alerts)
    enqueueHUDAlert('*** NAMED UP: ' .. namedName .. ' ***', {1.0, 0.0, 0.0, 1.0})
end

-- ============================================================================
-- MATCHING LOGIC
-- ============================================================================

local function matches(name)
    local profile = state.profiles[state.currentProfile]
    if not profile then return false end
    
    local lname = string.lower(name)
    
    for _, e in ipairs(profile.exactList) do
        if lname == string.lower(e) then return true end
    end
    
    for _, p in ipairs(profile.partialList) do
        if lname:find(string.lower(p), 1, true) then return true end
    end
    
    return false
end

-- ============================================================================
-- TARGET SCANNING (DEBUG)
-- ============================================================================

local function scanCurrentTarget()
    local target = mq.TLO.Target
    if not target() then
        addDebugLog('No target selected')
        return
    end
    
    local rawName = target.Name()
    local cleanName = target.CleanName()
    local displayName = target.DisplayName()
    local id = target.ID()
    local distance = target.Distance()
    
    addDebugLog(string.format('TARGET SCAN:'))
    addDebugLog(string.format('  Name (raw): "%s" (type: %s)', tostring(rawName), type(rawName)))
    addDebugLog(string.format('  CleanName: "%s" (type: %s)', tostring(cleanName), type(cleanName)))
    addDebugLog(string.format('  DisplayName: "%s" (type: %s)', tostring(displayName), type(displayName)))
    addDebugLog(string.format('  ID: %s (type: %s)', tostring(id), type(id)))
    addDebugLog(string.format('  Distance: %s', tostring(distance)))
    
    mq.cmdf('/echo Name=[%s] CleanName=[%s] DisplayName=[%s] ID=%s', tostring(rawName), tostring(cleanName), tostring(displayName), tostring(id))
end

-- ============================================================================
-- MULTI-NAMED TRACKING
-- ============================================================================

local function isSpawnInRange(spawnID)
    local spawn = mq.TLO.Spawn(spawnID)
    if not spawn() then return false end
    
    local distance = spawn.Distance() or 999999
    local zDiff = math.abs((spawn.Z() or 0) - (mq.TLO.Me.Z() or 0))
    
    return distance <= state.radius and zDiff <= state.zRange
end

local function updateTrackedNameds()
    for id, data in pairs(state.trackedNameds) do
        if not isSpawnInRange(id) then
            state.trackedNameds[id] = nil
        end
    end
end

local function scan()
    if not state.armed then return end
    
    if state.scanCooldown > 0 then
        state.scanCooldown = state.scanCooldown - 1
        return
    end
    state.scanCooldown = 2
    
    updateTrackedNameds()
    
    local count = mq.TLO.SpawnCount('npc radius ' .. state.radius .. ' zradius ' .. state.zRange)()
    if not count or count == 0 then return end
    
    for i = 1, count do
        local sp = mq.TLO.NearestSpawn(i, 'npc radius ' .. state.radius .. ' zradius ' .. state.zRange)
        if sp() then
            -- Use .Name() for system spawn name (e.g. "Defender_Karrik000")
            local name = sp.Name()
            local id = sp.ID()
            
            -- Robust validation: ensure we have valid string name and numeric ID
            if name and type(name) == 'string' and name ~= '' and id and type(id) == 'number' then
                if matches(name) and not state.trackedNameds[id] then
                    -- Store CleanName for display, but match against raw Name
                    local displayName = sp.CleanName() or name
                    
                    state.trackedNameds[id] = {
                        name = displayName,
                        rawName = name,
                        firstSeen = os.time(),
                        status = STATUS_MONITORING
                    }
                    
                    addDebugLog(string.format('NAMED DETECTED: %s [%s] (ID: %d)', displayName, name, id))
                    mq.cmdf('/echo \\a-t*** NAMED UP: %s (ID: %d) ***\\a-x', displayName, id)
                    playAlert(displayName)
                end
            end
        end
    end
end

-- ============================================================================
-- UI RENDERING
-- ============================================================================

local function drawMonitorTab()
    ImGui.Text('Status: ')
    ImGui.SameLine()
    
    local namedCount = 0
    for _ in pairs(state.trackedNameds) do namedCount = namedCount + 1 end
    
    if namedCount > 0 then
        ImGui.TextColored(1, 0, 0, 1, string.format('%d Named(s) Detected', namedCount))
    else
        ImGui.TextColored(0, 1, 0, 1, 'Waiting for nameds')
    end
    
    ImGui.Separator()
    
    if namedCount > 0 then
        ImGui.TextColored(1, 1, 0, 1, 'Active Nameds:')
        
        -- Build snapshot of tracked nameds to avoid iteration issues
        local snapshot = {}
        for id, data in pairs(state.trackedNameds) do
            if data and data.name and data.firstSeen then
                table.insert(snapshot, {
                    id = id,
                    name = data.name,
                    rawName = data.rawName,
                    firstSeen = data.firstSeen
                })
            end
        end
        
        -- Render from snapshot
        for _, entry in ipairs(snapshot) do
            local elapsed = os.time() - entry.firstSeen
            local displayName = tostring(entry.name)
            local rawName = entry.rawName and (' [' .. entry.rawName .. ']') or ''
            local displayID = tonumber(entry.id) or 0
            ImGui.BulletText(string.format('%s%s (ID: %d) - %ds ago', displayName, rawName, displayID, elapsed))
        end
    else
        ImGui.TextDisabled('No nameds currently detected')
    end
    
    ImGui.Separator()
    
    ImGui.Text(string.format('Scan Range: %d radius, +/-%d Z', state.radius, state.zRange))
    
    -- Profile Dropdown (with UX polish)
    ImGui.Text('Profile: ')
    ImGui.SameLine()
    
    -- Build profile name list (default always first)
    local profileNames = {}
    table.insert(profileNames, 'default')  --  Default always first
    for name, _ in pairs(state.profiles) do
        if name ~= 'default' then
            table.insert(profileNames, name)
        end
    end
    table.sort(profileNames, function(a, b)
        if a == 'default' then return true end
        if b == 'default' then return false end
        return a < b
    end)
    
    -- Find current index
    local currentIndex = 1
    for i, name in ipairs(profileNames) do
        if name == state.currentProfile then
            currentIndex = i
            break
        end
    end
    
    --  Disable dropdown while armed
    if state.armed then
        ImGui.PushStyleColor(ImGuiCol.Text, 0.5, 0.5, 0.5, 1.0)
        ImGui.Text(state.currentProfile)
        ImGui.PopStyleColor()
        tooltip('Disarm to change profiles')
    else
        -- Dropdown enabled
        local result = ImGui.Combo('##profilecombo', currentIndex, profileNames, #profileNames)
        if type(result) == 'number' and result ~= currentIndex and profileNames[result] then
            state.currentProfile = profileNames[result]
            loadProfile(state.currentProfile)
            saveAllToINI()
            state.profileLoadedTime = os.time()  --  Trigger banner
            addDebugLog('Switched to profile: ' .. state.currentProfile)
        end
        tooltip('Quick switch between profiles')
    end
    
    ImGui.Text('Audio: ' .. state.audioAlert)
    
    --  Profile Loaded Banner (3 seconds)
    if os.time() < state.profileLoadedTime + 3 then
        ImGui.SameLine()
        ImGui.TextColored(0, 1, 0, 1, '✓ Loaded')
    end
    
    ImGui.Separator()
    
    local armed = ImGui.Checkbox('Armed##armed', state.armed)
    if type(armed) == 'boolean' then
        state.armed = armed
    end
    tooltip('When armed, the script actively scans for nameds')
    
    ImGui.SameLine()
    
    if ImGui.Button('Clear All Detections') then
        state.trackedNameds = {}
    end
    tooltip('Clear all currently tracked nameds')
    
    ImGui.Separator()
    
    -- DEBUG SECTION
    ImGui.TextColored(1, 0.5, 0, 1, 'Debug Tools:')
    if ImGui.Button('Scan Current Target') then
        scanCurrentTarget()
    end
    tooltip('Debug: Show all name variants for your current target')
    
    ImGui.SameLine()
    if ImGui.Button('Test Center Alert') then
        enqueueHUDAlert('*** TEST ALERT: This is a test! ***', {1.0, 0.0, 0.0, 1.0})
    end
    tooltip('Test the center-screen alert overlay')
    
    ImGui.SameLine()
    if ImGui.Button('Test Multi-Alert') then
        enqueueHUDAlert('*** ALERT 1: First Named ***', {1.0, 0.0, 0.0, 1.0})
        enqueueHUDAlert('*** ALERT 2: Second Named ***', {1.0, 0.5, 0.0, 1.0})
        enqueueHUDAlert('*** ALERT 3: Third Named ***', {1.0, 1.0, 0.0, 1.0})
    end
    tooltip('Test multiple alerts queuing')
    
    if #state.debugLog > 0 then
        ImGui.Separator()
        ImGui.TextColored(0.7, 0.7, 0.7, 1, 'Recent Debug Log:')
        for _, log in ipairs(state.debugLog) do
            ImGui.TextColored(0.5, 0.5, 0.5, 1, log)
        end
    end
    
    -- HUD Queue Status
    if state.activeHUD or #state.hudQueue > 0 then
        ImGui.Separator()
        ImGui.TextColored(1, 1, 0, 1, 'HUD Alert Queue:')
        if state.activeHUD then
            local remaining = state.activeHUD.expiresAt - os.time()
            ImGui.TextColored(0, 1, 0, 1, string.format('Active: %s (%ds)', state.activeHUD.msg, remaining))
        end
        if #state.hudQueue > 0 then
            ImGui.Text(string.format('Queued: %d alert(s)', #state.hudQueue))
            for i, alert in ipairs(state.hudQueue) do
                ImGui.BulletText(string.format('%d: %s', i, alert.msg))
            end
        end
    end
end

local function drawConfigTab()
    local profile = state.profiles[state.currentProfile]
    if not profile then return end
    
    ImGui.TextColored(1, 1, 0, 1, 'Configuration')
    ImGui.Text('Profile: ' .. state.currentProfile)
    
    if state.armed then
        ImGui.TextColored(1, 0.5, 0, 1, 'Disarm to edit watch lists')
        return
    end
    
    ImGui.Separator()
    
    ImGui.Text('Scan Range Settings:')
    local r = ImGui.SliderInt('Radius##radius', state.radius, 50, 5000)
    if type(r) == 'number' and r ~= state.radius then
        state.radius = r
        state.unsavedChanges = true  --  Mark unsaved
    end
    tooltip('Horizontal detection radius (50-5000 units)')
    
    local z = ImGui.SliderInt('Z Range##zrange', state.zRange, 10, 500)
    if type(z) == 'number' and z ~= state.zRange then
        state.zRange = z
        state.unsavedChanges = true  --  Mark unsaved
    end
    tooltip('Vertical detection range (10-500 units, for multi-floor zones)')
    
    ImGui.Separator()
    
    ImGui.Text('Audio Alert:')
    if ImGui.RadioButton('Beep##beep', state.audioAlert == 'beep') then
        state.audioAlert = 'beep'
        state.unsavedChanges = true  --  Mark unsaved
    end
    ImGui.SameLine()
    if ImGui.RadioButton('Sound##sound', state.audioAlert == 'sound') then
        state.audioAlert = 'sound'
        state.unsavedChanges = true  --  Mark unsaved
    end
    ImGui.SameLine()
    if ImGui.RadioButton('None##none', state.audioAlert == 'none') then
        state.audioAlert = 'none'
        state.unsavedChanges = true  --  Mark unsaved
    end
    
    if state.audioAlert == 'sound' then
        local oldSound = state.soundFile
        state.soundFile = InputTextValue('Sound File##soundfile', state.soundFile, 64)
        if state.soundFile ~= oldSound then
            state.unsavedChanges = true  --  Mark unsaved
        end
        tooltip('Sound file in MQ/resources/sounds folder')
    end
    
    ImGui.Separator()
    
    ImGui.Text('HUD Alert Settings:')
    local hudTime = ImGui.SliderInt('Alert Display Time (sec)##hudtime', state.hudDisplayTime, 2, 10)
    if type(hudTime) == 'number' and hudTime ~= state.hudDisplayTime then
        state.hudDisplayTime = hudTime
        state.unsavedChanges = true  --  Mark unsaved (will save on button click)
        addDebugLog('HUD display time changed to ' .. hudTime .. 's')
    end
    tooltip('How long each HUD alert stays on screen (saved)')
    
    local hudMax = ImGui.SliderInt('Max Queued Alerts##hudmax', state.hudMaxQueue, 3, 15)
    if type(hudMax) == 'number' and hudMax ~= state.hudMaxQueue then
        state.hudMaxQueue = hudMax
        state.unsavedChanges = true  --  Mark unsaved (will save on button click)
        addDebugLog('Max HUD queue changed to ' .. hudMax)
    end
    tooltip('Maximum number of alerts that can be queued (saved)')
    
    ImGui.Separator()
    
    -- EXACT MATCHES (using working v1.0.2 pattern)
    ImGui.TextColored(0.5, 1, 1, 1, 'Exact Match Names:')
    
    if #profile.exactList > 0 then
        for i, name in ipairs(profile.exactList) do
            ImGui.BulletText(name)
            ImGui.SameLine()
            ImGui.PushID('exact_del_' .. i)
            if ImGui.SmallButton('X') then
                table.remove(profile.exactList, i)
                saveAllToINI()
                addDebugLog('Removed exact match: ' .. name)
            end
            ImGui.PopID()
        end
    else
        ImGui.TextDisabled('  (no exact matches defined)')
    end
    
    state.exactInput = InputTextValue('##exactinput', state.exactInput, 64)
    tooltip('Name must match exactly (use Scan Target button to see actual name)')
    
    ImGui.SameLine()
    if ImGui.Button('Add##addexact') then
        local val = trim(state.exactInput)
        if val ~= '' then
            table.insert(profile.exactList, val)
            state.exactInput = ''
            saveAllToINI()
            addDebugLog('Added exact match: ' .. val)
        end
    end
    
    ImGui.Separator()
    
    -- PARTIAL MATCHES (using working v1.0.2 pattern)
    ImGui.TextColored(0.5, 1, 1, 1, 'Partial Match Patterns:')
    
    if #profile.partialList > 0 then
        for i, name in ipairs(profile.partialList) do
            ImGui.BulletText(name)
            ImGui.SameLine()
            ImGui.PushID('partial_del_' .. i)
            if ImGui.SmallButton('X') then
                table.remove(profile.partialList, i)
                saveAllToINI()
                addDebugLog('Removed partial match: ' .. name)
            end
            ImGui.PopID()
        end
    else
        ImGui.TextDisabled('  (no partial matches defined)')
    end
    
    state.partialInput = InputTextValue('##partialinput', state.partialInput, 64)
    tooltip('Matches any NPC name containing this text')
    
    ImGui.SameLine()
    if ImGui.Button('Add##addpartial') then
        local val = trim(state.partialInput)
        if val ~= '' then
            table.insert(profile.partialList, val)
            state.partialInput = ''
            saveAllToINI()
            addDebugLog('Added partial match: ' .. val)
        end
    end
    
    ImGui.Separator()
    
    --  Highlight Save button if unsaved changes
    if state.unsavedChanges then
        ImGui.PushStyleColor(ImGuiCol.Button, 1.0, 0.5, 0.0, 1.0)  -- Orange
        ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 1.0, 0.6, 0.2, 1.0)
        ImGui.PushStyleColor(ImGuiCol.ButtonActive, 1.0, 0.4, 0.0, 1.0)
        if ImGui.Button('Save Settings *##save') then
            saveAllToINI()
        end
        ImGui.PopStyleColor(3)
        tooltip('Unsaved changes! Click to save to INI file')
    else
        if ImGui.Button('Save Settings##save') then
            saveAllToINI()
        end
        tooltip('Save all settings and current profile to INI file')
    end
end

local function drawProfilesTab()
    ImGui.TextColored(1, 1, 0, 1, 'Zone Profile Management')
    
    ImGui.Text('Current Zone: ' .. (state.currentZone ~= '' and state.currentZone or 'Unknown'))
    ImGui.Text('Active Profile: ' .. state.currentProfile)
    
    ImGui.Separator()
    
    ImGui.Text('Available Profiles:')
    for name, _ in pairs(state.profiles) do
        local isActive = (name == state.currentProfile)
        if isActive then
            ImGui.TextColored(0, 1, 0, 1, '> ' .. name)
        else
            ImGui.Text('  ' .. name)
            ImGui.SameLine()
            if ImGui.SmallButton('Switch##switch_' .. name) then
                state.currentProfile = name
                saveAllToINI()
            end
            ImGui.SameLine()
            if name ~= 'default' and ImGui.SmallButton('Delete##del_' .. name) then
                state.profiles[name] = nil
                if state.currentProfile == name then
                    state.currentProfile = 'default'
                end
                saveAllToINI()
            end
        end
    end
    
    ImGui.Separator()
    
    ImGui.Text('Create New Profile:')
    state.profileInput = InputTextValue('##profileinput', state.profileInput, 64)
    
    ImGui.SameLine()
    if ImGui.Button('Create') then
        local val = trim(state.profileInput)
        if val ~= '' and not state.profiles[val] then
            state.profiles[val] = {
                exactList = {},
                partialList = {}
            }
            state.currentProfile = val
            state.profileInput = ''
            saveAllToINI()
            addDebugLog('Created profile: ' .. val)
        end
    end
    
    ImGui.Separator()
    
    if ImGui.Button('Use Zone Name as Profile') then
        if state.currentZone ~= '' then
            state.currentProfile = state.currentZone
            if not state.profiles[state.currentZone] then
                state.profiles[state.currentZone] = {
                    exactList = {},
                    partialList = {}
                }
            end
            saveAllToINI()
        end
    end
    tooltip('Create/switch to profile named after current zone')
end

local function draw()
    -- Update HUD queue state (must happen before rendering)
    updateHUDQueue()
    
    -- CENTER-SCREEN HUD (only if active alert exists)
    if state.activeHUD then
        local io = ImGui.GetIO()
        local x = io.DisplaySize.x / 2
        local y = io.DisplaySize.y * 0.20
        
        -- No background (EQ-style)
        ImGui.SetNextWindowBgAlpha(0.0)
        ImGui.SetNextWindowPos(x, y, ImGuiCond.Always, 0.5, 0.5)
        
        ImGui.Begin('##NamedCenterOverlay', nil,
            bit32.bor(ImGuiWindowFlags.NoDecoration, ImGuiWindowFlags.AlwaysAutoResize,
                     ImGuiWindowFlags.NoSavedSettings, ImGuiWindowFlags.NoFocusOnAppearing,
                     ImGuiWindowFlags.NoNav, ImGuiWindowFlags.NoInputs))
        
        ImGui.SetWindowFontScale(2.5)
        
        local msg = state.activeHUD.msg or ''
        local cx, cy = ImGui.GetCursorPos()
        
        -- Shadow
        ImGui.SetCursorPos(cx + 2, cy + 2)
        ImGui.TextColored(0.0, 0.0, 0.0, 1.0, msg)
        
        -- Foreground (color from alert)
        local c = state.activeHUD.color
        ImGui.SetCursorPos(cx, cy)
        ImGui.TextColored(c[1], c[2], c[3], c[4], msg)
        
        ImGui.SetWindowFontScale(1.0)
        ImGui.End()
    end
    
    -- MAIN WINDOW
    openGUI, shouldShow = ImGui.Begin('Spawn Monitor ' .. VERSION, openGUI)
    
    if not shouldShow then
        ImGui.End()
        return
    end
    
    if ImGui.BeginTabBar('MainTabs') then
        if ImGui.BeginTabItem('Monitor') then
            drawMonitorTab()
            ImGui.EndTabItem()
        end
        
        if ImGui.BeginTabItem('Config') then
            drawConfigTab()
            ImGui.EndTabItem()
        end
        
        if ImGui.BeginTabItem('Profiles') then
            drawProfilesTab()
            ImGui.EndTabItem()
        end
        
        ImGui.EndTabBar()
    end
    
    ImGui.End()
    
    if not openGUI then
        mq.exit()
    end
end

-- ============================================================================
-- INITIALIZATION & MAIN LOOP
-- ============================================================================

local function initialize()
    loadSettings()
    loadAllProfiles()
    
    if not state.profiles[state.currentProfile] then
        state.profiles[state.currentProfile] = {
            exactList = {},
            partialList = {}
        }
    end
    
    loadProfile(state.currentProfile)
    
    state.currentZone = mq.TLO.Zone.ShortName() or ''
    
    print('SpawnMonitor v' .. VERSION .. ' initialized')
    print('Current zone: ' .. state.currentZone)
    print('Active profile: ' .. state.currentProfile)
    addDebugLog('Script initialized')
end

mq.imgui.init('SpawnMonitorUI', draw)
initialize()

while openGUI do
    local currentZone = mq.TLO.Zone.ShortName() or ''
    if currentZone ~= state.currentZone then
        state.currentZone = currentZone
    end
    
    scan()
    
    mq.delay(500)
end
