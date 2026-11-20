import Foundation

/// 表结构与升级。见 docs/数据模型.md §3。
///
/// 用 `PRAGMA user_version` 记版本；每个版本一段 SQL，按顺序执行，已执行过的跳过。
enum Schema {
    static let migrations: [String] = [
        // 1：M1 的核心表。收藏夹先建最小的两张表，扫描中断的测试要核对收藏夹可见性。
        """
        CREATE TABLE volumes (
            id INTEGER PRIMARY KEY,
            volume_uuid TEXT NOT NULL,
            name TEXT NOT NULL,
            scan_root TEXT NOT NULL,
            capacity_bytes INTEGER,
            filesystem TEXT,
            status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'removed')),
            created_at REAL NOT NULL,
            removed_at REAL,
            last_seen_at REAL,
            last_scanned_at REAL
        );
        -- 已移除的卷重新插上时建新记录，所以只要求在用的卷 UUID 唯一。
        CREATE UNIQUE INDEX volumes_active_uuid ON volumes(volume_uuid) WHERE status = 'active';

        CREATE TABLE import_batches (
            id INTEGER PRIMARY KEY,
            volume_id INTEGER NOT NULL REFERENCES volumes(id),
            started_at REAL NOT NULL,
            finished_at REAL,
            photo_count INTEGER NOT NULL DEFAULT 0
        );

        CREATE TABLE photos (
            id INTEGER PRIMARY KEY,
            identity_key TEXT NOT NULL UNIQUE,
            base_name TEXT NOT NULL,
            file_number INTEGER,
            capture_date TEXT,
            capture_subsec TEXT,
            camera_make TEXT,
            camera_model TEXT,
            lens TEXT,
            focal_length REAL,
            aperture REAL,
            shutter REAL,
            iso INTEGER,
            width INTEGER,
            height INTEGER,
            latitude REAL,
            longitude REAL,
            geo_cell TEXT,
            place_id INTEGER,
            rating INTEGER NOT NULL DEFAULT 0 CHECK (rating BETWEEN 0 AND 5),
            flag TEXT NOT NULL DEFAULT 'none' CHECK (flag IN ('none', 'pick', 'reject')),
            preview_file_id INTEGER,
            thumb_state TEXT NOT NULL DEFAULT 'pending' CHECK (thumb_state IN ('pending', 'ready', 'failed')),
            preview_state TEXT NOT NULL DEFAULT 'pending' CHECK (preview_state IN ('pending', 'ready', 'failed')),
            ocr_state TEXT NOT NULL DEFAULT 'pending',
            face_state TEXT NOT NULL DEFAULT 'pending',
            present_location_count INTEGER NOT NULL DEFAULT 0 CHECK (present_location_count >= 0),
            imported_at REAL NOT NULL,
            import_batch_id INTEGER REFERENCES import_batches(id)
        );
        -- 网格的主查询：可见照片按拍摄时间排序。
        CREATE INDEX photos_visible_date ON photos(present_location_count, capture_date, capture_subsec, base_name);
        CREATE INDEX photos_batch ON photos(import_batch_id);

        CREATE TABLE files (
            id INTEGER PRIMARY KEY,
            photo_id INTEGER NOT NULL REFERENCES photos(id) ON DELETE CASCADE,
            extension TEXT NOT NULL,
            kind TEXT NOT NULL,
            file_size INTEGER NOT NULL,
            UNIQUE (photo_id, extension)
        );

        CREATE TABLE locations (
            id INTEGER PRIMARY KEY,
            file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
            volume_id INTEGER NOT NULL REFERENCES volumes(id),
            relative_path TEXT NOT NULL,
            dir_path TEXT NOT NULL,
            file_size INTEGER NOT NULL,
            file_mtime REAL NOT NULL,
            status TEXT NOT NULL CHECK (status IN ('present', 'historical')),
            last_seen_at REAL NOT NULL
        );
        -- 同一路径只能有一个现存位置；历史位置可以有多条（先后放过的不同照片）。
        CREATE UNIQUE INDEX locations_present_path ON locations(volume_id, relative_path) WHERE status = 'present';
        CREATE INDEX locations_path ON locations(volume_id, relative_path);
        CREATE INDEX locations_dir ON locations(volume_id, dir_path, status);
        CREATE INDEX locations_file ON locations(file_id);

        CREATE TABLE scan_dirs (
            volume_id INTEGER NOT NULL REFERENCES volumes(id),
            dir_path TEXT NOT NULL,
            state TEXT NOT NULL CHECK (state IN ('complete', 'incomplete')),
            last_complete_at REAL,
            last_error TEXT,
            PRIMARY KEY (volume_id, dir_path)
        );

        CREATE TABLE collections (
            id INTEGER PRIMARY KEY,
            name TEXT NOT NULL,
            created_at REAL NOT NULL,
            last_used_at REAL
        );
        CREATE TABLE collection_members (
            collection_id INTEGER NOT NULL REFERENCES collections(id) ON DELETE CASCADE,
            photo_id INTEGER NOT NULL REFERENCES photos(id) ON DELETE CASCADE,
            added_at REAL NOT NULL,
            PRIMARY KEY (collection_id, photo_id)
        );
        """,
        // 2：M2 选片。标签固定 9 个位置，顺序决定快捷键；名字为空表示这个位置没用（信息架构 §3.3.2）。
        """
        CREATE TABLE labels (
            id INTEGER PRIMARY KEY,
            name TEXT NOT NULL DEFAULT '',
            color TEXT NOT NULL,
            sort_order INTEGER NOT NULL UNIQUE
        );
        INSERT INTO labels (name, color, sort_order) VALUES
            ('经典', '#e5484d', 0), ('人像', '#f5a524', 1), ('风景', '#30a46c', 2), ('人文', '#3e63dd', 3),
            ('', '#8e4ec6', 4), ('', '#12a594', 5), ('', '#e93d82', 6), ('', '#ad7f58', 7), ('', '#8b8d98', 8);
        CREATE TABLE photo_labels (
            photo_id INTEGER NOT NULL REFERENCES photos(id) ON DELETE CASCADE,
            label_id INTEGER NOT NULL REFERENCES labels(id) ON DELETE CASCADE,
            PRIMARY KEY (photo_id, label_id)
        ) WITHOUT ROWID;
        CREATE INDEX photo_labels_label ON photo_labels(label_id);
        CREATE INDEX collection_members_photo ON collection_members(photo_id);
        """,
        // 3：库级别的一次性整理做没做过（比如按预览校正照片尺寸）。
        """
        CREATE TABLE library_meta (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        ) WITHOUT ROWID;
        """,
        // 4：M5 命令行按编号、按文件名找照片。
        """
        CREATE INDEX photos_number ON photos(file_number);
        CREATE INDEX photos_base_name ON photos(base_name COLLATE NOCASE);
        """,
        // 5：M6 后台分析。照片表里早就有 ocr_state、face_state（默认 pending）、geo_cell。
        """
        CREATE TABLE people (
            id INTEGER PRIMARY KEY,
            name TEXT,
            is_hidden INTEGER NOT NULL DEFAULT 0,
            -- 归在这个人物下、有特征的脸的特征之和与张数：归新脸时和它的平均方向比，不用每次读全部特征。
            feature_sum BLOB,
            face_count INTEGER NOT NULL DEFAULT 0,
            created_at REAL NOT NULL
        );
        CREATE INDEX people_name ON people(name) WHERE name IS NOT NULL;
        CREATE TABLE faces (
            id INTEGER PRIMARY KEY,
            photo_id INTEGER NOT NULL REFERENCES photos(id) ON DELETE CASCADE,
            person_id INTEGER REFERENCES people(id) ON DELETE SET NULL,
            -- 在 1600 预览里的位置，0–1，左上为原点。
            x REAL NOT NULL, y REAL NOT NULL, w REAL NOT NULL, h REAL NOT NULL,
            quality REAL NOT NULL,
            -- 512 个 float32，L2 归一化；太小、太糊的脸没有特征，只记位置。
            feature BLOB,
            -- 用户说过“不是 TA”的人物：这张脸不再自动归进去。
            rejected_person_id INTEGER
        );
        CREATE INDEX faces_photo ON faces(photo_id);
        CREATE INDEX faces_person ON faces(person_id);
        -- 等待归属的脸（有特征、没人物）。
        CREATE INDEX faces_unassigned ON faces(id) WHERE person_id IS NULL AND feature IS NOT NULL;
        CREATE INDEX photos_ocr_state ON photos(ocr_state) WHERE ocr_state = 'pending';
        CREATE INDEX photos_face_state ON photos(face_state) WHERE face_state = 'pending';

        -- OCR 文字，rowid 就是照片 id。trigram 分词：中文没有空格，按三个字一组建索引，任意一段文字都能搜到。
        CREATE VIRTUAL TABLE ocr_text USING fts5(text, tokenize = 'trigram');

        -- 地名缓存：一个约 1 公里的网格一行（坐标取两位小数）。
        CREATE TABLE places (
            geo_cell TEXT PRIMARY KEY,
            name TEXT,
            detail TEXT,
            state TEXT NOT NULL CHECK (state IN ('found', 'none', 'failed')),
            fetched_at REAL NOT NULL
        ) WITHOUT ROWID;
        CREATE INDEX photos_geo_cell ON photos(geo_cell) WHERE geo_cell IS NOT NULL;
        """,
        // 0.6.x：相机记录的对焦框。原片在线时后台读文件头（`FocusRunner`），卡拔掉以后照样能显示。
        """
        -- pending 还没读；found 读到了；none 这台相机没记（或没对上焦）。
        ALTER TABLE photos ADD COLUMN focus_state TEXT NOT NULL DEFAULT 'pending';
        -- 转正后的照片上，左上为原点，0–1。
        ALTER TABLE photos ADD COLUMN focus_x REAL;
        ALTER TABLE photos ADD COLUMN focus_y REAL;
        ALTER TABLE photos ADD COLUMN focus_w REAL;
        ALTER TABLE photos ADD COLUMN focus_h REAL;
        CREATE INDEX photos_focus_state ON photos(focus_state) WHERE focus_state = 'pending';
        """
    ]

    static func migrate(_ database: Database) throws {
        let current = try database.scalarInt("PRAGMA user_version;")
        guard current < migrations.count else { return }
        try database.transaction {
            for version in current..<migrations.count {
                try database.execute(migrations[version])
            }
            try database.execute("PRAGMA user_version = \(migrations.count);")
        }
    }
}
