--- sv_setup.lua
--- Database setup & migration

MySQL.ready(function()
    -- Buat tabel kalau belum ada
    local success = pcall(MySQL.scalar.await, 'SELECT 1 FROM `maximgm_plants` LIMIT 1')

    if not success then
        utils.print('Creating maximgm_plants table')
        MySQL.query([[
            CREATE TABLE IF NOT EXISTS `maximgm_plants` (
                `id`         int(11)      NOT NULL AUTO_INCREMENT,
                `coords`     longtext     NOT NULL CHECK (json_valid(`coords`)),
                `time`       datetime     NOT NULL,
                `fertilizer` longtext     NOT NULL CHECK (json_valid(`fertilizer`)),
                `water`      longtext     NOT NULL CHECK (json_valid(`water`)),
                `plantType`  varchar(50)  NOT NULL,
                `owner`      varchar(50)  NOT NULL DEFAULT '',
                `health`     int(3)       NOT NULL DEFAULT 100,
                PRIMARY KEY (`id`)
            )
        ]])
        utils.print('maximgm_plants table created!')
    end
end)

-- =============================================
-- Migration: tambah kolom owner (kalau belum ada)
-- =============================================
MySQL.ready(function()
    local exists = MySQL.scalar.await([[
        SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS
        WHERE TABLE_NAME = 'maximgm_plants' AND COLUMN_NAME = 'owner'
    ]])
    if exists == 0 then
        utils.print('Adding owner column to maximgm_plants...')
        MySQL.query("ALTER TABLE `maximgm_plants` ADD COLUMN `owner` VARCHAR(50) NOT NULL DEFAULT '' AFTER `plantType`")
        utils.print('owner column added!')
    end
end)

-- =============================================
-- ✅ Migration: tambah kolom health (kalau belum ada)
-- =============================================
MySQL.ready(function()
    local exists = MySQL.scalar.await([[
        SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS
        WHERE TABLE_NAME = 'maximgm_plants' AND COLUMN_NAME = 'health'
    ]])
    if exists == 0 then
        utils.print('Adding health column to maximgm_plants...')
        MySQL.query("ALTER TABLE `maximgm_plants` ADD COLUMN `health` INT(3) NOT NULL DEFAULT 100 AFTER `owner`")
        utils.print('health column added!')
    end
end)