-- Optional: Die Tabellen werden beim Start der Resource automatisch erstellt
-- (bestehende bus_routes-Tabellen werden automatisch um line_no / course_no erweitert).

CREATE TABLE IF NOT EXISTS `bus_users` (
    `id` INT NOT NULL AUTO_INCREMENT,
    `name` VARCHAR(32) NOT NULL,
    `password` CHAR(64) NOT NULL,
    `created_by` VARCHAR(100) NOT NULL DEFAULT '',
    `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    UNIQUE KEY `name` (`name`)
);

CREATE TABLE IF NOT EXISTS `bus_routes` (
    `id` INT NOT NULL AUTO_INCREMENT,
    `name` VARCHAR(64) NOT NULL,
    `line_no` INT NOT NULL DEFAULT 0,
    `course_no` INT NOT NULL DEFAULT 0,
    `pay` INT NOT NULL DEFAULT 150,
    `stops` LONGTEXT NOT NULL,
    PRIMARY KEY (`id`)
);

CREATE TABLE IF NOT EXISTS `bus_logs` (
    `id` INT NOT NULL AUTO_INCREMENT,
    `actor` VARCHAR(100) NOT NULL DEFAULT '',
    `action` VARCHAR(60) NOT NULL DEFAULT '',
    `details` VARCHAR(255) NOT NULL DEFAULT '',
    `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`)
);

CREATE TABLE IF NOT EXISTS `bus_settings` (
    `skey` VARCHAR(40) NOT NULL,
    `svalue` VARCHAR(255) NOT NULL DEFAULT '',
    PRIMARY KEY (`skey`)
);
