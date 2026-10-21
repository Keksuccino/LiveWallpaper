use std::{
    fs::{self, File, OpenOptions},
    io::{self, Write},
    path::{Path, PathBuf},
    str::FromStr,
    sync::{Arc, Mutex, OnceLock},
};

use chrono::{DateTime, Local, TimeZone};
use log::{Level, LevelFilter, Log, Metadata, Record};
use wallpaper_core::log_context;

use crate::{BridgeError, BridgeErrorKind, paths::BridgePaths};

const MAX_LOG_FILE_BYTES: u64 = 5 * 1024 * 1024;
/// Files kept per session: a session that runs for weeks keeps its newest
/// 50 MB rather than growing without bound.
const MAX_FILES_PER_SESSION: u64 = 10;
/// Earlier sessions kept at launch besides the new one, newest first, while
/// they fit in [`MAX_OLD_SESSION_BYTES`]. A report needs the last few
/// launches, not a history of every one.
const MAX_OLD_SESSIONS: usize = 9;
const MAX_OLD_SESSION_BYTES: u64 = 100 * 1024 * 1024;
/// Overrides the level for the process, whatever the verbose-logging setting.
const LEVEL_ENV: &str = "WALLPAPER_ENGINE_LOG_LEVEL";

static LOGGER_STATE: OnceLock<Arc<Mutex<LoggerState>>> = OnceLock::new();

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LogStatus {
    pub logs_root: PathBuf,
    pub active_session: String,
    pub active_file: PathBuf,
    pub active_file_size_bytes: u64,
}

pub struct ApplicationLogger {
    inner: Arc<Mutex<LoggerState>>,
}

struct LoggerState {
    logs_root: PathBuf,
    active_session: String,
    active_file_id: u64,
    active_file: PathBuf,
    active_file_size_bytes: u64,
    file: Option<File>,
}

/// Where one line came from; everything the formatted prefix needs.
struct LineOrigin<'a> {
    time: DateTime<Local>,
    level: Level,
    load: Option<u64>,
    file: Option<&'a str>,
    line: Option<u32>,
}

impl ApplicationLogger {
    /// # Errors
    ///
    /// Returns an error when the log session directory or initial file cannot
    /// be created.
    pub fn new(paths: &BridgePaths) -> Result<Self, BridgeError> {
        let logs_root = paths.logs_root();
        let state = LoggerState::new(logs_root)?;
        Ok(Self {
            inner: Arc::new(Mutex::new(state)),
        })
    }

    /// # Errors
    ///
    /// Returns an error when the log session cannot be initialized.
    pub fn install(paths: &BridgePaths) -> Result<(), BridgeError> {
        let logger = Self::new(paths)?;
        let inner = Arc::clone(&logger.inner);
        if LOGGER_STATE.set(inner).is_err() {
            return Ok(());
        }

        log::set_boxed_logger(Box::new(logger)).map_err(|error| BridgeError::Error {
            kind: BridgeErrorKind::Io,
            message: format!("failed to install application logger: {error}"),
        })?;

        let (level, source) = level_for(false);
        log::set_max_level(level);
        log::info!(
            "log session started: pid {}, level {level} ({source})",
            std::process::id()
        );
        Ok(())
    }

    /// Applies the persisted verbose-logging choice. `WALLPAPER_ENGINE_LOG_LEVEL`
    /// still wins when set, so a developer's override is not undone by the
    /// setting. Does nothing until the logger is installed, which keeps tests
    /// that build a bridge from changing the process-wide level.
    pub fn set_verbose(verbose: bool) {
        if LOGGER_STATE.get().is_none() {
            return;
        }
        let (level, source) = level_for(verbose);
        if level != log::max_level() {
            log::set_max_level(level);
            log::info!("log level {level} ({source})");
        }
    }

