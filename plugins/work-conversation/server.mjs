import { createReadStream, existsSync, readdirSync, readFileSync, realpathSync, statSync } from 'node:fs';
import { createInterface } from 'node:readline';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const configuredRoot = process.env.CODEX_CONVERSATION_ROOT || process.env.CODEX_HOME;
if (!configuredRoot) throw new Error('Set CODEX_HOME or CODEX_CONVERSATION_ROOT to the Codex data directory');
const root = resolve(configuredRoot);
const uuid = /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i;
const clamp = (n, fallback, max) => Number.isInteger(n) ? Math.max(1, Math.min(n, max)) : fallback;
const parse = line => { try { return JSON.parse(line); } catch { return null; } };
const fault = (message, code = -32602) => Object.assign(new Error(message), { code });

function indexRoot() {
  const sessions = join(root, 'sessions');
  const archived = join(root, 'archived_sessions');
  if (!existsSync(sessions) || !existsSync(archived)) return root;
  const sessionRoot = dirname(realpathSync(sessions));
  const archivedRoot = dirname(realpathSync(archived));
  return sessionRoot.toLowerCase() === archivedRoot.toLowerCase() ? sessionRoot : root;
}

function titleIndex() {
  const path = join(indexRoot(), 'session_index.jsonl');
  const result = new Map();
  if (!existsSync(path)) return result;
  for (const line of readFileSync(path, 'utf8').split(/\r?\n/)) {
    const item = parse(line);
    if (uuid.test(item?.id) && typeof item.thread_name === 'string')
      result.set(item.id.toLowerCase(), { title: item.thread_name.slice(0, 180), updatedAt: item.updated_at || null });
  }
  return result;
}

function walk(dir) {
  if (!existsSync(dir)) return [];
  const result = [];
  const pending = [dir];
  while (pending.length) {
    const current = pending.pop();
    for (const entry of readdirSync(current, { withFileTypes: true })) {
      if (entry.isSymbolicLink()) continue;
      const path = join(current, entry.name);
      if (entry.isDirectory()) pending.push(path);
      else if (entry.isFile() && entry.name.endsWith('.jsonl')) result.push(path);
    }
  }
  return result;
}

async function firstLine(path) {
  const stream = createReadStream(path, { encoding: 'utf8' });
  const lines = createInterface({ input: stream, crlfDelay: Infinity });
  try {
    for await (const line of lines) return parse(line);
    return null;
  } finally {
    lines.close();
    stream.destroy();
  }
}

async function catalog() {
  const names = titleIndex();
  const result = new Map();
  for (const [dir, archived] of [['sessions', false], ['archived_sessions', true]]) {
    for (const path of walk(join(root, dir))) {
      const first = await firstLine(path);
      const id = first?.payload?.id;
      if (!uuid.test(id)) continue;
      if (!['user', 'chatgpt_handoff', 'voice_chat'].includes(first?.payload?.thread_source)) continue;
      const key = id.toLowerCase();
      const stat = statSync(path);
      const info = names.get(key);
      const row = result.get(key) || { threadId: id, title: info?.title || '(未命名任务)',
        updatedAt: null, archived: true, files: [], mtime: 0 };
      row.files.push({ path, startedAt: first.timestamp || '', mtime: stat.mtimeMs });
      row.archived = row.archived && archived;
      row.mtime = Math.max(row.mtime, stat.mtimeMs);
      result.set(key, row);
    }
  }
  for (const row of result.values()) {
    row.files.sort((a, b) => a.startedAt.localeCompare(b.startedAt) || a.path.localeCompare(b.path));
    row.updatedAt = new Date(row.mtime).toISOString();
  }
  return [...result.values()].sort((a, b) => b.mtime - a.mtime);
}

const publicRow = ({ threadId, title, updatedAt, archived }) => ({ threadId, title, updatedAt, archived });

function titleQuery(value) {
  return value.toLocaleLowerCase()
    .replace(/(?:请|帮我|一下|继续|读取|查找|查一下|搜索|工作会话|工作任务|会话|任务|work|codex)/gu, ' ')
    .trim();
}

