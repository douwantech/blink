CREATE TABLE IF NOT EXISTS users (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
  username VARCHAR(100) NOT NULL UNIQUE,
  password_hash VARCHAR(255) NOT NULL,
  is_admin BOOLEAN NOT NULL DEFAULT FALSE,
  can_write BOOLEAN NOT NULL DEFAULT FALSE,
  disabled BOOLEAN NOT NULL DEFAULT FALSE,
  config_version BIGINT UNSIGNED NOT NULL DEFAULT 1,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS sessions (
  token_hash BINARY(32) NOT NULL PRIMARY KEY,
  user_id BIGINT UNSIGNED NOT NULL,
  expires_at TIMESTAMP NOT NULL,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  INDEX sessions_user_id (user_id),
  CONSTRAINT sessions_user_fk FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS login_limits (
  identity_hash BINARY(32) NOT NULL PRIMARY KEY,
  window_start TIMESTAMP NOT NULL,
  attempts INT UNSIGNED NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS config_versions (
  id TINYINT UNSIGNED NOT NULL PRIMARY KEY,
  version BIGINT UNSIGNED NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
INSERT IGNORE INTO config_versions (id, version) VALUES (1, 1);

CREATE TABLE IF NOT EXISTS machines (
  id VARCHAR(100) NOT NULL PRIMARY KEY,
  position INT NOT NULL DEFAULT 0,
  data JSON NOT NULL,
  updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS user_configs (
  user_id BIGINT UNSIGNED NOT NULL PRIMARY KEY,
  tabs JSON NULL,
  recent_selection JSON NULL,
  agents JSON NULL,
  CONSTRAINT user_configs_user_fk FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Voice corrections are personal configuration. Keeping them in their own
-- table lets existing user_configs rows migrate without an ALTER statement.
CREATE TABLE IF NOT EXISTS voice_corrections (
  user_id BIGINT UNSIGNED NOT NULL PRIMARY KEY,
  data JSON NOT NULL,
  CONSTRAINT voice_corrections_user_fk FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- AI configuration is shared by every account. The singleton row is versioned
-- through config_versions, like the shared machine catalogue.
CREATE TABLE IF NOT EXISTS shared_ai_config (
  id TINYINT UNSIGNED NOT NULL PRIMARY KEY,
  data JSON NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
INSERT IGNORE INTO shared_ai_config (id, data) VALUES (1, '{"userGlossary":""}');