    /// Writes one line from the host UI, stamped with when the host produced
    /// it (Unix milliseconds) rather than when it arrived, so lines buffered
    /// before the bridge existed keep their time.
    pub fn emit_gui_log(
        level: Level,
        file: &str,
        line: u32,
        message: &str,
        load: Option<u64>,
        unix_millis: Option<i64>,
    ) {
        if level > log::max_level() {
            return;
        }
        let time = unix_millis
            .and_then(|millis| Local.timestamp_millis_opt(millis).single())
            .unwrap_or_else(Local::now);
        let origin = LineOrigin {
            time,
            level,
            load: load.or_else(log_context::current_load),
            file: Some(file),
            line: Some(line),
        };
        let line = format_record(&origin, &format_args!("{message}"));
        if let Some(inner) = LOGGER_STATE.get()
            && let Ok(mut state) = inner.lock()
        {
            state.write_line(level, &line);
        }
    }

    #[must_use]
    pub fn status() -> Option<LogStatus> {
        LOGGER_STATE
            .get()
            .and_then(|inner| inner.lock().ok().map(|state| state.status()))
    }

    #[must_use]
    pub fn logs_root() -> Option<PathBuf> {
        Self::status().map(|status| status.logs_root)
    }

    /// # Errors
    ///
    /// Returns an error when a new active log session cannot be created.
    pub fn clear() -> Result<LogStatus, BridgeError> {
        let inner = LOGGER_STATE.get().ok_or_else(|| BridgeError::Error {
            kind: BridgeErrorKind::Io,
            message: "application logger is not installed".to_string(),
        })?;
        let mut state = inner.lock().map_err(|_| BridgeError::Error {
            kind: BridgeErrorKind::Io,
            message: "application logger state is poisoned".to_string(),
        })?;
        state.clear()
    }

    #[cfg(test)]
    fn instance_status(&self) -> Option<LogStatus> {
        self.inner.lock().ok().map(|state| state.status())
    }

    #[cfg(test)]
    fn clear_instance(&self) -> Result<LogStatus, BridgeError> {
        self.inner
            .lock()
            .map_err(|_| BridgeError::Error {
                kind: BridgeErrorKind::Io,
                message: "application logger state is poisoned".to_string(),
            })?
            .clear()
    }

    #[cfg(test)]
    fn write_instance(&self, line: &str) {
        self.inner.lock().unwrap().write_line(Level::Info, line);
    }
}

impl Log for ApplicationLogger {
    fn enabled(&self, metadata: &Metadata<'_>) -> bool {
        metadata.level() <= Level::Trace
    }

    fn log(&self, record: &Record<'_>) {
        if !self.enabled(record.metadata()) {
            return;
        }

        let origin = LineOrigin {
            time: Local::now(),
            level: record.level(),
            load: log_context::current_load(),
            file: record.file(),
            line: record.line(),
        };
        let line = format_record(&origin, record.args());
        if let Ok(mut state) = self.inner.lock() {
            state.write_line(record.level(), &line);
        }
    }

    fn flush(&self) {}
}

/// The level in force and why: the environment override, else the setting.
fn level_for(verbose: bool) -> (LevelFilter, &'static str) {
    if let Some(level) = std::env::var(LEVEL_ENV)
        .ok()
        .and_then(|value| LevelFilter::from_str(&value).ok())
    {
        return (level, LEVEL_ENV);
    }
    if verbose {
        (LevelFilter::Debug, "verbose logging on")
    } else {
        (LevelFilter::Info, "default")
    }
}

/// `2026-09-27T15:02:11.482+08:00 ERROR [load#7] Parser.cpp:1061 message`.
/// Local time with its offset, so a line can be matched both to what the
/// user saw on their clock and to a crash report.
fn format_record(origin: &LineOrigin<'_>, args: &std::fmt::Arguments<'_>) -> String {
    let file = origin
        .file
        .and_then(|path| Path::new(path).file_name())
        .and_then(|name| name.to_str())
        .unwrap_or("unknown");
    let line = origin.line.unwrap_or(0);
    let time = origin.time.format("%Y-%m-%dT%H:%M:%S%.3f%:z");
    let level = origin.level;
    match origin.load {
        Some(load) => format!("{time} {level} [load#{load}] {file}:{line} {args}\n"),
        None => format!("{time} {level} {file}:{line} {args}\n"),
    }
}

