//! Adds the games of PGN files to an En Croissant database (`.db3`),
//! creating it if needed: the same tables, move encoding (each move is its
//! index in shakmaty's legal move list, with comments, NAGs and variations
//! in between), material and pawn columns as En Croissant's own PGN import
//! (src-tauri/src/db/mod.rs, `convert_pgn`, v0.15.1), which this follows
//! closely (En Croissant is GPL-3.0, and so is this tool). Used by
//! scripts/ec-sync.py for the games played against zchess.
//!
//! usage: ec-db <database.db3> --title <title> [--description <text>] <games.pgn>...

use pgn_reader::{BufferedReader, Nag, RawComment, RawHeader, SanPlus, Skip, Visitor};
use rusqlite::{params, Connection};
use shakmaty::{
    fen::Fen, Board, ByColor, CastlingMode, Chess, FromSetup, Move, Piece, Position,
    PositionError,
};
use std::{fs::File, path::PathBuf, process::ExitCode};

const DATABASE_VERSION: &str = "1.0.0";

const VARIATION_START_MARKER: u8 = 255;
const VARIATION_END_MARKER: u8 = 254;
const COMMENT_MARKER: u8 = 253;
const NAG_MARKER: u8 = 252;

// En Croissant's own SQL (src-tauri/src/db/create.sql and indexes.sql, v0.15.1).
const CREATE_TABLES_SQL: &str = include_str!("create.sql");
const INDEXES_SQL: &str = include_str!("indexes.sql");

fn encode_move(m: &Move, chess: &Chess) -> u8 {
    let moves = chess.legal_moves();
    moves.iter().position(|x| x == m).unwrap() as u8
}

fn encode_text(marker: u8, text: &str, output: &mut Vec<u8>) {
    for chunk in text.as_bytes().chunks(u16::MAX as usize) {
        output.push(marker);
        output.extend_from_slice(&(chunk.len() as u16).to_le_bytes());
        output.extend_from_slice(chunk);
    }
}

/// Mainline moves in an encoded game (skips variations, comments and NAGs).
fn mainline_ply_count(bytes: &[u8]) -> i32 {
    let (mut i, mut depth, mut n) = (0, 0usize, 0);
    while i < bytes.len() {
        let b = bytes[i];
        i += 1;
        match b {
            VARIATION_START_MARKER => depth += 1,
            VARIATION_END_MARKER => depth = depth.saturating_sub(1),
            COMMENT_MARKER | NAG_MARKER => {
                if i + 2 > bytes.len() {
                    break;
                }
                let len = u16::from_le_bytes([bytes[i], bytes[i + 1]]) as usize;
                i = (i + 2 + len).min(bytes.len());
            }
            _ if depth == 0 => n += 1,
            _ => {}
        }
    }
    n
}

fn get_material_count(board: &Board) -> ByColor<u8> {
    board.material().map(|material| {
        material.pawn + material.knight * 3 + material.bishop * 3 + material.rook * 5 + material.queen * 9
    })
}

/// The pawns on the second and seventh ranks, as bits.
fn get_pawn_home(board: &Board) -> u16 {
    let white_pawns = board.by_piece(Piece::from_char('P').unwrap());
    let black_pawns = board.by_piece(Piece::from_char('p').unwrap());
    let second_rank_pawns = (white_pawns.0 >> 8) as u8;
    let seventh_rank_pawns = (black_pawns.0 >> 48) as u8;
    (second_rank_pawns as u16) | ((seventh_rank_pawns as u16) << 8)
}

struct TempGame {
    event_name: Option<String>,
    site_name: Option<String>,
    date: Option<String>,
    time: Option<String>,
    round: Option<String>,
    white_name: Option<String>,
    white_elo: Option<i32>,
    black_name: Option<String>,
    black_elo: Option<i32>,
    result: Option<String>,
    time_control: Option<String>,
    eco: Option<String>,
    fen: Option<String>,
    moves: Vec<u8>,
    position: Chess,
    /// The least material each side had before a promotion (39 = all).
    material_count: ByColor<u8>,
}

impl Default for TempGame {
    fn default() -> Self {
        TempGame {
            event_name: None,
            site_name: None,
            date: None,
            time: None,
            round: None,
            white_name: None,
            white_elo: None,
            black_name: None,
            black_elo: None,
            result: None,
            time_control: None,
            eco: None,
            fen: None,
            moves: Vec::new(),
            position: Chess::default(),
            material_count: ByColor { white: 39, black: 39 },
        }
    }
}

