/* SSC Intramurals 2026: Student-Facing Kiosk Portal (Invisible Shield Edition)
   Enterprise Hardened: Invisible Station Token Security, Strict Monotonic Tokens,
   Instant UI Button Disabling, and Atomic Row-Lock Concurrency Handling.
   Uses only Supabase publishable key; never expose a service_role key here.
*/
const SUPABASE_URL = 'https://iyxcdaojmwbwbgtmzbrv.supabase.co';
const SUPABASE_PUBLISHABLE_KEY = 'sb_publishable_yOmBBCTCB4Dq4ogoeqPbzQ_a-IYvt7j';
const TIME_ZONE = 'Asia/Manila';
const $ = (id) => document.getElementById(id);

// 1. Invisible Station Key Integration (Expects p_station_key in hardened Supabase RPCs)
const STATION_KEY = 'SSC-KIOSK-2026-STATION-AUTH-SECURE-KEY';

let db = null;
let selectedStudent = null;
let searchTimer = null;
let controls = null;
let busy = false;
let confirming = false;
let autoResetTimer = null;

// 2. Concurrency & Race Condition Fixes: Monotonic Sequence Counters & Abort Controllers
let searchSequence = 0;
let searchAbortController = null;
let stateSequence = 0;
let stateAbortController = null;

const ACTIONS = [
  { key: 'morning_time_in_at', action: 'morning_time_in', label: 'Morning Time-in', short: 'Morning In' },
  { key: 'morning_time_out_at', action: 'morning_time_out', label: 'Morning Time-out', short: 'Morning Out' },
  { key: 'afternoon_time_in_at', action: 'afternoon_time_in', label: 'Afternoon Time-in', short: 'Afternoon In' },
  { key: 'afternoon_time_out_at', action: 'afternoon_time_out', label: 'Afternoon Time-out', short: 'Afternoon Out' }
];

const safe = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({
  '&': '&amp;',
  '<': '&lt;',
  '>': '&gt;',
  '"': '&quot;',
  "'": '&#39;'
}[c]));

const initials = (n) => String(n || '').trim().split(/\s+/).slice(0, 2).map((x) => x[0] || '').join('').toUpperCase() || 'ST';

function showStudentConfirmModal(message) {
  return new Promise((resolve) => {
    const existing = document.getElementById('_studentConfirmModal');
    if (existing) existing.remove();
    const modal = document.createElement('div');
    modal.id = '_studentConfirmModal';
    modal.style.cssText = 'position:fixed;inset:0;background:rgba(0,0,0,.55);z-index:9999;display:flex;align-items:center;justify-content:center;padding:1rem';
    modal.innerHTML = `<div style="background:#fff;border-radius:12px;padding:1.5rem;max-width:380px;width:100%;box-shadow:0 8px 32px rgba(0,0,0,.2)">
      <p style="margin:0 0 1.25rem;white-space:pre-wrap;font-size:1rem">${safe(message)}</p>
      <div style="display:flex;gap:.75rem;justify-content:stretch">
        <button type="button" style="flex:1" class="button outline btn-cancel">Cancel</button>
        <button type="button" style="flex:1" class="button primary btn-confirm">Confirm</button>
      </div>
    </div>`;
    document.body.appendChild(modal);

    const cleanup = (result) => {
      window.removeEventListener('keydown', onKey);
      modal.remove();
      resolve(result);
    };

    const onKey = (e) => {
      if (e.key === 'Escape') cleanup(false);
    };
    window.addEventListener('keydown', onKey);

    modal.onclick = (e) => { if (e.target === modal) cleanup(false); };
    modal.querySelector('.btn-cancel').onclick = () => cleanup(false);
    modal.querySelector('.btn-confirm').onclick = () => cleanup(true);
  });
}

function maskStudentName(fullName) {
  const words = String(fullName || '').trim().split(/\s+/).filter(Boolean);
  if (!words.length) return '';
  return [words[0], ...words.slice(1).map((word) => {
    if (word.length <= 2 || /^(?:jr|sr)\.?$/i.test(word)) return word;
    return `${word[0]}**${word[word.length - 1]}`;
  })].join(' ');
}

