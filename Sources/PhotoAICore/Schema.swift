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
