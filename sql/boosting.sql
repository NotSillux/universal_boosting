-- Universal Boosting — database schema.
-- Auto-created on first start (server/db.lua); provided here for manual installs.

CREATE TABLE IF NOT EXISTS `boosting_profiles` (
    `identifier` VARCHAR(64) NOT NULL,
    `name` VARCHAR(64) DEFAULT NULL,
    `level` INT NOT NULL DEFAULT 1,
    `xp` INT NOT NULL DEFAULT 0,
    `hacker_xp` INT NOT NULL DEFAULT 0,
    `driver_xp` INT NOT NULL DEFAULT 0,
    `completed` INT NOT NULL DEFAULT 0,
    `earnings` BIGINT NOT NULL DEFAULT 0,
    `weekly_xp` INT NOT NULL DEFAULT 0,
    `weekly_hacker` INT NOT NULL DEFAULT 0,
    `weekly_driver` INT NOT NULL DEFAULT 0,
    `week_tag` VARCHAR(16) DEFAULT NULL,
    `updated_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (`identifier`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `boosting_groups` (
    `id` VARCHAR(24) NOT NULL,
    `leader` VARCHAR(64) NOT NULL,
    `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `boosting_contracts` (
    `id` VARCHAR(24) NOT NULL,
    `owner` VARCHAR(64) NOT NULL,
    `tier` VARCHAR(4) NOT NULL,
    `model` VARCHAR(48) NOT NULL,
    `reward` INT NOT NULL,
    `state` VARCHAR(24) NOT NULL DEFAULT 'assigned',
    `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_owner` (`owner`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `boosting_auctions` (
    `id` VARCHAR(24) NOT NULL,
    `seller` VARCHAR(64) NOT NULL,
    `seller_name` VARCHAR(64) DEFAULT NULL,
    `tier` VARCHAR(4) NOT NULL,
    `model` VARCHAR(48) NOT NULL,
    `reward` INT NOT NULL,
    `start_price` INT NOT NULL,
    `buyout` INT DEFAULT NULL,
    `top_bid` INT DEFAULT NULL,
    `top_bidder` VARCHAR(64) DEFAULT NULL,
    `top_bidder_name` VARCHAR(64) DEFAULT NULL,
    `ends_at` INT NOT NULL,
    `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `boosting_history` (
    `id` INT NOT NULL AUTO_INCREMENT,
    `identifier` VARCHAR(64) NOT NULL,
    `tier` VARCHAR(4) NOT NULL,
    `model` VARCHAR(48) NOT NULL,
    `outcome` VARCHAR(24) NOT NULL,
    `reward` INT NOT NULL DEFAULT 0,
    `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_identifier` (`identifier`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- registry of VIN-scratched vehicles (their new clean plates) — the police
-- VIN check looks plates up here
CREATE TABLE IF NOT EXISTS `boosting_vin_records` (
    `plate` VARCHAR(12) NOT NULL,
    `identifier` VARCHAR(64) NOT NULL,
    `model` VARCHAR(48) NOT NULL,
    `tier` VARCHAR(4) DEFAULT NULL,
    `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`plate`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- audit log of police VIN checks (/boostadmin vinlogs)
CREATE TABLE IF NOT EXISTS `boosting_vin_checks` (
    `id` INT NOT NULL AUTO_INCREMENT,
    `officer` VARCHAR(64) NOT NULL,
    `officer_name` VARCHAR(64) DEFAULT NULL,
    `plate` VARCHAR(12) NOT NULL,
    `result` VARCHAR(16) NOT NULL,
    `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_plate` (`plate`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