function todayPHT() {
  const p = Object.fromEntries(new Intl.DateTimeFormat('en-CA', {
    timeZone: TIME_ZONE,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit'
  }).formatToParts(new Date()).filter((x) => x.type !== 'literal').map((x) => [x.type, x.value]));
  return `${p.year}-${p.month}-${p.day}`;
}

function dateLabel(d) {
  const [y, m, day] = d.split('-').map(Number);
  return new Intl.DateTimeFormat('en-PH', {
    timeZone: TIME_ZONE,
    month: 'long',
    day: 'numeric',
    year: 'numeric'
  }).format(new Date(Date.UTC(y, m - 1, day, 12)));
}

function timeLabel(v) {
  if (!v) return '';
  const d = new Date(v);
  return Number.isNaN(d.getTime()) ? '' : new Intl.DateTimeFormat('en-PH', {
    timeZone: TIME_ZONE,
    hour: 'numeric',
    minute: '2-digit',
    hour12: true
  }).format(d).replace(/\s+/g, ' ');
}

function setTodayLabel(text) {
  const el = $('todayLabel');
  if (!el) return;
  const span = el.querySelector('span');
  if (span) span.textContent = text;
  else el.textContent = text;
}

function toast(s) {
  const el = $('toast');
  if (!el) return;
  el.textContent = s;
  el.classList.add('show');
  setTimeout(() => el.classList.remove('show'), 3500);
}

function setStatusText() {
  const enabled = ACTIONS.filter((a) => controls?.[`enable_${a.action}`]);
  const open = enabled.length > 0;
  $('portalStatus').textContent = open ? `${enabled.length} check-in action${enabled.length === 1 ? '' : 's'} is now open` : 'Check-in is currently closed';
  $('portalHint').textContent = open ? 'Tap the action that matches your current session.' : 'Please wait for the SSC Officer to open check-in.';
  $('statusDot').classList.toggle('open', open);
  $('statusDot').classList.toggle('closed', !open);
  $('actionStatus').innerHTML = open ? enabled.map((a) => `<div class="status-chip enabled">${safe(a.short)}<br>OPEN</div>`).join('') : '<div class="empty-state">No check-in actions are open right now.</div>';
}

async function refreshControls() {
  if (!db || busy) return;
  const { data, error } = await db.rpc('get_public_attendance_controls');
  if (error) {
    $('portalStatus').textContent = 'Could not check attendance status';
    $('portalHint').textContent = 'Please check your internet connection and tap Refresh.';
    console.error('Error fetching public attendance controls:', error);
    return;
  }
  controls = data || {};
  setStatusText();
  if (selectedStudent) await loadStudentState();
}

function renderSearchResults(rows) {
  const el = $('searchResults');
  if (!rows?.length) {
    el.innerHTML = '<div class="empty-state">No matching names found. Please check your spelling and try again.</div>';
    return;
  }

  el.innerHTML = rows.map((p) => `<button class="result-button" type="button" data-student-id="${safe(p.id)}"><span class="avatar">${safe(initials(p.full_name))}</span><span class="result-info"><strong>${safe(maskStudentName(p.full_name))}</strong></span><span class="result-arrow">›</span></button>`).join('');

  el.querySelectorAll('[data-student-id]').forEach((btn) => {
    btn.addEventListener('click', () => {
      // Instant UI lockout: prevent multi-clicks while confirmation modal prepares
      if (confirming || busy) return;
      btn.disabled = true;
      const targetStudent = rows.find((x) => x.id === btn.dataset.studentId);
      selectStudent(targetStudent);
    });
  });
}