fn named_id(db: &Connection, table: &str, name: &str) -> rusqlite::Result<i64> {
    db.execute(&format!("INSERT OR IGNORE INTO {table} (Name) VALUES (?1)"), params![name])?;
    db.query_row(&format!("SELECT ID FROM {table} WHERE Name = ?1"), params![name], |r| r.get(0))
}

impl TempGame {
    fn insert(&self, db: &Connection) -> rusqlite::Result<()> {
        let id = |table: &str, name: &Option<String>| match name {
            Some(n) => named_id(db, table, n),
            None => Ok(0),
        };
        let white_id = id("Players", &self.white_name)?;
        let black_id = id("Players", &self.black_name)?;
        let event_id = id("Events", &self.event_name)?;
        let site_id = id("Sites", &self.site_name)?;
        let final_material = get_material_count(self.position.board());
        db.execute(
            "INSERT OR IGNORE INTO Games (EventID, SiteID, Date, UTCTime, Round, WhiteID, WhiteElo, BlackID, BlackElo,
                WhiteMaterial, BlackMaterial, Result, TimeControl, ECO, PlyCount, FEN, Moves, PawnHome)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18)",
            params![
                event_id,
                site_id,
                self.date,
                self.time,
                self.round,
                white_id,
                self.white_elo,
                black_id,
                self.black_elo,
                self.material_count.white.min(final_material.white) as i32,
                self.material_count.black.min(final_material.black) as i32,
                self.result,
                self.time_control,
                self.eco,
                mainline_ply_count(&self.moves),
                self.fen,
                self.moves,
                get_pawn_home(self.position.board()) as i32,
            ],
        )?;
        Ok(())
    }
}

struct ImportFrame {
    position: Chess,
    pre_move_positions: Vec<Chess>,
}

impl ImportFrame {
    fn new(position: Chess) -> Self {
        Self { position, pre_move_positions: Vec::new() }
    }
}

#[derive(Default)]
struct Importer {
    game: TempGame,
    skip: bool,
    frames: Vec<ImportFrame>,
}

impl Visitor for Importer {
    type Result = Option<TempGame>;

    fn begin_game(&mut self) {
        self.game = TempGame::default();
        self.skip = false;
        self.frames.clear();
    }

    fn header(&mut self, key: &[u8], value: RawHeader<'_>) {
        let text = || Some(value.decode_utf8_lossy().into_owned());
        let elo = || if value.as_bytes() == b"-" { Some(0) } else { btoi::btoi(value.as_bytes()).ok() };
        match key {
            b"White" => self.game.white_name = text(),
            b"Black" => self.game.black_name = text(),
            b"WhiteElo" => self.game.white_elo = elo(),
            b"BlackElo" => self.game.black_elo = elo(),
            b"TimeControl" => self.game.time_control = text(),
            b"ECO" => self.game.eco = text(),
            b"Round" => self.game.round = text(),
            b"Date" | b"UTCDate" => self.game.date = text(),
            b"UTCTime" => self.game.time = text(),
            b"Site" => self.game.site_name = text(),
            b"Event" => self.game.event_name = text(),
            b"Result" => self.game.result = text(),
            b"FEN" => {
                if value.as_bytes() == b"rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1" {
                    self.game.fen = None;
                } else if let Ok(fen) = Fen::from_ascii(value.as_bytes()) {
                    self.game.fen = text();
                    let setup = fen.into_setup();
                    let castling_mode = CastlingMode::detect(&setup);
                    match Chess::from_setup(setup, castling_mode).or_else(PositionError::ignore_too_much_material) {
                        Ok(p) => self.game.position = p,
                        Err(_) => self.skip = true,
                    }
                } else {
                    self.skip = true;
                }
            }
            _ => {}
        }
    }

    fn end_headers(&mut self) -> Skip {
        self.frames.clear();
        self.frames.push(ImportFrame::new(self.game.position.clone()));
        Skip(self.skip)
    }

