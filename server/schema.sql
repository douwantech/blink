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
INSERT IGNORE INTO shared_ai_config (id, data) VALUES (1, JSON_OBJECT('userGlossary', '用户专属术语表（固定，最高优先级；ASR 一旦出现近音写法，直接改成规范写法，即使词表/修正记录里没有）：
工具 / 命令：
- claude（听成 cloud / Cloud / cloudcode / CloudAI / 卡了带 / 卡老的 / 卡密）
- Claude Code（cloudcode / cloud code / CloudCodeAI）
- Claude（句中作产品名时首字母大写）
- git（get / q帕）；github（计划 / git hub）；commit（给客密）；merge（默记 / 给默记）
- PR（皮阿 / 皮啊 / P2 / P啊 / 一休）；issue（医院 / 艺术出来 / 哎呦）
- safecmd（SFCMD / selfcmd / Safemind / safe command）
- tmux（tmus）；cmux（CMS / 新music）；socket（sokia / sock / Sokki / SOCKET）
- SSH（sh / SS / ssh 规范为大写 SSH）；zsh（Jessie）；status（Stadia）
- oss（OSI / OHS）；ipa（IPA）；wiki（viki / wick / week / wikie / Viki）
- proxy（process / AIprocess）；VPN（V P N / VPA）
- tailscale（tailsquare）；clashx（crossX / CrossX）；Clash（Crash）
- peekaboo（Pico）；tab（table / tap）；tabbar（tablebar / tableau）；toolbar（拖把）
项目 / 专名：
- Mac（麦克 / max / make / Max / Make）；admin（A的门 / Adam）
- cto（GTO）；dev skill（deepseek 剧情 / devskull / devskill）；cto skill（GTO skill）
- binsoft（冰社 / BingSoft）；binku87（冰库八七）；binsoft-dev（大夫 / deep）
- blink；blinkd（BlinkD）；talkai
中文常错：
- 主分支（主分词）；原型（圆形）；弹窗（糖床 / 棒糖窗 / 棒糖 / 堂装 / 半弹窗听成堂装）
- 真机（蒸鸡）；横幅（红福 / banner）；均摊（金汤）
- 边距（的编辑）；错题（彻底）
规则：以上是发音提示，不要机械套用到语义完全无关的句子；拿不准就保留原文，别硬改。'));