// 1 & 2. HARDENED SEARCH: STRICT MONOTONIC SEQUENCE & INVISIBLE STATION KEY
async function searchStudents() {
  const q = $('studentSearch').value.trim();
  if (q.length < 3) {
    if (searchAbortController) {
      searchAbortController.abort();
      searchAbortController = null;
    }
    searchSequence++;
    $('searchResults').innerHTML = '<div class="empty-state">Type at least 3 letters of your name.</div>';
    return;
  }
  if (!db) return;

  // 1. Cancel previous in-flight HTTP search
  if (searchAbortController) {
    searchAbortController.abort();
  }
  searchAbortController = new AbortController();

  // 2. Strict Monotonically Increasing Sequence Token
  const currentSeq = ++searchSequence;

  $('searchResults').innerHTML = '<div class="empty-state">Searching…</div>';
  try {
    let queryBuilder = db.rpc('search_active_students', {
      p_query: q,
      p_station_key: STATION_KEY
    });
    if (typeof queryBuilder.abortSignal === 'function') {
      queryBuilder = queryBuilder.abortSignal(searchAbortController.signal);
    }
    const { data, error } = await queryBuilder;

    // Stale response guard: discard if user typed more or triggered a newer search
    if (currentSeq !== searchSequence) return;

    if (error) {
      if (error.code === '42901' || /rate limit/i.test(error.message)) {
        $('searchResults').innerHTML = '<div class="empty-state">Please wait a few seconds before searching again.</div>';
        toast('Please wait a moment before searching again.');
        return;
      }
      $('searchResults').innerHTML = '<div class="empty-state">Search is temporarily unavailable. Please try again.</div>';
      console.error('Search RPC error:', error);
      return;
    }

    renderSearchResults(data || []);
  } catch (err) {
    if (err.name === 'AbortError' || currentSeq !== searchSequence) return;
    $('searchResults').innerHTML = '<div class="empty-state">Connection took too long. Please try again.</div>';
  }
}

function resetStudent() {
  if (busy) return;
  clearTimeout(autoResetTimer);
  if (stateAbortController) {
    stateAbortController.abort();
    stateAbortController = null;
  }
  stateSequence++;
  $('selectedPanel').classList.add('hidden');
  selectedStudent = null;
  if ($('studentSearch')) {
    $('studentSearch').disabled = false;
    $('studentSearch').value = '';
  }
  $('searchResults').innerHTML = '<div class="empty-state">Start typing your name to search.</div>';
  if ($('studentSearch')) $('studentSearch').focus();
}

async function selectStudent(p) {
  if (!p || busy || confirming) return;
  confirming = true;
  try {
    clearTimeout(autoResetTimer);
    const isConfirmed = await showStudentConfirmModal(`Is this your name?\n\n${p.full_name}\n\nTap Confirm if YES, or Cancel if NO.`);
    if (!isConfirmed) return;
    selectedStudent = p;
    $('selectedPanel').classList.remove('hidden');
    $('studentAvatar').textContent = initials(p.full_name);
    $('selectedName').textContent = p.full_name;
    $('selectedMeta').textContent = `${p.position ? `${p.position} · ` : ''}${p.department || 'Department not listed'}${p.year_level ? ` · Year ${p.year_level}` : ''}`;
    $('studentMessage').textContent = '';
    $('selectedPanel').scrollIntoView({ behavior: 'smooth', block: 'nearest' });
    await loadStudentState();
  } finally {
    confirming = false;
    // Re-enable search result buttons if student canceled modal
    $('searchResults').querySelectorAll('.result-button').forEach((b) => { b.disabled = false; });
  }
}