impl LoggerState {
    #[allow(clippy::single_call_fn)]
    fn new(logs_root: PathBuf) -> Result<Self, BridgeError> {
        fs::create_dir_all(&logs_root).map_err(|error| BridgeError::Error {
            kind: BridgeErrorKind::Io,
            message: error.to_string(),
        })?;
        prune_old_sessions(&logs_root, MAX_OLD_SESSIONS, MAX_OLD_SESSION_BYTES);
        let active_session = unique_session_name(&logs_root);
        let session_root = logs_root.join(&active_session);
        fs::create_dir_all(&session_root).map_err(|error| BridgeError::Error {
            kind: BridgeErrorKind::Io,
            message: error.to_string(),
        })?;
        let active_file = session_root.join("0.log");
        let file = open_log_file(&active_file).map_err(|error| BridgeError::Error {
            kind: BridgeErrorKind::Io,
            message: error.to_string(),
        })?;
        let active_file_size_bytes = file.metadata().map_or(0, |metadata| metadata.len());

        Ok(Self {
            logs_root,
            active_session,
            active_file_id: 0,
            active_file,
            active_file_size_bytes,
            file: Some(file),
        })
    }

    fn status(&self) -> LogStatus {
        LogStatus {
            logs_root: self.logs_root.clone(),
            active_session: self.active_session.clone(),
            active_file: self.active_file.clone(),
            active_file_size_bytes: self.active_file_size_bytes,
        }
    }

    fn clear(&mut self) -> Result<LogStatus, BridgeError> {
        let old_sessions = fs::read_dir(&self.logs_root)
            .map_err(|error| BridgeError::Error {
                kind: BridgeErrorKind::Io,
                message: error.to_string(),
            })?
            .filter_map(Result::ok)
            .map(|entry| entry.path())
            .collect::<Vec<_>>();

        let active_session = unique_session_name(&self.logs_root);
        let session_root = self.logs_root.join(&active_session);
        fs::create_dir_all(&session_root).map_err(|error| BridgeError::Error {
            kind: BridgeErrorKind::Io,
            message: error.to_string(),
        })?;
        let active_file = session_root.join("0.log");
        let file = open_log_file(&active_file).map_err(|error| BridgeError::Error {
            kind: BridgeErrorKind::Io,
            message: error.to_string(),
        })?;

        self.file = Some(file);
        self.active_session = active_session;
        self.active_file_id = 0;
        self.active_file = active_file;
        self.active_file_size_bytes = 0;

        for path in old_sessions {
            if path == session_root {
                continue;
            }
            let result = if path.is_dir() {
                fs::remove_dir_all(&path)
            } else {
                fs::remove_file(&path)
            };
            if let Err(error) = result {
                eprintln!("ERROR logging.rs:0 failed to remove old log path: {error}");
            }
        }

        Ok(self.status())
    }

    fn rotate(&mut self) -> io::Result<()> {
        self.active_file_id = self.active_file_id.saturating_add(1);
        let session_root = self.logs_root.join(&self.active_session);
        self.active_file = session_root.join(format!("{}.log", self.active_file_id));
        let file = open_log_file(&self.active_file)?;
        self.active_file_size_bytes = file.metadata().map_or(0, |metadata| metadata.len());
        self.file = Some(file);
        if let Some(expired) = self.active_file_id.checked_sub(MAX_FILES_PER_SESSION) {
            // Only ever the one file that just fell out of the window: the
            // ones before it went on earlier rotations.
            let _ = fs::remove_file(session_root.join(format!("{expired}.log")));
        }
        Ok(())
    }

    fn write_line(&mut self, level: Level, line: &str) {
        match level {
            Level::Error | Level::Warn => eprint!("{line}"),
            Level::Info | Level::Debug | Level::Trace => print!("{line}"),
        }

        if let Err(error) = self.write_line_to_file(line) {
            eprintln!("ERROR logging.rs:0 failed to persist log: {error}");
        }
    }

