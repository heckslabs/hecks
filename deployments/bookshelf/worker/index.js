// Generated from bookshelf.bluebook
// Cloudflare Worker — commands as POST, queries as GET, D1 persistence

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type',
};

function json(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { 'Content-Type': 'application/json', ...CORS },
  });
}

function uuid() {
  return crypto.randomUUID();
}

function now() {
  return new Date().toISOString();
}

// Lifecycle transitions — from bookshelf.bluebook
const TRANSITIONS = {
  StartReading: { from: ['want_to_read'], to: 'reading' },
  FinishBook:   { from: ['reading'],      to: 'finished' },
  AbandonBook:  { from: ['reading'],      to: 'abandoned' },
  ReRead:       { from: ['finished'],     to: 'reading' },
};

export default {
  async fetch(request, env) {
    if (request.method === 'OPTIONS') {
      return new Response(null, { headers: CORS });
    }

    const url = new URL(request.url);
    const path = url.pathname;
    const db = env.DB;

    try {
      // --- Book commands (POST) ---

      if (path === '/api/books/add' && request.method === 'POST') {
        const body = await request.json();
        const id = uuid();
        await db.prepare(
          'INSERT INTO books (id, title, author, genre, pages, status) VALUES (?, ?, ?, ?, ?, ?)'
        ).bind(id, body.title, body.author, body.genre || null, body.pages || null, 'want_to_read').run();
        await recordEvent(db, 'Book', id, 'BookAdded', body);
        return json({ id, event: 'BookAdded' });
      }

      if (path === '/api/books/start-reading' && request.method === 'POST') {
        const body = await request.json();
        const result = await transitionBook(db, body.id, 'StartReading');
        return result;
      }

      if (path === '/api/books/finish' && request.method === 'POST') {
        const body = await request.json();
        const result = await transitionBook(db, body.id, 'FinishBook');
        if (body.rating) {
          await db.prepare('UPDATE books SET rating = ?, notes = ?, updated_at = ? WHERE id = ?')
            .bind(body.rating, body.notes || null, now(), body.id).run();
        }
        // Policy: CountFinished → IncrementProgress
        const currentYear = new Date().getFullYear();
        await db.prepare(
          'UPDATE reading_goals SET completed = completed + 1, updated_at = ? WHERE year = ?'
        ).bind(now(), currentYear).run();
        return result;
      }

      if (path === '/api/books/abandon' && request.method === 'POST') {
        const body = await request.json();
        if (body.notes) {
          await db.prepare('UPDATE books SET notes = ?, updated_at = ? WHERE id = ?')
            .bind(body.notes, now(), body.id).run();
        }
        return await transitionBook(db, body.id, 'AbandonBook');
      }

      if (path === '/api/books/reread' && request.method === 'POST') {
        const body = await request.json();
        return await transitionBook(db, body.id, 'ReRead');
      }

      // --- Book queries (GET) ---

      if (path === '/api/books' && request.method === 'GET') {
        const status = url.searchParams.get('status');
        let results;
        if (status) {
          results = await db.prepare('SELECT * FROM books WHERE status = ? ORDER BY updated_at DESC')
            .bind(status).all();
        } else {
          results = await db.prepare('SELECT * FROM books ORDER BY updated_at DESC').all();
        }
        return json(results.results);
      }

      if (path.startsWith('/api/books/') && request.method === 'GET') {
        const id = path.split('/').pop();
        const book = await db.prepare('SELECT * FROM books WHERE id = ?').bind(id).first();
        if (!book) return json({ error: 'Book not found' }, 404);
        return json(book);
      }

      // --- ReadingGoal commands (POST) ---

      if (path === '/api/goals/set' && request.method === 'POST') {
        const body = await request.json();
        const id = uuid();
        await db.prepare(
          'INSERT OR REPLACE INTO reading_goals (id, year, target, completed) VALUES (?, ?, ?, ?)'
        ).bind(id, body.year, body.target, 0).run();
        await recordEvent(db, 'ReadingGoal', id, 'GoalSet', body);
        return json({ id, event: 'GoalSet' });
      }

      // --- ReadingGoal queries (GET) ---

      if (path === '/api/goals' && request.method === 'GET') {
        const results = await db.prepare('SELECT * FROM reading_goals ORDER BY year DESC').all();
        return json(results.results);
      }

      // --- Events (GET) ---

      if (path === '/api/events' && request.method === 'GET') {
        const limit = url.searchParams.get('limit') || 50;
        const results = await db.prepare(
          'SELECT * FROM events ORDER BY created_at DESC LIMIT ?'
        ).bind(limit).all();
        return json(results.results);
      }

      return json({ error: 'Not found' }, 404);

    } catch (e) {
      return json({ error: e.message }, 500);
    }
  }
};

async function transitionBook(db, id, command) {
  const book = await db.prepare('SELECT * FROM books WHERE id = ?').bind(id).first();
  if (!book) return json({ error: 'Book not found' }, 404);

  const transition = TRANSITIONS[command];
  if (!transition.from.includes(book.status)) {
    return json({
      error: `Cannot ${command} — book is ${book.status}, must be ${transition.from.join(' or ')}`
    }, 422);
  }

  await db.prepare('UPDATE books SET status = ?, updated_at = ? WHERE id = ?')
    .bind(transition.to, now(), id).run();
  const eventName = command.replace(/([A-Z])/g, (m) => m).replace(/^./, (c) => c.toUpperCase());
  await recordEvent(db, 'Book', id, eventName, { from: book.status, to: transition.to });
  return json({ id, status: transition.to, event: eventName });
}

async function recordEvent(db, aggregateType, aggregateId, eventType, payload) {
  await db.prepare(
    'INSERT INTO events (id, aggregate_type, aggregate_id, event_type, payload, created_at) VALUES (?, ?, ?, ?, ?, ?)'
  ).bind(uuid(), aggregateType, aggregateId, eventType, JSON.stringify(payload), now()).run();
}
