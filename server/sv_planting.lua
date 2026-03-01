--- Plant System - Server Core
--- ✅ Decay per-plant mengikuti growTime masing-masing tanaman
--- ✅ Decay tick = growTime / 2 (misal growTime 4 menit → decay tiap 2 menit)
--- ✅ Health disimpan di DB sebagai field terpisah
--- ✅ time parsing dari MySQL DATETIME string

local globalState = GlobalState

_G.PlantCache = {}
local PlantCache = _G.PlantCache
local Plants     = {}

local Plant = {}
Plant.__index = Plant

-- =============================================
-- Helpers
-- =============================================

local function parseDbTime(raw)
    if type(raw) == 'number' then
        return raw > 1e10 and math.floor(raw / 1000) or math.floor(raw)
    elseif type(raw) == 'string' then
        local y, mo, d, h, m, s = raw:match('(%d+)-(%d+)-(%d+) (%d+):(%d+):(%d+)')
        if y then
            return os.time({
                year  = tonumber(y),  month = tonumber(mo), day = tonumber(d),
                hour  = tonumber(h),  min   = tonumber(m),  sec = tonumber(s)
            })
        end
    end
    return os.time()
end

local function findSourceByIdentifier(identifier)
    if not identifier or identifier == '' then return nil end
    for _, playerId in ipairs(GetPlayers()) do
        local src    = tonumber(playerId)
        local Player = server.GetPlayerFromId(src)
        if Player then
            local pd = server.getPlayerData(Player)
            if pd and pd.identifier == identifier then return src end
        end
    end
    return nil
end

-- =============================================
-- Plant Class
-- =============================================

function Plant:create(id, coords, time, plantType, owner, fertilizer, water, health)
    local plant = setmetatable({}, Plant)

    plant.id         = id
    plant.coords     = coords
    plant.time       = time or os.time()
    plant.plantType  = plantType
    plant.owner      = owner or ''
    plant.fertilizer = fertilizer or {}
    plant.water      = water or {}
    plant.health     = health ~= nil and tonumber(health) or 100

    Plants[id]    = plant
    PlantCache[id] = { coords = coords, time = time, plantType = plantType, owner = owner }

    return plant
end

function Plant:new(coords, plantType, owner)
    if not coords or type(coords) ~= 'vector3' then return false, 'Coords must be a vector3' end
    if not Config.Plants[plantType] then return false, 'Invalid plant type' end

    local time = os.time()

    local id = MySQL.insert.await([[
        INSERT INTO `maximgm_plants` (`coords`, `time`, `fertilizer`, `water`, `plantType`, `owner`, `health`)
        VALUES (:coords, :time, :fertilizer, :water, :plantType, :owner, :health)
    ]], {
        coords     = json.encode(coords),
        time       = os.date('%Y-%m-%d %H:%M:%S', time),
        fertilizer = json.encode({}),
        water      = json.encode({}),
        plantType  = plantType,
        owner      = owner or '',
        health     = 100,
    })

    if not id then return false, 'Failed to insert plant into database' end

    local plant = Plant:create(id, coords, time, plantType, owner, {}, {}, 100)

    TriggerClientEvent('maximgm-farming:client:NewPlant', -1, id, coords, time, plantType)
    print(string.format('^2[MaximGM-Farming]^7 New plant: ID=%d Type=%s Owner=%s', id, plantType, owner))

    return plant
end

function Plant:remove()
    local id = self.id
    self._decayStopped = true  -- Stop decay loop

    MySQL.query.await('DELETE FROM `maximgm_plants` WHERE `id` = :id', { id = id })

    Plants[id]    = nil
    PlantCache[id] = nil

    TriggerClientEvent('maximgm-farming:client:RemovePlant', -1, id)
    return true
end

function Plant:set(property, value)
    self[property] = value
end

function Plant:save()
    local rows = MySQL.update.await([[
        UPDATE `maximgm_plants` SET
            `coords`     = :coords,
            `time`       = :time,
            `fertilizer` = :fertilizer,
            `water`      = :water,
            `plantType`  = :plantType,
            `owner`      = :owner,
            `health`     = :health
        WHERE `id` = :id
    ]], {
        coords     = json.encode(self.coords),
        time       = os.date('%Y-%m-%d %H:%M:%S', self.time),
        fertilizer = json.encode(self.fertilizer),
        water      = json.encode(self.water),
        plantType  = self.plantType,
        owner      = self.owner or '',
        health     = math.max(0, math.min(100, math.floor(self.health or 100))),
        id         = self.id
    })
    return rows > 0
end

function Plant:getPlant(id)
    return Plants[id]
end

-- =============================================
-- Calculation Methods
-- =============================================

function Plant:calcGrowth()
    local plantConfig = Config.Plants[self.plantType]
    if not plantConfig then return 0 end
    local progress = os.difftime(os.time(), self.time)
    return math.min(lib.math.round(progress * 100 / (plantConfig.growTime * 60), 2), 100.00)
end

function Plant:calcStage()
    local plantConfig = Config.Plants[self.plantType]
    if not plantConfig then return 1 end
    local growth = math.min(lib.math.round(os.difftime(os.time(), self.time) * 100 / (plantConfig.growTime * 60), 2), 100.00)
    return math.min(5, math.floor((growth - 1) / 20) + 1)
end