// HYDRATE STUDENT ATTENDANCE STATE WITH SEQUENCE GUARD
async function loadStudentState() {
  if (!db || !selectedStudent) return;
  const targetStudentId = selectedStudent.id;

  // Cancel prior in-flight state request
  if (stateAbortController) {
    stateAbortController.abort();
  }
  stateAbortController = new AbortController();
  const currentSeq = ++stateSequence;

  try {
    let stateQuery = db.rpc('get_student_attendance_state', {
      p_participant_id: targetStudentId,
      p_station_key: STATION_KEY
    });
    if (typeof stateQuery.abortSignal === 'function') {
      stateQuery = stateQuery.abortSignal(stateAbortController.signal);
    }
    const { data, error } = await stateQuery;

    // Stale response guard: discard if student has switched or newer request completed
    if (currentSeq !== stateSequence || !selectedStudent || selectedStudent.id !== targetStudentId) return;

    if (error) {
      $('studentActions').innerHTML = '<div class="empty-state">Could not load check-in buttons. Please tap Refresh.</div>';
      console.error('get_student_attendance_state error:', error);
      return;
    }

    const state = data || {};
    controls = state.controls || controls || {};
    setStatusText();
    const row = state.attendance || {};

    $('studentActions').innerHTML = ACTIONS.map((a) => {
      const enabled = !!controls?.[`enable_${a.action}`];
      const recorded = row[a.key];
      if (!enabled) return '';
      if (recorded) {
        return `<article class="action-card"><div class="action-title">${safe(a.label)}</div><div class="action-detail">Already recorded today</div><div class="recorded-pill">✓ ${safe(timeLabel(recorded))} PHT</div></article>`;
      }
      return `<article class="action-card enabled"><div class="action-title">${safe(a.label)}</div><div class="action-detail">Open now · Philippine Time</div><button class="button action-button" type="button" data-action="${a.action}">Save ${safe(a.label)} →</button></article>`;
    }).join('') || '<div class="empty-state">No check-in actions are open right now. Please wait for an SSC officer to open one.</div>';

    // Bind Click Events
    $('studentActions').querySelectorAll('[data-action]').forEach((btn) => {
      btn.addEventListener('click', () => {
        if (busy) return;
        recordAction(btn.dataset.action, btn);
      });
    });
  } catch (err) {
    if (err.name === 'AbortError' || currentSeq !== stateSequence) return;
    $('studentActions').innerHTML = '<div class="empty-state">Connection problem. Please tap Refresh.</div>';
  }
}

// 2. HARDENED TRANSACTIONAL ACTION RECORDING: MILLISECOND BUTTON LOCKING & STEALTH KEY
async function recordAction(action, button) {
  if (busy || !selectedStudent) return;
  busy = true;
  clearTimeout(autoResetTimer);
  const originalText = button.textContent;

  // HARD MILLISECOND LOCK: Instantly disable the clicked button AND the 'Change' button
  button.disabled = true;
  if ($('changeStudent')) $('changeStudent').disabled = true;

  // Lock sibling action buttons and inputs to prevent switching students mid-flight
  const allActionBtns = $('studentActions').querySelectorAll('button');
  allActionBtns.forEach((b) => { b.disabled = true; });
  if ($('studentSearch')) $('studentSearch').disabled = true;
  if ($('refreshStatus')) $('refreshStatus').disabled = true;

  button.textContent = 'Saving…';
  $('studentMessage').textContent = 'Saving your attendance, please wait…';

  try {
    const eventId = crypto.randomUUID ? crypto.randomUUID() : null;
    const { data, error } = await db.rpc('student_record_attendance_action', {
      p_participant_id: selectedStudent.id,
      p_action: action,
      p_station_key: STATION_KEY,
      p_event_id: eventId
    });

    if (error) {
      if (error.code === '42901' || /rate limit/i.test(error.message)) {
        throw new Error('Please wait a few moments before trying again.');
      }
      throw error;
    }

    const actionInfo = ACTIONS.find((a) => a.action === action);
    const actionLabel = actionInfo ? actionInfo.label : action;

    // Structured JSON Response from Upgraded Atomic Row-Locking RPC
    if (data && typeof data === 'object') {
      if (!data.success) {
        throw new Error(data.error || 'Attendance could not be recorded.');
      }
      const recordedTime = timeLabel(data.recorded_at);
      if (data.already_recorded) {
        $('studentMessage').innerHTML = `<span class="notice-badge warning">✓ Already Recorded</span> ${safe(selectedStudent.full_name)}: Your ${safe(actionLabel)} was already recorded at ${safe(recordedTime)} PHT.`;
        toast('Already recorded today.');
      } else {
        $('studentMessage').innerHTML = `<span class="notice-badge success">✓ Saved</span> ${safe(selectedStudent.full_name)}: Your ${safe(actionLabel)} was saved at ${safe(recordedTime)} PHT.`;
        toast('Attendance saved!');
      }
    } else {
      // Fallback for scalar timestamp
      const recordedTime = timeLabel(data);
      $('studentMessage').innerHTML = `<span class="notice-badge success">✓ Saved</span> ${safe(selectedStudent.full_name)}: Your ${safe(actionLabel)} was saved at ${safe(recordedTime)} PHT.`;
      toast('Attendance saved!');
    }

    await loadStudentState();
    autoResetTimer = setTimeout(() => {
      if (selectedStudent && !busy) {
        resetStudent();
        toast('Ready for next student.');
      }
    }, 5000);
  } catch (e) {
    console.error('Attendance recording error:', e);
    const friendlyMsg = e.message || 'Attendance could not be recorded. Please try again.';
    $('studentMessage').innerHTML = `<span class="notice-badge error">✕ Notice</span> ${safe(friendlyMsg)}`;
    toast(friendlyMsg);
    allActionBtns.forEach((b) => { b.disabled = false; });
    if (document.contains(button)) {
      button.disabled = false;
      button.textContent = originalText;
    }
  } finally {
    // Unlock interface once the Supabase promise has resolved
    busy = false;
    if ($('changeStudent')) $('changeStudent').disabled = false;
    if ($('studentSearch')) $('studentSearch').disabled = false;
    if ($('refreshStatus')) $('refreshStatus').disabled = false;
  }
}