    fn san(&mut self, san: SanPlus) {
        if self.frames.is_empty() {
            self.frames.push(ImportFrame::new(self.game.position.clone()));
        }
        let is_mainline = self.frames.len() == 1;
        let frame = self.frames.last_mut().unwrap();
        let pre_move_position = frame.position.clone();
        match san.san.to_move(&frame.position) {
            Ok(m) => {
                if is_mainline && m.is_promotion() {
                    let cur = get_material_count(frame.position.board());
                    let mc = &mut self.game.material_count;
                    mc.white = mc.white.min(cur.white);
                    mc.black = mc.black.min(cur.black);
                }
                self.game.moves.push(encode_move(&m, &frame.position));
                frame.pre_move_positions.push(pre_move_position);
                frame.position.play_unchecked(&m);
                if is_mainline {
                    self.game.position = frame.position.clone();
                }
            }
            Err(_) => self.skip = true,
        }
    }

    fn begin_variation(&mut self) -> Skip {
        if self.frames.is_empty() {
            self.frames.push(ImportFrame::new(self.game.position.clone()));
        }
        let parent = self.frames.last().unwrap();
        let start = parent.pre_move_positions.last().cloned().unwrap_or_else(|| parent.position.clone());
        self.game.moves.push(VARIATION_START_MARKER);
        self.frames.push(ImportFrame::new(start));
        Skip(false)
    }

    fn end_variation(&mut self) {
        self.game.moves.push(VARIATION_END_MARKER);
        if self.frames.len() > 1 {
            self.frames.pop();
        } else {
            self.skip = true;
        }
        if let Some(root) = self.frames.first() {
            self.game.position = root.position.clone();
        }
    }

    fn comment(&mut self, comment: RawComment<'_>) {
        encode_text(COMMENT_MARKER, &String::from_utf8_lossy(comment.as_bytes()), &mut self.game.moves);
    }

    fn nag(&mut self, nag: Nag) {
        encode_text(NAG_MARKER, &nag.to_string(), &mut self.game.moves);
    }

    fn end_game(&mut self) -> Self::Result {
        self.frames.clear();
        let game = std::mem::take(&mut self.game);
        if self.skip { None } else { Some(game) }
    }
}

fn run() -> Result<usize, Box<dyn std::error::Error>> {
    let mut args = std::env::args().skip(1);
    let mut db_path: Option<PathBuf> = None;
    let (mut title, mut description) = (String::new(), String::new());
    let mut files = Vec::new();
    while let Some(a) = args.next() {
        match a.as_str() {
            "--title" => title = args.next().ok_or("--title needs a value")?,
            "--description" => description = args.next().ok_or("--description needs a value")?,
            _ if db_path.is_none() => db_path = Some(a.into()),
            _ => files.push(PathBuf::from(a)),
        }
    }
    let db_path = db_path.ok_or("usage: ec-db <database.db3> --title <title> [--description <text>] <games.pgn>...")?;

    let exists = db_path.exists();
    let mut db = Connection::open(&db_path)?;
    db.busy_timeout(std::time::Duration::from_secs(10))?;
    if !exists {
        db.execute_batch(CREATE_TABLES_SQL)?;
        for (k, v) in [("Version", DATABASE_VERSION), ("Title", &title), ("Description", &description)] {
            db.execute("INSERT INTO Info (Name, Value) VALUES (?1, ?2)", params![k, v])?;
        }
    }

    let tx = db.transaction()?;
    let mut imported = 0;
    for path in &files {
        let mut importer = Importer::default();
        for game in BufferedReader::new(File::open(path)?).into_iter(&mut importer) {
            if let Some(g) = game? {
                g.insert(&tx)?;
                imported += 1;
            }
        }
    }
    tx.commit()?;
    if !exists {
        db.execute_batch(INDEXES_SQL)?;
    }
    for (name, table) in [("GameCount", "Games"), ("PlayerCount", "Players"), ("EventCount", "Events"), ("SiteCount", "Sites")] {
        let n: i64 = db.query_row(&format!("SELECT COUNT(*) FROM {table}"), [], |r| r.get(0))?;
        db.execute(
            "INSERT INTO Info (Name, Value) VALUES (?1, ?2) ON CONFLICT(Name) DO UPDATE SET Value = excluded.Value",
            params![name, n.to_string()],
        )?;
    }
    Ok(imported)
}

fn main() -> ExitCode {
    match run() {
        Ok(n) => {
            println!("{n}");
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("ec-db: {e}");
            ExitCode::FAILURE
        }
    }
}
