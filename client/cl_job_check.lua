--- cl_job_check.lua
--- Client-side job validation (GLOBAL)
--- ✅ requireJobAccess() tersedia di semua file client
--- ✅ _jobAllowed (global) bisa dipakai di canInteract ox_target
--- File ini HARUS di-load PERTAMA sebelum file client lainnya (via fxmanifest)

-- =============================================
-- State global (dibaca cl_plot.lua untuk canInteract)
-- =============================================
_G._jobAllowed = false
_G._jobChecked = false

local function updateJobCache()
    if not Config.EnableJobSystem then
        _G._jobAllowed = true
        _G._jobChecked = true
        return
    end

    local result = lib.callback.await('maximgm_farming:server:checkJob', false)
    _G._jobAllowed = result == true
    _G._jobChecked = true

    if _G._jobAllowed then
        print('^2[MaximGM-Farming]^7 Job check: ALLOWED')
    else
        print('^3[MaximGM-Farming]^7 Job check: DENIED (job not in AllowedJobs)')
    end
end

-- Update cache saat resource start
CreateThread(function()
    Wait(3000)
    updateJobCache()
end)

-- =============================================
-- Auto refresh saat job berubah (QBCore)
-- =============================================
AddEventHandler('QBCore:Client:OnPlayerLoaded', function()
    Wait(1000); updateJobCache()
end)

AddEventHandler('QBCore:Client:OnJobUpdate', function()
    Wait(500); updateJobCache()
end)

-- =============================================
-- Auto refresh saat job berubah (ESX)
-- =============================================
AddEventHandler('esx:playerLoaded', function()
    Wait(1000); updateJobCache()
end)

AddEventHandler('esx:setJob', function()
    Wait(500); updateJobCache()
end)

-- =============================================
-- Global Job Check Function
-- Dipanggil dari cl_plot.lua, interactions.lua, planting.lua
-- =============================================

function requireJobAccess()
    if not Config.EnableJobSystem then
        return true
    end

    if not _G._jobChecked then
        updateJobCache()
    end

    if not _G._jobAllowed then
        utils.notify(
            Locales['notify_title_farming'] or 'Farming',
            Config.JobDeniedMessage or 'You need a farming job to do that!',
            'error',
            4000
        )
        return false
    end

    return true
end

exports('refreshJobCache', function()
    updateJobCache()
end)

print('^2[MaximGM-Farming]^7 Client job check loaded!')