function titleMatches(rows, rawQuery) {
  const query = titleQuery(rawQuery);
  if (!query) return [];
  const terms = query.match(/[a-z0-9]+|[\p{Script=Han}]+/gu) || [];
  const compact = query.replace(/[^a-z0-9\p{Script=Han}]/gu, '');
  return rows.map(row => {
    const title = row.title.toLocaleLowerCase();
    const flatTitle = title.replace(/[^a-z0-9\p{Script=Han}]/gu, '');
    const hits = terms.filter(term => title.includes(term));
    const exact = title.includes(rawQuery.trim().toLocaleLowerCase());
    const phrase = compact.length >= 2 && flatTitle.includes(compact);
    const score = exact ? 3 : phrase ? 2 : hits.length === terms.length ? 1 : 0;
    return { row, score };
  }).filter(item => item.score > 0)
    .sort((a, b) => b.score - a.score || b.row.mtime - a.row.mtime);
}

async function messages(files) {
  const found = [];
  for (const { path } of files) {
    const stream = createReadStream(path, { encoding: 'utf8' });
    const lines = createInterface({ input: stream, crlfDelay: Infinity });
    for await (const line of lines) {
      const row = parse(line);
      const item = row?.type === 'response_item' ? row.payload : null;
      if (item?.type !== 'message' || !['user', 'assistant'].includes(item.role)) continue;
      if (item.role === 'assistant' && item.phase && !['final_answer', 'commentary'].includes(item.phase)) continue;
      const text = (Array.isArray(item.content) ? item.content : [])
        .filter(part => ['input_text', 'output_text', 'text'].includes(part?.type))
        .map(part => part.text || '').join('\n').trim();
      if (text) found.push({ role: item.role, phase: item.role === 'assistant' ? item.phase || null : null,
        text: text.slice(0, 2000), timestamp: row.timestamp || null });
    }
  }
  return found;
}

async function lastMessageMatch(files, query) {
  let hit = null;
  for (const { path } of files) {
    const stream = createReadStream(path, { encoding: 'utf8' });
    const lines = createInterface({ input: stream, crlfDelay: Infinity });
    for await (const line of lines) {
      if (!line.toLocaleLowerCase().includes(query)) continue;
      const row = parse(line);
      const item = row?.type === 'response_item' ? row.payload : null;
      if (item?.type !== 'message' || !['user', 'assistant'].includes(item.role)) continue;
      if (item.role === 'assistant' && item.phase && !['final_answer', 'commentary'].includes(item.phase)) continue;
      const text = (Array.isArray(item.content) ? item.content : [])
        .filter(part => ['input_text', 'output_text', 'text'].includes(part?.type))
        .map(part => part.text || '').join('\n');
      const at = text.toLocaleLowerCase().indexOf(query);
      if (at >= 0) hit = { role: item.role, timestamp: row.timestamp || null,
        snippet: text.slice(Math.max(0, at - 100), at + query.length + 200) };
    }
  }
  return hit;
}

