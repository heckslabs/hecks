-- Generated from bookshelf.bluebook
-- Aggregate: Book → table: books
-- Aggregate: ReadingGoal → table: reading_goals

CREATE TABLE IF NOT EXISTS books (
  id TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  author TEXT NOT NULL,
  genre TEXT CHECK(genre IN ('fiction', 'nonfiction', 'technical', 'poetry', 'biography')),
  pages INTEGER,
  rating INTEGER CHECK(rating IS NULL OR (rating >= 1 AND rating <= 5)),
  notes TEXT,
  status TEXT NOT NULL DEFAULT 'want_to_read' CHECK(status IN ('want_to_read', 'reading', 'finished', 'abandoned')),
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS reading_goals (
  id TEXT PRIMARY KEY,
  year INTEGER NOT NULL,
  target INTEGER NOT NULL,
  completed INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS events (
  id TEXT PRIMARY KEY,
  aggregate_type TEXT NOT NULL,
  aggregate_id TEXT NOT NULL,
  event_type TEXT NOT NULL,
  payload TEXT,
  created_at TEXT NOT NULL DEFAULT (datetime('now'))
);