function updateNetworkBadge() {
  const badge = $('networkBadge');
  const dot = $('networkDot');
  const label = $('networkLabel');
  if (!badge || !dot || !label) return;
  const online = navigator.onLine;
  label.textContent = online ? 'Online' : 'Offline';
  label.style.color = online ? '#34d399' : '#f87171';
  dot.style.background = online ? '#10b981' : '#ef4444';
  dot.style.boxShadow = online ? '0 0 10px #10b981' : '0 0 10px #ef4444';
  badge.style.borderColor = online ? 'rgba(16,185,129,0.35)' : 'rgba(239,68,68,0.35)';
  badge.style.background = online ? 'rgba(16,185,129,0.12)' : 'rgba(239,68,68,0.12)';
  badge.style.boxShadow = online ? '0 0 16px rgba(16,185,129,0.15)' : '0 0 16px rgba(239,68,68,0.15)';
}

window.addEventListener('online', updateNetworkBadge);
window.addEventListener('offline', updateNetworkBadge);

async function init() {
  updateNetworkBadge();
  setTodayLabel(`Philippine Time · ${dateLabel(todayPHT())}`);

  if ('serviceWorker' in navigator) {
    navigator.serviceWorker.register('./service-worker.js').catch((err) => console.warn('Kiosk service worker registration:', err));
  }

  if (!window.supabase) {
    $('portalStatus').textContent = 'Cannot connect to attendance service';
    $('portalHint').textContent = 'Please make sure you are connected to the internet and refresh.';
    return;
  }

  db = window.supabase.createClient(SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, {
    auth: {
      persistSession: false,
      autoRefreshToken: false,
      detectSessionInUrl: false
    }
  });

  $('studentSearch').addEventListener('input', () => {
    clearTimeout(searchTimer);
    searchTimer = setTimeout(searchStudents, 250);
  });

  $('clearSearch').addEventListener('click', () => {
    if (searchAbortController) {
      searchAbortController.abort();
      searchAbortController = null;
    }
    searchSequence++;
    $('studentSearch').value = '';
    $('searchResults').innerHTML = '<div class="empty-state">Start typing your name to search.</div>';
  });

  $('changeStudent').addEventListener('click', resetStudent);
  $('refreshStatus').addEventListener('click', refreshControls);

  await refreshControls();

  if (db.channel) {
    db.channel('public-attendance-controls')
      .on('postgres_changes', { event: '*', schema: 'public', table: 'attendance_day_settings' }, () => refreshControls())
      .subscribe();
  }

  window.addEventListener('focus', refreshControls);
  setInterval(refreshControls, 15000);
}

document.addEventListener('DOMContentLoaded', init);