    fn write_line_to_file(&mut self, line: &str) -> io::Result<()> {
        let line_len = u64::try_from(line.len()).unwrap_or(u64::MAX);
        if self.active_file_size_bytes > 0
            && self.active_file_size_bytes.saturating_add(line_len) > MAX_LOG_FILE_BYTES
        {
            self.rotate()?;
        }

        if let Some(file) = &mut self.file {
            file.write_all(line.as_bytes())?;
            file.flush()?;
            self.active_file_size_bytes = self.active_file_size_bytes.saturating_add(line_len);
        }
        Ok(())
    }
}

/// Keeps the newest `keep` session directories, as long as together they fit
/// in `max_bytes`, and removes every older one. Session names are timestamps,
/// so name order is age order. Runs before the new session exists, so it can
/// never remove the one being written.
fn prune_old_sessions(logs_root: &Path, keep: usize, max_bytes: u64) {
    let Ok(entries) = fs::read_dir(logs_root) else {
        return;
    };
    let mut sessions = entries
        .filter_map(Result::ok)
        .filter(|entry| entry.file_type().is_ok_and(|kind| kind.is_dir()))
        .map(|entry| entry.path())
        .collect::<Vec<_>>();
    sessions.sort_by(|a, b| session_order(b).cmp(&session_order(a)));

    let mut kept_bytes = 0_u64;
    let mut full = false;
    for (index, session) in sessions.iter().enumerate() {
        let bytes = directory_bytes(session);
        full = full || index >= keep || kept_bytes.saturating_add(bytes) > max_bytes;
        if !full {
            kept_bytes = kept_bytes.saturating_add(bytes);
            continue;
        }
        if let Err(error) = fs::remove_dir_all(session) {
            eprintln!("ERROR logging.rs:0 failed to remove expired log session: {error}");
        }
    }
}

/// `20260927-150211-2` sorts after `20260927-150211` and before
/// `20260927-150211-10`: the base timestamp, then the numeric suffix.
fn session_order(path: &Path) -> (String, u64) {
    let name = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or_default();
    match name.rsplit_once('-') {
        Some((base, suffix)) if base.contains('-') => {
            (base.to_string(), suffix.parse().unwrap_or(0))
        }
        _ => (name.to_string(), 0),
    }
}

fn directory_bytes(path: &Path) -> u64 {
    fs::read_dir(path).map_or(0, |entries| {
        entries
            .filter_map(Result::ok)
            .filter_map(|entry| entry.metadata().ok())
            .filter(fs::Metadata::is_file)
            .map(|metadata| metadata.len())
            .sum()
    })
}

fn unique_session_name(logs_root: &Path) -> String {
    let base = chrono::Local::now().format("%Y%m%d-%H%M%S").to_string();
    if !logs_root.join(&base).exists() {
        return base;
    }

    for suffix in 1.. {
        let candidate = format!("{base}-{suffix}");
        if !logs_root.join(&candidate).exists() {
            return candidate;
        }
    }
    unreachable!("unbounded suffix loop must return");
}

fn open_log_file(path: &Path) -> io::Result<File> {
    OpenOptions::new().create(true).append(true).open(path)
}

#[cfg(test)]
mod tests {
    use std::{fs, path::Path};

    use chrono::{Local, TimeZone};
    use log::Level;

    use super::{
        ApplicationLogger, LineOrigin, MAX_FILES_PER_SESSION, MAX_LOG_FILE_BYTES,
        format_record, prune_old_sessions,
    };
    use crate::paths::BridgePaths;