const result = value => ({ content: [{ type: 'text', text: JSON.stringify(value) }], structuredContent: value });
const readOnly = { readOnlyHint: true, destructiveHint: false };
const tools = [
  { name: 'list_work_threads', description: 'List recent local Codex tasks by title and date.',
    inputSchema: { type: 'object', properties: { limit: { type: 'integer', minimum: 1, maximum: 50 } }, additionalProperties: false }, annotations: readOnly },
  { name: 'search_work_threads', description: 'Find local Codex tasks by approximate title. Natural requests containing a topic keyword can match titles containing that keyword. If needsSelection is true, show the candidate titles and dates and ask the user which task to read before calling read_work_thread.',
    inputSchema: { type: 'object', properties: { query: { type: 'string', minLength: 1 }, limit: { type: 'integer', minimum: 1, maximum: 50 } }, required: ['query'], additionalProperties: false }, annotations: readOnly },
  { name: 'search_work_messages', description: 'Find local Codex tasks containing a phrase in user or assistant conversation text; returns short excerpts.',
    inputSchema: { type: 'object', properties: { query: { type: 'string', minLength: 2 }, limit: { type: 'integer', minimum: 1, maximum: 20 } }, required: ['query'], additionalProperties: false }, annotations: readOnly },
  { name: 'read_work_thread', description: 'Read user and assistant messages from one local Codex task. For “继续读取工作会话”, “继续读取…”, or “读取上一个工作会话”, reuse the task already selected in this chat. “上一个” means the most recently selected/read task here, not the newest task on disk. If several targets remain plausible, ask which one. Pass nextCursor to continue toward older messages; otherwise read the latest messages for new work.',
    inputSchema: { type: 'object', properties: { threadId: { type: 'string' }, cursor: { type: 'integer', minimum: 0 }, messageLimit: { type: 'integer', minimum: 1, maximum: 20 } }, required: ['threadId'], additionalProperties: false }, annotations: readOnly },
];

export async function handle({ method, params = {} }) {
  if (method === 'initialize') return { protocolVersion: '2024-11-05', capabilities: { tools: {} },
    serverInfo: { name: 'work-conversation', version: '0.1.0' } };
  if (method === 'ping') return {};
  if (method === 'tools/list') return { tools };
  if (method !== 'tools/call') throw fault('Unsupported method', -32601);
  const { name, arguments: args = {} } = params;
  if (name === 'list_work_threads' || name === 'search_work_threads') {
    if (name === 'search_work_threads' && (typeof args.query !== 'string' || !args.query.trim()))
      throw fault('query is required');
    const rows = await catalog();
    if (name === 'list_work_threads')
      return result({ items: rows.slice(0, clamp(args.limit, 10, 50)).map(publicRow) });
    const matches = titleMatches(rows, args.query);
    const items = matches.slice(0, clamp(args.limit, 10, 50))
      .map(({ row, score }) => ({ ...publicRow(row), matchLevel: score === 3 ? 'exact' : score === 2 ? 'phrase' : 'keywords' }));
    return result({ items, needsSelection: matches.length > 1 });
  }
  if (name === 'search_work_messages') {
    if (typeof args.query !== 'string' || args.query.trim().length < 2) throw fault('query must contain at least 2 characters');
    const query = args.query.trim().toLocaleLowerCase();
    const limit = clamp(args.limit, 10, 20);
    const items = [];
    for (const row of await catalog()) {
      const match = await lastMessageMatch(row.files, query);
      if (match) items.push({ thread: publicRow(row), ...match });
      if (items.length >= limit) break;
    }
    return result({ items });
  }
  if (name === 'read_work_thread') {
    if (typeof args.threadId !== 'string' || !uuid.test(args.threadId)) throw fault('Invalid threadId');
    const offset = Number.isInteger(args.cursor) && args.cursor >= 0 ? args.cursor : 0;
    const limit = clamp(args.messageLimit, 10, 20);
    const row = (await catalog()).find(item => item.threadId.toLowerCase() === args.threadId.toLowerCase());
    if (!row) throw fault('Task not found');
    const all = await messages(row.files);
    const end = Math.max(0, all.length - offset);
    const start = Math.max(0, end - limit);
    return result({ thread: publicRow(row), messages: all.slice(start, end),
      nextCursor: start > 0 ? offset + end - start : null, totalMessages: all.length });
  }
  throw fault('Unknown tool', -32601);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const input = createInterface({ input: process.stdin, crlfDelay: Infinity });
  let queue = Promise.resolve();
  input.on('line', line => {
    queue = queue.then(async () => {
      let request;
      try {
        request = JSON.parse(line);
        if (request.id === undefined) return;
        const response = await handle(request);
        process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id: request.id, result: response }) + '\n');
      } catch (error) {
        process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id: request?.id ?? null,
          error: { code: error.code || -32603, message: error.message || 'Request failed' } }) + '\n');
      }
    });
  });
}