function Plant:calcFertilizer()
    if #self.fertilizer == 0 then return 0 end
    local elapsed = os.difftime(os.time(), self.fertilizer[#self.fertilizer])
    return math.max(lib.math.round(100 - (elapsed / 60 * Config.FertilizerDecay), 2), 0.00)
end

function Plant:calcTotalFertilizer()
    return #self.fertilizer
end

function Plant:calcWater()
    if #self.water == 0 then return 0 end
    local elapsed = os.difftime(os.time(), self.water[#self.water])
    return math.max(lib.math.round(100 - (elapsed / 60 * Config.WaterDecay), 2), 0.00)
end

-- ✅ calcHealth langsung dari field, bukan kalkulasi retroaktif
function Plant:calcHealth()
    return math.max(0, math.min(100, self.health or 100))
end

-- =============================================
-- DECAY LOOP - jalan tiap 1 menit (60 detik)
-- Damage random dari Config.HealthBaseDecay {min, max}
-- =============================================

local function runDecayLoop()
    CreateThread(function()
        Wait(5000)

        print(string.format(
            '^2[MaximGM-Farming]^7 Decay loop started | Tick: 60s | Damage: %d-%d per tick | WaterThreshold: %d%% | FertThreshold: %d%%',
            Config.HealthBaseDecay[1], Config.HealthBaseDecay[2],
            Config.WaterThreshold, Config.FertilizerThreshold
        ))

        while true do
            Wait(60 * 1000) -- Tick setiap 1 menit

            local processed = 0
            local decayed   = 0

            for id, plant in pairs(Plants) do
                if not plant or plant._decayStopped then goto continue end
                processed = processed + 1

                local water      = plant:calcWater()
                local fertilizer = plant:calcFertilizer()
                local changed    = false

                -- ✅ Damage RANDOM setiap tick dari range Config.HealthBaseDecay
                local dmgWater = math.random(Config.HealthBaseDecay[1], Config.HealthBaseDecay[2])
                local dmgFert  = math.random(Config.HealthBaseDecay[1], Config.HealthBaseDecay[2])

                if water < Config.WaterThreshold then
                    plant.health = plant.health - dmgWater
                    changed      = true
                    print(string.format('^3[Decay]^7 ID=%d water=%.0f%% → -%d hp (now %d)',
                        id, water, dmgWater, math.floor(plant.health)))
                end

                if fertilizer < Config.FertilizerThreshold then
                    plant.health = plant.health - dmgFert
                    changed      = true
                    print(string.format('^3[Decay]^7 ID=%d fert=%.0f%% → -%d hp (now %d)',
                        id, fertilizer, dmgFert, math.floor(plant.health)))
                end

                if changed then
                    plant.health = math.max(0, plant.health)
                    plant:save()
                    decayed = decayed + 1
                end

                -- ── Notifikasi owner ──────────────────────────
                local health   = plant:calcHealth()
                local ownerSrc = findSourceByIdentifier(plant.owner)

                if health <= 0 then
                    print(string.format('^1[Decay]^7 Plant ID=%d DEAD', id))
                    if ownerSrc then
                        utils.notify(ownerSrc, Locales['notify_title_farming'],
                            Locales['plant_server_dead'] or '💀 One of your plants has died!', 'error', 8000)
                    end
                    if Config.PlantHealth.AutoDeleteDead then
                        if ownerSrc then
                            TriggerClientEvent('maximgm-farming:client:Plant:AutoDelete', ownerSrc, id)
                        end
                        plant:remove()
                    end

                elseif health <= Config.PlantHealth.DyingThreshold and changed then
                    if ownerSrc then
                        utils.notify(ownerSrc, Locales['notify_title_farming'],
                            string.format(
                                Locales['plant_server_dying'] or '⚠️ Plant dying! Health: %d%% | Water: %d%% | Fertilizer: %d%%',
                                math.floor(health), math.floor(water), math.floor(fertilizer)
                            ), 'warning', 6000)
                    end

                elseif health <= Config.PlantHealth.HealthyThreshold and changed then
                    if ownerSrc and (water < Config.WaterThreshold + 20 or fertilizer < Config.FertilizerThreshold + 20) then
                        utils.notify(ownerSrc, Locales['notify_title_farming'],
                            string.format(
                                Locales['plant_server_needs_care'] or '🌿 Plant needs care! Water: %d%% | Fertilizer: %d%%',
                                math.floor(water), math.floor(fertilizer)
                            ), 'primary', 5000)
                    end
                end

                ::continue::
            end

            if decayed > 0 then
                print(string.format('^3[Decay]^7 Tick done | %d plants processed | %d decayed', processed, decayed))
            end
        end
    end)
end

-- =============================================
-- Setup
-- =============================================

local setupPlants = function()
    local clear  = Config.ClearOnStartup
    local result = MySQL.Sync.fetchAll('SELECT * FROM `maximgm_plants`')

    local plantCount   = 0
    local clearedCount = 0

    for _, data in pairs(result) do
        local coords     = json.decode(data.coords)
        local fertilizer = json.decode(data.fertilizer)
        local water      = json.decode(data.water)
        local time       = parseDbTime(data.time)
        local owner      = data.owner or ''
        local health     = tonumber(data.health) or 100

        local plant = Plant:create(data.id, vector3(coords.x, coords.y, coords.z), time, data.plantType, owner, fertilizer, water, health)

        if clear and health <= 0 then
            plant:remove()
            clearedCount = clearedCount + 1
        else
            plantCount = plantCount + 1
        end
    end

    print(string.format('^2[MaximGM-Farming]^7 Loaded %d plants (cleared %d dead)', plantCount, clearedCount))
end

_G.Plant = Plant

CreateThread(function()
    Wait(2000)
    setupPlants()
    runDecayLoop() -- 1 global loop, tick tiap 1 menit

    while true do
        globalState.MaximgmFarmingTime = os.time()
        Wait(1000)
    end
end)