    fn origin(load: Option<u64>) -> LineOrigin<'static> {
        LineOrigin {
            time: Local.with_ymd_and_hms(2026, 9, 27, 15, 2, 11).unwrap()
                + chrono::Duration::milliseconds(482),
            level: Level::Error,
            load,
            file: Some("/tmp/Parser.cpp"),
            line: Some(1061),
        }
    }

    #[test]
    fn lines_carry_local_time_with_offset_level_and_source() {
        let line = format_record(&origin(None), &format_args!("unknown tex {:?}", "x"));
        let offset = Local
            .with_ymd_and_hms(2026, 9, 27, 15, 2, 11)
            .unwrap()
            .format("%:z");
        assert_eq!(
            line,
            format!("2026-09-27T15:02:11.482{offset} ERROR Parser.cpp:1061 unknown tex \"x\"\n")
        );
    }

    #[test]
    fn lines_of_a_load_carry_its_number() {
        let line = format_record(&origin(Some(7)), &format_args!("scene backend: native_metal"));
        assert!(
            line.contains(" ERROR [load#7] Parser.cpp:1061 scene backend: native_metal\n"),
            "{line}"
        );
    }

    #[test]
    fn clear_switches_to_new_session_and_removes_old_sessions() {
        let root = tempfile::tempdir().unwrap();
        let paths = BridgePaths::for_home(root.path());
        let logger = ApplicationLogger::new(&paths).unwrap();
        let before = logger.instance_status().unwrap();
        let old = before.logs_root.join("old-session");
        fs::create_dir_all(&old).unwrap();
        fs::write(old.join("ignored.log"), b"old").unwrap();

        let after = logger.clear_instance().unwrap();

        assert_ne!(before.active_session, after.active_session);
        assert!(after.active_file.exists());
        assert_eq!(fs::read_dir(&after.logs_root).unwrap().count(), 1);
    }

    fn session(root: &Path, name: &str, bytes: usize) {
        fs::create_dir_all(root.join(name)).unwrap();
        fs::write(root.join(name).join("0.log"), vec![b'x'; bytes]).unwrap();
    }

    fn sessions(root: &Path) -> Vec<String> {
        let mut names = fs::read_dir(root)
            .unwrap()
            .map(|entry| entry.unwrap().file_name().into_string().unwrap())
            .collect::<Vec<_>>();
        names.sort();
        names
    }

    #[test]
    fn pruning_keeps_the_newest_sessions_by_count() {
        let root = tempfile::tempdir().unwrap();
        for name in ["20260101-000000", "20260102-000000", "20260102-000000-1", "20260102-000000-10", "20260103-000000"] {
            session(root.path(), name, 1);
        }

        prune_old_sessions(root.path(), 3, u64::MAX);

        assert_eq!(
            sessions(root.path()),
            ["20260102-000000-1", "20260102-000000-10", "20260103-000000"]
        );
    }

    #[test]
    fn pruning_stops_at_the_byte_budget_even_below_the_count() {
        let root = tempfile::tempdir().unwrap();
        session(root.path(), "20260101-000000", 10);
        session(root.path(), "20260102-000000", 60);
        session(root.path(), "20260103-000000", 50);

        prune_old_sessions(root.path(), 9, 100);

        assert_eq!(sessions(root.path()), ["20260103-000000"]);
    }

    #[test]
    fn a_long_session_keeps_only_its_newest_files() {
        let root = tempfile::tempdir().unwrap();
        let logger = ApplicationLogger::new(&BridgePaths::for_home(root.path())).unwrap();
        let status = logger.instance_status().unwrap();
        let chunk = "x".repeat(usize::try_from(MAX_LOG_FILE_BYTES).unwrap());
        let rotations = MAX_FILES_PER_SESSION + 2;
        for _ in 0..=rotations {
            logger.write_instance(&chunk);
        }

        let session = status.logs_root.join(&status.active_session);
        let mut files = fs::read_dir(&session)
            .unwrap()
            .map(|entry| entry.unwrap().file_name().into_string().unwrap())
            .collect::<Vec<_>>();
        files.sort_by_key(|name| name.trim_end_matches(".log").parse::<u64>().unwrap());
        let expected = (rotations - MAX_FILES_PER_SESSION + 1..=rotations)
            .map(|id| format!("{id}.log"))
            .collect::<Vec<_>>();
        assert_eq!(files, expected);
    }
}
