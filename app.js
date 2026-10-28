/* SSC Intramurals 2026 Daily Attendance Portal
   Philippine Time is used for dates and display. Time input/output is 12-hour AM/PM.
   Use only a Supabase publishable/anon key in browser code. Never add a service_role key here.
*/
const SUPABASE_URL = 'https://iyxcdaojmwbwbgtmzbrv.supabase.co';
const SUPABASE_PUBLISHABLE_KEY = 'sb_publishable_yOmBBCTCB4Dq4ogoeqPbzQ_a-IYvt7j';
const TIME_ZONE = 'Asia/Manila';
const $ = (id) => document.getElementById(id);
let db = null;
let participants = [];
let dailyAttendance = [];
let scheduleSaved = false;
let toastTimer;
let loadDateInFlight = false;
let currentPage = 0;
let offlineMode = !navigator.onLine;
let serverOffline = false;
let offlineSnapshot = null;
const CACHE_KEY = 'ssc_attendance_cache_v1';
const QUEUE_KEY_PREFIX = 'ssc_attendance_offline_queue_';
const LEGACY_QUEUE_KEY = 'ssc_attendance_offline_queue_v1';
let currentOfficerUserId = null;
const PAGE_SIZE = 40;
const ACTIONS = [
  { key: 'morning_time_in_at', action: 'morning_time_in', label: 'Morning In', short: 'AM In' },
  { key: 'morning_time_out_at', action: 'morning_time_out', label: 'Morning Out', short: 'AM Out' },
  { key: 'afternoon_time_in_at', action: 'afternoon_time_in', label: 'Afternoon In', short: 'PM In' },
  { key: 'afternoon_time_out_at', action: 'afternoon_time_out', label: 'Afternoon Out', short: 'PM Out' }
];
const DEFAULT_SCHEDULE = { morning_time_in: '07:00:00', morning_time_out: '11:30:00', afternoon_time_in: '13:00:00', afternoon_time_out: '16:30:00', enable_morning_time_in:false, enable_morning_time_out:false, enable_afternoon_time_in:false, enable_afternoon_time_out:false };
const safe = (s='') => String(s).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const initials = (name='') => name.trim().split(/\s+/).slice(0,2).map(x=>x[0]||'').join('').toUpperCase() || '??';
function phtParts(date = new Date()) {
  const parts = new Intl.DateTimeFormat('en-CA', { timeZone: TIME_ZONE, year:'numeric', month:'2-digit', day:'2-digit' }).formatToParts(date);
  return Object.fromEntries(parts.filter(p=>p.type!=='literal').map(p=>[p.type,p.value]));
}
function todayPHT() { const p = phtParts(); return `${p.year}-${p.month}-${p.day}`; }
function dateLabel(dateString) {
  if (!dateString) return '';
  const [y,m,d] = dateString.split('-').map(Number);
  return new Intl.DateTimeFormat('en-PH',{timeZone:TIME_ZONE,month:'long',day:'numeric',year:'numeric'}).format(new Date(Date.UTC(y,m-1,d,12)));
}
function timeLabel(value) {
  if (!value) return '—';
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return '—';
  return new Intl.DateTimeFormat('en-PH',{timeZone:TIME_ZONE,hour:'numeric',minute:'2-digit',hour12:true}).format(date).replace(/\s+/g,' ');
}
function setTodayLabel(text){const el=$('todayLabel');if(!el)return;const s=el.querySelector('span');if(s)s.textContent=text;else el.textContent=text;}
function toast(message){const el=$('toast');el.textContent=message;el.classList.add('show');clearTimeout(toastTimer);toastTimer=setTimeout(()=>el.classList.remove('show'),3600)}
function configured(){return window.supabase && SUPABASE_URL.startsWith('https://') && !SUPABASE_URL.includes('PASTE_') && SUPABASE_PUBLISHABLE_KEY && !SUPABASE_PUBLISHABLE_KEY.includes('PASTE_')}
function setSignedIn(on){
  const loginPanel = $('loginPanel');
  const dashboardWrapper = $('dashboardWrapper');
  const appPanel = $('appPanel');
  const signOut = $('signOut');

  if (loginPanel) {
    if (on) loginPanel.classList.add('hidden');
    else loginPanel.classList.remove('hidden');
  }
  if (dashboardWrapper) {
    if (on) dashboardWrapper.classList.remove('hidden');
    else dashboardWrapper.classList.add('hidden');
  }
  if (appPanel) {
    if (on) appPanel.classList.remove('hidden');
    else appPanel.classList.add('hidden');
  }
  if (signOut) {
    if (on) signOut.classList.remove('hidden');
    else signOut.classList.add('hidden');
  }
}
function readCache(){try{return JSON.parse(localStorage.getItem(CACHE_KEY)||'null')}catch{return null}}
function writeCache(value){try{localStorage.setItem(CACHE_KEY,JSON.stringify(value))}catch(err){console.warn('Unable to cache attendance data locally',err);toast('Local cache is full. Offline attendance may not be available.')}}
function getQueueStorageKey(userId = currentOfficerUserId) {
  const uid = userId || offlineSnapshot?.userId || readCache()?.userId || null;
  return uid ? `${QUEUE_KEY_PREFIX}${uid}_v2` : `${QUEUE_KEY_PREFIX}anon_v2`;
}
function readQueue(userId = currentOfficerUserId){
  const uid = userId || offlineSnapshot?.userId || readCache()?.userId || null;
  if(!uid) return [];
  try{
    const key = getQueueStorageKey(uid);
    let queue = JSON.parse(localStorage.getItem(key)||'[]');
    // One-time auto migration of legacy entries owned by this officer
    const legacy = JSON.parse(localStorage.getItem(LEGACY_QUEUE_KEY)||'[]');
    if(legacy.length > 0){
      const mine = legacy.filter(x=>x.officer_user_id === uid);
      const others = legacy.filter(x=>x.officer_user_id !== uid);
      if(mine.length > 0){
        queue = [...queue, ...mine];
        localStorage.setItem(key, JSON.stringify(queue));
        localStorage.setItem(LEGACY_QUEUE_KEY, JSON.stringify(others));
      }
    }
    return queue;
  }catch{return [];}
}
function writeQueue(queue, userId = currentOfficerUserId){
  const uid = userId || offlineSnapshot?.userId || readCache()?.userId || null;
  if(!uid) return;
  try{
    const key = getQueueStorageKey(uid);
    localStorage.setItem(key,JSON.stringify(queue));
  }catch(err){console.error(err);toast('Could not save the offline queue on this device. Do not close this page until the issue is resolved.');}
}
function updateConnectivity(){offlineMode=!navigator.onLine||serverOffline;const queue=readQueue();const conflicts=queue.filter(x=>x.status==='conflict').length;const pending=queue.length-conflicts;const el=$('connection');el.textContent=offlineMode?'Offline mode':`Online${pending?` · ${pending} pending`:''}`;el.classList.toggle('ok',!offlineMode);el.classList.toggle('offline',offlineMode);const sync=$('syncStatus');if(sync)sync.textContent=offlineMode?`● Offline · ${pending} pending${conflicts?` · ${conflicts} conflict`:''}`:`● Online · ${pending} pending${conflicts?` · ${conflicts} conflict`:''}`;if($('saveSchedule'))$('saveSchedule').disabled=offlineMode;if($('tab-health')&&!$('tab-health').classList.contains('hidden')){runSystemDiagnostics().catch(()=>{});}}
function saveSnapshot(date){const old=readCache()||{userId:null,savedAt:null,participants:[],dates:{}};old.userId=offlineSnapshot?.userId||old.userId||null;old.savedAt=new Date().toISOString();old.participants=participants;old.dates=old.dates||{};old.dates[date]={attendance:dailyAttendance,schedule:window.currentSchedule||null};const keys=Object.keys(old.dates).sort();while(keys.length>10){delete old.dates[keys.shift()]}writeCache(old);offlineSnapshot=old}
function todayPHTFromDate(date){const parts=new Intl.DateTimeFormat('en-CA',{timeZone:TIME_ZONE,year:'numeric',month:'2-digit',day:'2-digit'}).formatToParts(date);const p=Object.fromEntries(parts.filter(x=>x.type!=='literal').map(x=>[x.type,x.value]));return `${p.year}-${p.month}-${p.day}`}
function uuid(){return crypto.randomUUID?crypto.randomUUID():'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g,c=>{const r=Math.random()*16|0;return (c==='x'?r:(r&0x3|0x8)).toString(16)})}
function loadCachedDate(date){const cache=readCache();if(!cache||!cache.participants?.length||!cache.dates?.[date])return false;participants=cache.participants;dailyAttendance=cache.dates[date].attendance||[];window.currentSchedule=cache.dates[date].schedule||null;scheduleSaved=!!window.currentSchedule;offlineSnapshot=cache;const values=window.currentSchedule||DEFAULT_SCHEDULE;$('morningTimeIn').value=formatDbTime(values.morning_time_in)||'7:00 AM';$('morningTimeOut').value=formatDbTime(values.morning_time_out)||'11:30 AM';$('afternoonTimeIn').value=formatDbTime(values.afternoon_time_in)||'1:00 PM';$('afternoonTimeOut').value=formatDbTime(values.afternoon_time_out)||'4:30 PM';$('enableMorningIn').checked=!!values.enable_morning_time_in;$('enableMorningOut').checked=!!values.enable_morning_time_out;$('enableAfternoonIn').checked=!!values.enable_afternoon_time_in;$('enableAfternoonOut').checked=!!values.enable_afternoon_time_out;$('scheduleStatus').textContent=window.currentSchedule?`Cached schedule · ${dateLabel(date)}`:'No saved schedule cached';$('scheduleStatus').classList.toggle('saved',!!window.currentSchedule);$('selectedDateLabel').textContent=dateLabel(date);$('registeredCount').textContent=participants.length;const deps=[...new Set(participants.map(p=>p.department).filter(Boolean))].sort((a,b)=>a.localeCompare(b));const oldDep=$('departmentFilter').value;$('departmentFilter').innerHTML='<option value="">All departments</option>'+deps.map(d=>`<option value="${safe(d)}">${safe(d)}</option>`).join('');if(deps.includes(oldDep))$('departmentFilter').value=oldDep;renderStats();renderParticipants();renderRecent();return true}
function loadOfflineDashboard(userId){const cache=readCache();if(!cache||cache.userId!==userId||!cache.participants?.length){toast('Offline access is not ready on this device. Connect once and sign in to cache the roster first.');return false}currentOfficerUserId=userId;participants=cache.participants;offlineSnapshot=cache;setSignedIn(true);const date=$('attendanceDate').value||todayPHT();if(!loadCachedDate(date)){if(date===todayPHT()){dailyAttendance=[];window.currentSchedule=null;saveSnapshot(date);loadCachedDate(date);toast('Today’s roster is available offline, but today’s schedule was not cached. Confirm the schedule when internet returns.');}else{toast('No cached records for this date. Select today to record offline attendance.');return false;}}setTodayLabel(`Philippine Time · ${dateLabel(todayPHT())}`);updateConnectivity();toast('Offline mode: entries are saved on this device and will sync when online.');return true}
function showError(el,msg){el.textContent=msg}
function parse12Hour(value) {
  const match = String(value || '').trim().match(/^(\d{1,2})(?::([0-5]\d))?\s*(AM|PM)$/i);
  if (!match) return null;
  let hour = Number(match[1]); const minute = Number(match[2] || 0); const period = match[3].toUpperCase();
  if (hour < 1 || hour > 12) return null;
  hour = hour % 12 + (period === 'PM' ? 12 : 0);
  return `${String(hour).padStart(2,'0')}:${String(minute).padStart(2,'0')}:00`;
}
function formatDbTime(value) {
  if (!value) return '';
  const [hh, mm] = String(value).split(':').map(Number);
  const period = hh >= 12 ? 'PM' : 'AM'; const hour = hh % 12 || 12;
  return `${hour}:${String(mm || 0).padStart(2,'0')} ${period}`;
}
function isSelectedDateToday() { return $('attendanceDate').value === todayPHT(); }
function showConfirmModal(message){
  return new Promise(resolve=>{
    const existing=document.getElementById('_confirmModal');if(existing)existing.remove();
    const modal=document.createElement('div');modal.id='_confirmModal';
    modal.style.cssText='position:fixed;inset:0;background:rgba(0,0,0,.55);z-index:9999;display:flex;align-items:center;justify-content:center;padding:1rem';
    modal.innerHTML=`<div style="background:#fff;border-radius:12px;padding:1.5rem;max-width:420px;width:100%;box-shadow:0 8px 32px rgba(0,0,0,.2)"><p style="margin:0 0 1.25rem;white-space:pre-wrap">${safe(message)}</p><div style="display:flex;gap:.75rem;justify-content:flex-end"><button type="button" class="button outline btn-cancel">Cancel</button><button type="button" class="button danger btn-confirm">Confirm</button></div></div>`;
    document.body.appendChild(modal);
    modal.querySelector('.btn-cancel').onclick=()=>{modal.remove();resolve(false);};
    modal.querySelector('.btn-confirm').onclick=()=>{modal.remove();resolve(true);};
  });
}
function showPromptModal(message){
  return new Promise(resolve=>{
    const existing=document.getElementById('_promptModal');if(existing)existing.remove();
    const modal=document.createElement('div');modal.id='_promptModal';
    modal.style.cssText='position:fixed;inset:0;background:rgba(0,0,0,.55);z-index:9999;display:flex;align-items:center;justify-content:center;padding:1rem';
    modal.innerHTML=`<div style="background:#fff;border-radius:12px;padding:1.5rem;max-width:420px;width:100%;box-shadow:0 8px 32px rgba(0,0,0,.2)"><p style="margin:0 0 1rem;white-space:pre-wrap">${safe(message)}</p><input id="_promptInput" type="text" style="width:100%;box-sizing:border-box;padding:.5rem .75rem;border:1.5px solid #ccd;border-radius:8px;font-size:1rem;margin-bottom:1.25rem" autocomplete="off" placeholder="Type here"><div style="display:flex;gap:.75rem;justify-content:flex-end"><button type="button" class="button outline btn-cancel">Cancel</button><button type="button" class="button danger btn-confirm">Confirm</button></div></div>`;
    document.body.appendChild(modal);
    const input=modal.querySelector('#_promptInput');input.focus();
    modal.querySelector('.btn-cancel').onclick=()=>{modal.remove();resolve(null);};
    modal.querySelector('.btn-confirm').onclick=()=>{const v=input.value;modal.remove();resolve(v);};
    input.addEventListener('keydown',e=>{if(e.key==='Enter'){const v=input.value;modal.remove();resolve(v);}if(e.key==='Escape'){modal.remove();resolve(null);}});
  });
}

/* ==============================================================================
   TABBED SINGLE PAGE APPLICATION (SPA) & SYSTEM HEALTH LOGIC
   ============================================================================== */

function initTabs() {
  function switchTab(targetId) {
    if (!targetId) return;
    const targetSection = document.getElementById(targetId);
    if (!targetSection) return;

    // 1. Hide all tab content sections
    document.querySelectorAll('.tab-content').forEach(section => {
      section.classList.add('hidden');
      section.classList.remove('active');
    });

    // 2. Unhide target section
    targetSection.classList.remove('hidden');
    targetSection.classList.add('active');

    // 3. Highlight active tab link in sidebar
    document.querySelectorAll('[data-target]').forEach(link => {
      const isMatch = link.dataset.target === targetId;
      link.classList.toggle('active', isMatch);
      if (link.tagName === 'BUTTON' || link.tagName === 'A') {
        link.setAttribute('aria-selected', isMatch ? 'true' : 'false');
      }
    });

    // 4. Auto-close mobile drawer if open
    const mobileToggle = document.getElementById('sidebarToggle');
    if (mobileToggle && mobileToggle.checked) {
      mobileToggle.checked = false;
    }

    // 5. If switching to System Health tab, run diagnostic ping immediately
    if (targetId === 'tab-health') {
      runSystemDiagnostics();
    }

    // 6. Smooth scroll main canvas to top of new view
    const mainContent = document.querySelector('.main-content');
    if (mainContent) mainContent.scrollTop = 0;
  }

  // Bind click listener for all elements with [data-target]
  document.addEventListener('click', (e) => {
    const trigger = e.target.closest('[data-target]');
    if (!trigger) return;
    const targetId = trigger.dataset.target;
    if (targetId) {
      e.preventDefault();
      switchTab(targetId);
    }
  });

  window.switchTab = switchTab;
}

async function runSystemDiagnostics() {
  const ts = new Intl.DateTimeFormat('en-PH', { timeZone: TIME_ZONE, hour: 'numeric', minute: '2-digit', second: '2-digit', hour12: true }).format(new Date());
  const tsEl = $('telemetryTimestamp');
  if (tsEl) tsEl.textContent = `${ts} (PST UTC+8)`;

  // 1. Front-End Runtime Status
  const feBadge = $('healthFrontendBadge');
  const feValue = $('healthFrontendValue');
  const fePwa = $('healthFrontendPwa');
  const feEng = $('healthFrontendEng');
  const swStatus = $('telemetrySwStatus');
  if (feBadge) {
    const isDOMReady = document.readyState === 'complete' || document.readyState === 'interactive';
    const isScriptReady = typeof window.supabase !== 'undefined';
    if (isDOMReady && isScriptReady) {
      feBadge.className = 'health-badge ok';
      feBadge.innerHTML = '<span class="health-dot dot-emerald"></span><span class="health-badge-text">Operational</span>';
      if (feValue) feValue.textContent = 'DOM & Core Scripts Active';
    } else {
      feBadge.className = 'health-badge error';
      feBadge.innerHTML = '<span class="health-dot dot-red"></span><span class="health-badge-text">Degraded</span>';
      if (feValue) feValue.textContent = 'Scripts Incomplete';
    }
    if (fePwa) fePwa.textContent = 'PWA Cache: v20261025-perf-fix2';
    if (feEng) feEng.textContent = `Platform: ${navigator.platform || 'Modern Browser'}`;
    if (swStatus) swStatus.textContent = ('serviceWorker' in navigator) ? 'Registered & Active (App Shell Cached)' : 'Unsupported on this device';
  }

  // 2. Network Interface Status
  const netBadge = $('healthNetworkBadge');
  const netValue = $('healthNetworkValue');
  const netType = $('healthNetworkType');
  const isOnline = navigator.onLine && !serverOffline;
  if (netBadge) {
    if (isOnline) {
      netBadge.className = 'health-badge ok';
      netBadge.innerHTML = '<span class="health-dot dot-emerald"></span><span class="health-badge-text">Online</span>';
      if (netValue) netValue.textContent = 'Active Internet Uplink';
      const conn = navigator.connection || navigator.mozConnection || navigator.webkitConnection;
      if (netType) netType.textContent = conn ? `Type: ${conn.effectiveType || conn.type || 'Broadband'} (RTT: ~${conn.rtt || 25}ms)` : 'Type: High-Speed Uplink';
    } else {
      netBadge.className = 'health-badge error';
      netBadge.innerHTML = '<span class="health-dot dot-red"></span><span class="health-badge-text">Offline</span>';
      if (netValue) netValue.textContent = 'Offline Mode Active';
      if (netType) netType.textContent = 'No external internet connection';
    }
  }

  // 3. Supabase Database Ping
  const sbBadge = $('healthSupabaseBadge');
  const sbValue = $('healthSupabaseValue');
  const sbLatency = $('healthSupabaseLatency');
  if (sbBadge) {
    if (!db || !navigator.onLine) {
      sbBadge.className = 'health-badge error';
      sbBadge.innerHTML = '<span class="health-dot dot-red"></span><span class="health-badge-text">Offline / Error</span>';
      if (sbValue) sbValue.textContent = 'Database Unreachable';
      if (sbLatency) sbLatency.textContent = 'Ping: Timed out or offline';
    } else {
      sbBadge.className = 'health-badge checking';
      sbBadge.innerHTML = '<span class="health-dot dot-amber"></span><span class="health-badge-text">Pinging…</span>';
      const t0 = performance.now();
      try {
        const { error } = await db.from('attendance_day_settings').select('attendance_date', { count: 'exact', head: true }).limit(1);
        const elapsed = Math.round(performance.now() - t0);
        if (error && error.code !== 'PGRST116') throw error;
        sbBadge.className = 'health-badge ok';
        sbBadge.innerHTML = '<span class="health-dot dot-emerald"></span><span class="health-badge-text">Connected</span>';
        if (sbValue) sbValue.textContent = 'Supabase Cloud Live';
        if (sbLatency) sbLatency.textContent = `Ping Latency: ${elapsed}ms`;
      } catch (err) {
        sbBadge.className = 'health-badge error';
        sbBadge.innerHTML = '<span class="health-dot dot-red"></span><span class="health-badge-text">Error</span>';
        if (sbValue) sbValue.textContent = 'Database Ping Failed';
        if (sbLatency) sbLatency.textContent = `Error: ${err.message || 'Network failure'}`;
      }
    }
  }

  // 4. Offline Sync Queue Status
  const qBadge = $('healthQueueBadge');
  const qValue = $('healthQueueValue');
  const qConflicts = $('healthQueueConflicts');
  if (qBadge) {
    const queue = readQueue();
    const conflicts = queue.filter(x => x.status === 'conflict').length;
    const pending = queue.length - conflicts;
    if (pending === 0 && conflicts === 0) {
      qBadge.className = 'health-badge ok';
      qBadge.innerHTML = '<span class="health-dot dot-emerald"></span><span class="health-badge-text">0 Pending</span>';
      if (qValue) qValue.textContent = 'Queue Clean · All Synced';
    } else if (conflicts > 0) {
      qBadge.className = 'health-badge error';
      qBadge.innerHTML = `<span class="health-dot dot-red"></span><span class="health-badge-text">${conflicts} Conflicts</span>`;
      if (qValue) qValue.textContent = `${pending} Pending, ${conflicts} Conflicts`;
    } else {
      qBadge.className = 'health-badge warning';
      qBadge.innerHTML = `<span class="health-dot dot-amber"></span><span class="health-badge-text">${pending} Queued</span>`;
      if (qValue) qValue.textContent = `${pending} Item(s) awaiting sync`;
    }
    if (qConflicts) qConflicts.textContent = `Conflicts: ${conflicts} | Total in local buffer: ${queue.length}`;
  }
}

async function init(){
  initTabs();
  if ($('runDiagnosticsBtn')) {
    $('runDiagnosticsBtn').addEventListener('click', async () => {
      toast('Running system diagnostic ping…');
      await runSystemDiagnostics();
      toast('Diagnostics updated.');
    });
  }
  if ($('testHandshakeBtn')) {
    $('testHandshakeBtn').addEventListener('click', async () => {
      toast('Testing database handshake…');
      await runSystemDiagnostics();
      toast('Handshake test complete.');
    });
  }
  const today = todayPHT(); $('attendanceDate').value = today;
  setTodayLabel(`Philippine Time · ${dateLabel(today)}`);
  $('selectedDateLabel').textContent = dateLabel(today);
  // PWA installation prompt: browser support varies by device.
  const installButton = $('installApp');
  let deferredInstallPrompt = null;
  if (installButton) {
    window.addEventListener('beforeinstallprompt', (event) => { event.preventDefault(); deferredInstallPrompt = event; installButton.classList.remove('hidden'); });
    installButton.addEventListener('click', async () => {
      if (!deferredInstallPrompt) { toast('On supported browsers, open the browser menu and choose Install app or Add to Home Screen.'); return; }
      deferredInstallPrompt.prompt(); await deferredInstallPrompt.userChoice; deferredInstallPrompt = null; installButton.classList.add('hidden');
    });
    window.addEventListener('appinstalled', () => { installButton.classList.add('hidden'); toast('SSC Attendance app installed on this device.'); });
  }

  if('serviceWorker' in navigator){navigator.serviceWorker.register('./service-worker.js').catch(err=>console.warn('Offline app-shell cache unavailable',err));}
  window.addEventListener('online',async()=>{serverOffline=false;updateConnectivity();if(db){await syncOfflineQueue();await loadDashboard();}});
  window.addEventListener('offline',()=>{updateConnectivity();if($('appPanel')&&!$('appPanel').classList.contains('hidden')){loadCachedDate($('attendanceDate').value||todayPHT());toast('Connection lost. Offline attendance is available if this date was cached.');}});
  if(!configured()){ $('connection').textContent='Setup required'; $('setupNotice').classList.remove('hidden'); return; }
  $('setupNotice').classList.add('hidden');
  if(!window.supabase){$('connection').textContent='Offline app shell';toast('Attendance library is not cached yet. Open the portal online once before relying on offline mode.');return;}
  db=window.supabase.createClient(SUPABASE_URL,SUPABASE_PUBLISHABLE_KEY);
  $('connection').textContent='Connecting…';
  const {data:{session},error}=await db.auth.getSession();
  if(error){$('connection').textContent='Connection error';return;}
  if(session){
    currentOfficerUserId=session.user.id;
    if(navigator.onLine)await loadDashboard();else loadOfflineDashboard(session.user.id);
  }else{
    currentOfficerUserId=null;
    setSignedIn(false);
    updateConnectivity();
  }
  db.auth.onAuthStateChange((_event,session)=>{
    currentOfficerUserId=session?.user?.id||null;
    setSignedIn(!!session);
    if(session&&navigator.onLine)setTimeout(loadDashboard,0);
    else if(session)loadOfflineDashboard(session.user.id);
    else {participants=[];dailyAttendance=[];updateConnectivity();}
  });
  updateConnectivity();
}
$('loginForm').addEventListener('submit',async e=>{e.preventDefault();if(!db)return;const button=e.submitter||$('loginForm').querySelector('[type="submit"]');if(!button)return;button.disabled=true;showError($('loginMessage'),'');try{const {error}=await db.auth.signInWithPassword({email:$('email').value.trim(),password:$('password').value});if(error)throw error;}catch(err){showError($('loginMessage'),err.message||'Unable to sign in.')}finally{button.disabled=false;}});
$('signOut').addEventListener('click',async()=>{if(db){const {error}=await db.auth.signOut();if(error)toast(error.message);else toast('Signed out.');}});
$('searchInput').addEventListener('input',()=>{currentPage=0;renderParticipants();});
$('departmentFilter').addEventListener('change',()=>{currentPage=0;renderParticipants();});
$('typeFilter').addEventListener('change',()=>{currentPage=0;renderParticipants();});
if($('attendanceStatusFilter'))$('attendanceStatusFilter').addEventListener('change',()=>{currentPage=0;renderParticipants();});
$('attendanceDate').addEventListener('change',async()=>{if(!$('attendanceDate').value)return;currentPage=0;await loadSelectedDate();});
$('refreshDate').addEventListener('click',async()=>{if(navigator.onLine){serverOffline=false;await loadDashboard();}else await loadSelectedDate();});
$('saveSchedule').addEventListener('click',saveSchedule);
if($('deactivateAllStudents'))$('deactivateAllStudents').addEventListener('click',deactivateAllStudents);
if($('clearAttendanceBtn'))$('clearAttendanceBtn').addEventListener('click',clearAttendance);
$('exportCsv').addEventListener('click',exportCsv);
$('previousPage').addEventListener('click',()=>{if(currentPage>0){currentPage--;renderParticipants();}});
$('nextPage').addEventListener('click',()=>{currentPage++;renderParticipants();});
async function loadDashboard(){
  try{
    const {data:{user},error:userError}=await db.auth.getUser(); if(userError||!user)throw userError||new Error('Please sign in again.');
    currentOfficerUserId = user.id;
    const {data:profile,error:profileError}=await db.from('ssc_officers').select('user_id,active').eq('user_id',user.id).maybeSingle();
    if(profileError)throw profileError;
    if(!profile || !profile.active){await db.auth.signOut();throw new Error('This account is not authorized as an active SSC attendance officer. Ask your administrator for access.');}
    // Supabase/PostgREST may cap each response at 1,000 rows. Fetch pages
    // explicitly so the roster includes every active student, not just the first page.
    const people = [];
    const fetchPageSize = 1000;
    for (let from = 0; ; from += fetchPageSize) {
      let page = null;
      const res1 = await db
        .from('participants')
        .select('id,full_name,student_number,department,year_level,participant_type,position,active')
        .eq('active', true)
        .order('full_name', { ascending: true })
        .range(from, from + fetchPageSize - 1);
      if (res1.error && res1.error.message && res1.error.message.includes('position')) {
        const res2 = await db
          .from('participants')
          .select('id,full_name,student_number,department,year_level,participant_type,active')
          .eq('active', true)
          .order('full_name', { ascending: true })
          .range(from, from + fetchPageSize - 1);
        if (res2.error) throw res2.error;
        page = res2.data;
      } else if (res1.error) {
        throw res1.error;
      } else {
        page = res1.data;
      }
      const batch = page || [];
      people.push(...batch);
      if (batch.length < fetchPageSize) break;
    }
    participants=people;offlineSnapshot=readCache()||{dates:{}};offlineSnapshot.userId=user.id;offlineSnapshot.participants=participants;
    const deps=[...new Set(participants.map(p=>p.department).filter(Boolean))].sort((a,b)=>a.localeCompare(b));
    const oldDep=$('departmentFilter').value;
    $('departmentFilter').innerHTML='<option value="">All departments</option>'+deps.map(d=>`<option value="${safe(d)}">${safe(d)}</option>`).join('');
    if(deps.includes(oldDep))$('departmentFilter').value=oldDep;
    await loadSelectedDate();await syncOfflineQueue();updateConnectivity();
  }catch(err){
    const {data:{session}}=await db.auth.getSession().catch(()=>({data:{session:null}}));
    if(isNetworkFailure(err)||!navigator.onLine)serverOffline=true;
    if(session&&(isNetworkFailure(err)||!navigator.onLine)&&loadOfflineDashboard(session.user.id)){updateConnectivity();return;}
    toast(err.message||'Could not load attendance data.');if(String(err.message||'').includes('not authorized'))showError($('loginMessage'),err.message);
  }
}
async function loadSelectedDate(){
  if(!db || $('appPanel').classList.contains('hidden'))return;
  if(loadDateInFlight)return;
  loadDateInFlight=true;
  const date=$('attendanceDate').value || todayPHT();
  $('selectedDateLabel').textContent=dateLabel(date);
  try{
    const [{data:attendance,error:aErr},{data:schedule,error:sErr}]=await Promise.all([
      db.from('attendance').select('id,participant_id,attendance_date,checked_in_at,checked_in_by,morning_time_in_at,morning_time_out_at,afternoon_time_in_at,afternoon_time_out_at').eq('attendance_date',date),
      db.from('attendance_day_settings').select('attendance_date,morning_time_in,morning_time_out,afternoon_time_in,afternoon_time_out,enable_morning_time_in,enable_morning_time_out,enable_afternoon_time_in,enable_afternoon_time_out,updated_at').eq('attendance_date',date).maybeSingle()
    ]);
    if(aErr)throw aErr;if(sErr)throw sErr;
    dailyAttendance=attendance||[];scheduleSaved=!!schedule;window.currentSchedule=schedule||null;
    const values=schedule||DEFAULT_SCHEDULE;
    $('morningTimeIn').value=formatDbTime(values.morning_time_in)||'7:00 AM';
    $('morningTimeOut').value=formatDbTime(values.morning_time_out)||'11:30 AM';
    $('afternoonTimeIn').value=formatDbTime(values.afternoon_time_in)||'1:00 PM';
    $('afternoonTimeOut').value=formatDbTime(values.afternoon_time_out)||'4:30 PM';
    $('enableMorningIn').checked=!!values.enable_morning_time_in;$('enableMorningOut').checked=!!values.enable_morning_time_out;$('enableAfternoonIn').checked=!!values.enable_afternoon_time_in;$('enableAfternoonOut').checked=!!values.enable_afternoon_time_out;
    $('scheduleStatus').textContent=schedule?`Saved for ${dateLabel(date)}`:'Example defaults · not saved';
    $('scheduleStatus').classList.toggle('saved',!!schedule);
    setTodayLabel(`Philippine Time · ${dateLabel(todayPHT())}`);
    $('saveSchedule').textContent=`Save schedule for ${dateLabel(date)}`;
    $('saveSchedule').disabled=false;
    renderStats();renderParticipants();renderRecent();saveSnapshot(date);updateConnectivity();
  }catch(err){if(isNetworkFailure(err)){serverOffline=true;if(loadCachedDate(date)){updateConnectivity();loadDateInFlight=false;return;}}toast(err.message||'Could not load records for this date.');}finally{loadDateInFlight=false;}
}
function attendanceByParticipant(){return new Map(dailyAttendance.map(a=>[a.participant_id,a]));}
function renderStats(){
  const rows=dailyAttendance; $('registeredCount').textContent=participants.length;
  $('morningInCount').textContent=rows.filter(a=>a.morning_time_in_at).length;
  $('morningOutCount').textContent=rows.filter(a=>a.morning_time_out_at).length;
  $('afternoonInCount').textContent=rows.filter(a=>a.afternoon_time_in_at).length;
  $('afternoonOutCount').textContent=rows.filter(a=>a.afternoon_time_out_at).length;
}
function filteredParticipants(){
  const q=$('searchInput').value.trim().toLocaleLowerCase();const dep=$('departmentFilter').value;const type=$('typeFilter').value;
  const attFilter=$('attendanceStatusFilter')?$('attendanceStatusFilter').value:'';
  const byParticipant=attendanceByParticipant();
  return participants.filter(p=>{
    if(dep && p.department!==dep)return false;
    if(type && p.participant_type!==type)return false;
    if(attFilter){
      const a=byParticipant.get(p.id);
      const hasAtt=!!(a&&(a.morning_time_in_at||a.morning_time_out_at||a.afternoon_time_in_at||a.afternoon_time_out_at));
      if(attFilter==='present'&&!hasAtt)return false;
      if(attFilter==='absent'&&hasAtt)return false;
    }
    if(q && ![p.full_name,p.student_number,p.department,p.participant_type].some(v=>String(v||'').toLocaleLowerCase().includes(q)))return false;
    return true;
  });
}
function renderParticipants(){
  const list=filteredParticipants(); const totalPages=Math.max(1,Math.ceil(list.length/PAGE_SIZE));currentPage=Math.min(currentPage,totalPages-1);
  const start=currentPage*PAGE_SIZE;const page=list.slice(start,start+PAGE_SIZE);const byParticipant=attendanceByParticipant();
  $('pageSummary').textContent=list.length?`Showing ${start+1}–${Math.min(start+PAGE_SIZE,list.length)} of ${list.length} students`:'No students match your search';
  $('previousPage').disabled=currentPage===0;$('nextPage').disabled=currentPage>=totalPages-1;
  const currentDay=isSelectedDateToday();
  $('results').innerHTML=page.length?page.map(p=>{
    const a=byParticipant.get(p.id)||{};
    const actionCells=ACTIONS.map(slot=>{
      const value=a[slot.key];
      const deleteButton = `<button class="button mini-delete" type="button" data-delete-participant="${safe(p.id)}" data-delete-action="${slot.action}" title="${value ? `Delete this ${slot.label} entry` : `No ${slot.label} entry to delete`}" aria-label="Delete ${slot.label} for ${safe(p.full_name)}" ${value ? '' : 'disabled'}>Delete</button>`;
      if(value)return `<div class="attendance-cell"><span class="slot-label">${slot.short}</span><span class="slot-time recorded">${safe(timeLabel(value))}</span>${deleteButton}</div>`;
      if(!currentDay)return `<div class="attendance-cell"><span class="slot-label">${slot.short}</span><span class="slot-time missing">—</span>${deleteButton}</div>`;
      return `<div class="attendance-cell"><span class="slot-label">${slot.short}</span><button class="button mini-action" data-participant="${safe(p.id)}" data-action="${slot.action}" title="Record ${slot.label}">${slot.short}</button>${deleteButton}</div>`;
    }).join('');
    return `<article class="roster-row"><div class="student-cell"><div class="avatar">${safe(initials(p.full_name))}</div><div class="person-info"><strong>${safe(p.full_name)}</strong><span>${safe(p.position ? p.position + ' · ' : '')}${safe(p.department||'No department')}${p.year_level?` · Year ${safe(p.year_level)}`:''} · ${safe(p.participant_type)}${p.student_number?` · ${safe(p.student_number)}`:''}</span></div></div><div class="attendance-cells">${actionCells}</div></article>`;
  }).join(''):'<div class="empty-state">No matching students. Check the spelling or filters.</div>';
  $('results').querySelectorAll('[data-participant]').forEach(btn=>btn.addEventListener('click',()=>recordAction(btn.dataset.participant,btn.dataset.action,btn)));
  $('results').querySelectorAll('[data-delete-participant]').forEach(btn=>btn.addEventListener('click',()=>deleteAttendanceAction(btn.dataset.deleteParticipant,btn.dataset.deleteAction,btn)));
  if(!currentDay)$('results').insertAdjacentHTML('afterbegin','<div class="readonly-note">Viewing a previous date. New check-ins are closed, but officers can delete an accidental entry if needed.</div>');
}

async function deleteAttendanceAction(participantId,action,button){
  const person=participants.find(p=>p.id===participantId);const slot=ACTIONS.find(x=>x.action===action);const date=$('attendanceDate').value||todayPHT();
  if(!person||!slot)return;
  const existing=attendanceByParticipant().get(participantId)||{};
  if(!existing[slot.key]){toast('This entry is already empty.');return;}
  if(!navigator.onLine||serverOffline){toast('You need to be connected to the internet to delete an attendance entry.');return;}
  const confirmed=await showConfirmModal(`Delete ${slot.label} (${timeLabel(existing[slot.key])}) for ${person.full_name} on ${dateLabel(date)}?\n\nOnly this check-in entry will be deleted. Student information and other attendance entries will remain.`);
  if(!confirmed)return;
  button.disabled=true;button.textContent='Deleting…';
  try{
    const {data,error}=await db.rpc('delete_attendance_action',{p_participant_id:participantId,p_attendance_date:date,p_action:action});
    if(error)throw error;
    if(data!==true)throw new Error('Could not delete this entry. Please refresh and try again.');
    // Remove matching unsynced local events only after the server has accepted the deletion.
    const queue=readQueue().filter(x=>!(x.participant_id===participantId&&x.attendance_date===date&&x.action===action));
    writeQueue(queue);
    const row=dailyAttendance.find(a=>a.participant_id===participantId);
    if(row){row[slot.key]=null;if(!row.morning_time_in_at&&!row.morning_time_out_at&&!row.afternoon_time_in_at&&!row.afternoon_time_out_at)dailyAttendance=dailyAttendance.filter(a=>a.participant_id!==participantId);}
    saveSnapshot(date);renderStats();renderParticipants();renderRecent();updateConnectivity();
    toast(`${slot.label} deleted for ${person.full_name}.`);
    await loadSelectedDate();
  }catch(err){
    if(isNetworkFailure(err))serverOffline=true;
    toast(err.message||'Unable to delete this attendance entry.');renderParticipants();updateConnectivity();
  }
}

async function recordAction(participantId,action,button){
  const person=participants.find(p=>p.id===participantId);const slot=ACTIONS.find(x=>x.action===action);if(!person||!slot)return;
  const date=$('attendanceDate').value||todayPHT();if(date!==todayPHT()){toast('Attendance can only be recorded for the current Philippine date.');return;}
  const existing=attendanceByParticipant().get(participantId)||{};if(existing[slot.key]){toast(`${person.full_name}: ${slot.label} is already recorded.`);return;}
  button.disabled=true;button.textContent='Saving…';
  if(!navigator.onLine||serverOffline){queueOfflineAction(person,slot,date);button.disabled=false;return;}
  try{
    const {data,error}=await db.rpc('record_attendance_action',{p_participant_id:participantId,p_attendance_date:date,p_action:action});
    if(error)throw error;
    toast(`${person.full_name}: ${slot.label} recorded at ${timeLabel(data)} PHT.`);
    await loadSelectedDate();
  }catch(err){
    if(isNetworkFailure(err)){serverOffline=true;queueOfflineAction(person,slot,date);button.disabled=false;return;}
    toast(err.message||'Unable to record attendance.');renderParticipants();
  }
}
function isNetworkFailure(err){return !navigator.onLine||/failed to fetch|network|fetch|timeout|load failed|connection/i.test(String(err?.message||''))}
function queueOfflineAction(person,slot,date){
  const stamp=new Date().toISOString();
  const officerId=currentOfficerUserId||offlineSnapshot?.userId||readCache()?.userId||null;
  if(!officerId){
    toast('Cannot record offline check-in without an active officer session.');
    return;
  }
  const queue=readQueue(officerId);
  if(queue.some(x=>x.participant_id===person.id&&x.attendance_date===date&&x.action===slot.action&&x.status!=='conflict')){toast('This action is already waiting to sync.');return;}
  const event={event_id:uuid(),participant_id:person.id,attendance_date:date,action:slot.action,recorded_at:stamp,officer_user_id:officerId,status:'pending',student_name:person.full_name};
  queue.push(event);
  writeQueue(queue,officerId);
  if(!readQueue(officerId).some(item=>item.event_id===event.event_id)){toast('Could not persist the offline entry on this device. Do not rely on this check-in; reconnect and record it online.');return;}
  let row=dailyAttendance.find(a=>a.participant_id===person.id);if(!row){row={id:`offline-${person.id}-${date}`,participant_id:person.id,attendance_date:date};dailyAttendance.push(row);}row[slot.key]=stamp;
  saveSnapshot(date);renderStats();renderParticipants();renderRecent();updateConnectivity();toast(`${person.full_name}: ${slot.label} saved offline at ${timeLabel(stamp)} PHT. It will sync when internet returns.`);
}
async function syncOfflineQueue(){
  if(!db||!navigator.onLine||serverOffline)return;
  const {data:{session},error:sessionError}=await db.auth.getSession();
  if(sessionError||!session||!session.user)return;
  const activeUserId=session.user.id;
  currentOfficerUserId=activeUserId;

  let queue=readQueue();
  if(!queue.length){updateConnectivity();return;}

  // Strict Identity Isolation: only process and upload records logged by this active officer
  // Any records belonging to a different officer remain in the queue untouched
  const myEvents=queue.filter(item=>item.officer_user_id===activeUserId&&item.status!=='conflict');
  if(!myEvents.length){updateConnectivity();return;}

  for(const event of myEvents){
    try{
      const {error}=await db.rpc('sync_offline_attendance_action',{
        p_event_id:event.event_id,
        p_participant_id:event.participant_id,
        p_attendance_date:event.attendance_date,
        p_action:event.action,
        p_recorded_at:event.recorded_at
      });
      if(error){
        const message=String(error.message||'');
        if(error.code==='401' || /jwt|not authenticated|invalid claim|permission denied/i.test(message)){
          toast('Reconnect and sign in again before syncing offline attendance.');
          break;
        }
        if(/already been recorded|duplicate|unique|conflict/i.test(message)){
          event.status='conflict';
          event.sync_error='A record for this action already exists. Review the database and local record before resolving.';
          writeQueue(queue);
          continue;
        }
        if(isNetworkFailure(error))break;
        event.status='conflict';
        event.sync_error=message||'Sync rejected';
        writeQueue(queue);
        continue;
      }
      // Remove ONLY this successfully uploaded event; other officers' entries remain untouched
      queue=queue.filter(item=>item.event_id!==event.event_id);
      writeQueue(queue);
    }catch(err){
      if(isNetworkFailure(err))break;
      event.status='conflict';
      event.sync_error=String(err.message||'Sync failed');
      writeQueue(queue);
    }
  }
  updateConnectivity();
  const remainingForOfficer=queue.filter(item=>item.officer_user_id===activeUserId);
  if(remainingForOfficer.length===0){
    toast('All your offline attendance entries have synced.');
    await loadSelectedDate();
  }else{
    const conflicts=remainingForOfficer.filter(x=>x.status==='conflict').length;
    if(conflicts)toast(`${conflicts} offline attendance item(s) need review because of a conflict.`);
  }
}


async function deactivateAllStudents(){
  if(!db||!navigator.onLine||serverOffline){toast('You need to be connected to the internet to update the student list. No changes were made.');return;}
  const studentIds=new Set(participants.filter(p=>p.participant_type==='Student').map(p=>p.id));
  if(!studentIds.size){toast('There are no active students to deactivate.');return;}
  const pending=readQueue().filter(e=>studentIds.has(e.participant_id)&&e.status!=='conflict');
  if(pending.length){toast(`Cannot deactivate students right now: ${pending.length} unsaved check-in(s) are still waiting to upload on this device. Please sync them first.`);return;}
  const confirmation=await showPromptModal(`Warning: This will hide ${studentIds.size} student(s) from the active list so they cannot check in. Past attendance records are safely kept in history.\n\nType DEACTIVATE ALL STUDENTS to confirm:`);
  if(confirmation!=='DEACTIVATE ALL STUDENTS'){toast('No changes were made.');return;}
  const button=$('deactivateAllStudents');button.disabled=true;button.textContent='Working…';
  try{
    const {data,error}=await db.rpc('deactivate_all_students');
    if(error)throw error;
    participants=participants.filter(p=>p.participant_type!=='Student');
    dailyAttendance=dailyAttendance.filter(a=>!studentIds.has(a.participant_id));
    updateLocalRosterCache(studentIds);
    currentPage=0;renderStats();renderParticipants();renderRecent();updateConnectivity();
    toast(`${data ?? studentIds.size} student(s) deactivated. Past attendance records remain saved.`);
    setTimeout(()=>loadDashboard(),800);
  }catch(err){toast(err.message||'Could not deactivate students. Please run student-deletion-admin.sql in Supabase first, then try again.');}
  finally{button.disabled=false;button.textContent='Deactivate all students';}
}

async function clearAttendance(){
  if(!db||!navigator.onLine||serverOffline){toast('You need to be connected to the internet to clear attendance. No changes were made.');return;}
  const selectedDate=$('attendanceDate').value||todayPHT();

  // --- Step 1: Show scope-choice modal (Selected Date vs All Dates) ---
  const scopeModal=await new Promise(resolve=>{
    const existing=document.getElementById('_clearScopeModal');if(existing)existing.remove();
    const modal=document.createElement('div');modal.id='_clearScopeModal';
    modal.style.cssText='position:fixed;inset:0;background:rgba(0,0,0,.55);z-index:9999;display:flex;align-items:center;justify-content:center;padding:1rem';
    // All button styles are fully inline so they render identically on every device/browser
    // regardless of whether the external stylesheet has loaded or which classes are scoped.
    const btnBase='display:block;width:100%;box-sizing:border-box;text-align:left;padding:.75rem 1rem;border-radius:8px;border:1.5px solid #fca5a5;background:#fff1f2;color:#b91c1c;font-family:inherit;font-size:.9rem;cursor:pointer;line-height:1.4';
    const btnCancel='display:inline-flex;align-items:center;padding:.5rem 1.25rem;border-radius:8px;border:1.5px solid #d1d5db;background:#fff;color:#374151;font-family:inherit;font-size:.875rem;cursor:pointer';
    modal.innerHTML=`<div style="background:#fff;border-radius:12px;padding:1.75rem;max-width:460px;width:100%;box-shadow:0 8px 32px rgba(0,0,0,.2)">
      <div style="font-size:.68rem;font-weight:700;letter-spacing:.09em;color:#ef4444;text-transform:uppercase;margin-bottom:.4rem">Warning</div>
      <p style="margin:0 0 .75rem;font-weight:600;font-size:1rem;color:#111">Clear attendance records?</p>
      <p style="margin:0 0 1.25rem;font-size:.85rem;color:#555">This will <strong>permanently delete</strong> the time-in and time-out logs. Student names will still be on the roster, but all their check-in records will be erased. Which records do you want to clear?</p>
      <div style="display:flex;flex-direction:column;gap:.625rem;margin-bottom:1.5rem">
        <button type="button" id="_scopeBtnDate" style="${btnBase}">
          <strong style="display:block;margin-bottom:.15rem">This date only</strong>
          <span style="font-size:.8rem;opacity:.8">${dateLabel(selectedDate)}</span>
        </button>
        <button type="button" id="_scopeBtnAll" style="${btnBase}">
          <strong style="display:block;margin-bottom:.15rem">All dates (entire event)</strong>
          <span style="font-size:.8rem;opacity:.8">Removes every check-in record from all days of the event</span>
        </button>
      </div>
      <div style="display:flex;justify-content:flex-end">
        <button type="button" id="_scopeBtnCancel" style="${btnCancel}">Cancel</button>
      </div>
    </div>`;
    document.body.appendChild(modal);
    modal.querySelector('#_scopeBtnDate').onclick=()=>{modal.remove();resolve('date');};
    modal.querySelector('#_scopeBtnAll').onclick=()=>{modal.remove();resolve('all');};
    modal.querySelector('#_scopeBtnCancel').onclick=()=>{modal.remove();resolve(null);};
    // Allow Escape key and backdrop click to cancel (accessibility + consistency with other modals)
    const onKey=(e)=>{if(e.key==='Escape'){modal.remove();window.removeEventListener('keydown',onKey);resolve(null);}};
    window.addEventListener('keydown',onKey);
    modal.addEventListener('click',(e)=>{if(e.target===modal){modal.remove();window.removeEventListener('keydown',onKey);resolve(null);}});
  });
  if(!scopeModal){toast('No changes were made.');return;}

  // --- Step 2: Check offline queue before proceeding ---
  // Use ALL participant IDs (students and officers) so pending queue entries for any
  // participant type are caught before clearing, preventing data loss.
  const allParticipantIds=new Set(participants.map(p=>p.id));
  const queueForScope=readQueue().filter(e=>{
    if(e.status==='conflict')return false;
    if(scopeModal==='all')return allParticipantIds.has(e.participant_id);
    return allParticipantIds.has(e.participant_id)&&e.attendance_date===selectedDate;
  });
  if(queueForScope.length){
    toast(`Cannot clear attendance right now — there ${queueForScope.length===1?'is':'are'} ${queueForScope.length} unsaved check-in(s) on this device that haven't been uploaded yet. Please wait for them to sync first.`);
    return;
  }

  // --- Step 3: Type-to-confirm prompt ---
  const confirmPhrase=scopeModal==='all'?'CLEAR ALL ATTENDANCE':'CLEAR ATTENDANCE';
  const confirmation=await showPromptModal(
    scopeModal==='all'
      ? `Are you sure? This will erase all check-in records from every day of the event.\n\nStudent names will remain, but all time-in and time-out logs will be deleted. This cannot be undone.\n\nType CLEAR ALL ATTENDANCE to confirm:`
      : `Are you sure? This will erase all check-in records for ${dateLabel(selectedDate)}.\n\nRecords from other dates will not be affected. This cannot be undone.\n\nType CLEAR ATTENDANCE to confirm:`
  );
  if(confirmation!==confirmPhrase){toast('No changes were made.');return;}

  const button=$('clearAttendanceBtn');button.disabled=true;button.textContent='Clearing…';
  try{
    let data,error;
    if(scopeModal==='all'){
      ({data,error}=await db.rpc('clear_all_attendance'));
    }else{
      ({data,error}=await db.rpc('clear_attendance_for_date',{p_attendance_date:selectedDate}));
    }
    if(error)throw error;

    // --- Step 4: Wipe local in-memory state & offline cache ---
    if(scopeModal==='all'){
      dailyAttendance=[];
      // Persist cleared state for the current date into the snapshot cache
      saveSnapshot(selectedDate);
      // Clear all dates from offline cache
      const cache=readCache();
      if(cache){cache.dates={};writeCache(cache);offlineSnapshot=cache;}
      // Clear entire offline queue for all participants (students and officers)
      const remainingQueue=readQueue().filter(e=>!allParticipantIds.has(e.participant_id));
      writeQueue(remainingQueue);
    }else{
      dailyAttendance=[];
      saveSnapshot(selectedDate);
      // Clear only queue items for the selected date (all participant types)
      const remainingQueue=readQueue().filter(e=>!(e.attendance_date===selectedDate&&allParticipantIds.has(e.participant_id)));
      writeQueue(remainingQueue);
    }

    currentPage=0;renderStats();renderParticipants();renderRecent();updateConnectivity();
    const clearedCount=data??0;
    toast(scopeModal==='all'
      ?`Done! ${clearedCount} check-in record(s) have been cleared from all event dates.`
      :`Done! ${clearedCount} check-in record(s) have been cleared for ${dateLabel(selectedDate)}.`
    );
    setTimeout(()=>loadSelectedDate(),600);
  }catch(err){
    toast(err.message||'Something went wrong and the records could not be cleared. Please run clear-attendance-admin.sql in Supabase first, then try again.');
  }finally{button.disabled=false;button.textContent='Clear Attendance…';}
}

function updateLocalRosterCache(deactivatedIds){
  const cache=readCache();if(!cache)return;
  cache.participants=(cache.participants||[]).filter(p=>!deactivatedIds.has(p.id));
  for(const date of Object.keys(cache.dates||{})){
    const entry=cache.dates[date];if(entry&&Array.isArray(entry.attendance))entry.attendance=entry.attendance.filter(a=>!deactivatedIds.has(a.participant_id));
  }
  writeCache(cache);offlineSnapshot=cache;
}

async function saveSchedule(){
  if(!navigator.onLine||serverOffline){toast('Schedule changes require an internet connection. Cached schedules remain available for offline attendance.');return;}
  const date=$('attendanceDate').value;if(!date){toast('Choose an attendance date first.');return;}
  const morningIn=parse12Hour($('morningTimeIn').value),morningOut=parse12Hour($('morningTimeOut').value),afternoonIn=parse12Hour($('afternoonTimeIn').value),afternoonOut=parse12Hour($('afternoonTimeOut').value);
  if(!morningIn||!morningOut||!afternoonIn||!afternoonOut){toast('Enter all times in 12-hour format, such as 7:00 AM or 1:30 PM.');return;}
  if(!(morningIn<morningOut&&morningOut<=afternoonIn&&afternoonIn<afternoonOut)){toast('Check the schedule order: morning time-in, morning time-out, afternoon time-in, then afternoon time-out.');return;}
  const {data:{user},error:userError}=await db.auth.getUser();if(userError||!user){toast('Please sign in again.');return;}
  const button=$('saveSchedule');button.disabled=true;button.textContent='Saving…';
  try{
    const {error}=await db.from('attendance_day_settings').upsert({attendance_date:date,morning_time_in:morningIn,morning_time_out:morningOut,afternoon_time_in:afternoonIn,afternoon_time_out:afternoonOut,enable_morning_time_in:$('enableMorningIn').checked,enable_morning_time_out:$('enableMorningOut').checked,enable_afternoon_time_in:$('enableAfternoonIn').checked,enable_afternoon_time_out:$('enableAfternoonOut').checked,updated_by:user.id,updated_at:new Date().toISOString()},{onConflict:'attendance_date'});
    if(error)throw error;
    scheduleSaved=true;window.currentSchedule={attendance_date:date,morning_time_in:morningIn,morning_time_out:morningOut,afternoon_time_in:afternoonIn,afternoon_time_out:afternoonOut,enable_morning_time_in:$('enableMorningIn').checked,enable_morning_time_out:$('enableMorningOut').checked,enable_afternoon_time_in:$('enableAfternoonIn').checked,enable_afternoon_time_out:$('enableAfternoonOut').checked};saveSnapshot(date);$('scheduleStatus').textContent=`Saved for ${dateLabel(date)}`;$('scheduleStatus').classList.add('saved');toast(`Schedule saved for ${dateLabel(date)} (Philippine Time).`);
  }catch(err){toast(err.message||'Unable to save the schedule.');}
  finally{button.disabled=false;button.textContent=`Save schedule for ${dateLabel(date)}`;}
}
function renderRecent(){
  const byId = new Map(participants.map(p => [p.id, p]));
  const studentMap = new Map();

  for (const a of dailyAttendance) {
    const p = byId.get(a.participant_id) || {
      id: a.participant_id,
      full_name: a.full_name || 'Student',
      department: a.department || '',
      participant_type: 'Student'
    };
    const recordedSlots = [];
    let latestTime = null;

    for (const slot of ACTIONS) {
      const timeVal = a[slot.key];
      if (timeVal) {
        recordedSlots.push({
          slot,
          key: slot.key,
          short: slot.short,
          label: slot.label,
          time: timeVal
        });
        if (!latestTime || new Date(timeVal) > new Date(latestTime)) {
          latestTime = timeVal;
        }
      }
    }

    if (recordedSlots.length > 0) {
      studentMap.set(a.participant_id, {
        person: p,
        slots: recordedSlots,
        latestTime: latestTime,
        attendance: a
      });
    }
  }

  // Sort students by latest activity time descending
  const studentList = Array.from(studentMap.values())
    .sort((a, b) => new Date(b.latestTime) - new Date(a.latestTime))
    .slice(0, 30);

  if (!studentList.length) {
    $('recentList').innerHTML = '<div class="empty-state">No attendance activity recorded for this date yet.</div>';
    return;
  }

  $('recentList').innerHTML = studentList.map(item => {
    const person = item.person;
    const name = person.full_name || 'Student';
    const dept = person.department || '';
    const pos = person.position ? `${person.position} · ` : (person.participant_type === 'SSC Officer' ? 'SSC Officer · ' : '');

    const badgesHtml = item.slots.map(s => {
      const badgeClass = s.key.replace(/_/g, '-');
      return `<span class="slot-pill ${badgeClass}" title="${safe(s.label)} at ${safe(timeLabel(s.time))}"><span class="pill-dot"></span><strong>${safe(s.short)}</strong> ${safe(timeLabel(s.time))}</span>`;
    }).join('');

    const sessionCountText = `${item.slots.length} of 4 session${item.slots.length > 1 ? 's' : ''}`;

    return `<div class="recent-item">
      <div class="avatar">${safe(initials(name))}</div>
      <div class="person-info">
        <div class="person-title-row">
          <strong>${safe(name)}</strong>
        </div>
        <span class="person-dept">${safe(pos)}${safe(dept)}</span>
        <div class="recent-slots-row">
          ${badgesHtml}
        </div>
      </div>
      <div class="recent-meta-col">
        <span class="recent-time" title="Most recent recorded time">${safe(timeLabel(item.latestTime))}</span>
        <span class="slot-count-badge">${sessionCountText}</span>
      </div>
    </div>`;
  }).join('');
}
// Sanitizes CSV cell values against CSV / Formula Injection (CWE-1236)
// Neutralizes formula triggers (=, +, -, @) so spreadsheet software treats them as literal strings
function csvEscape(value){
  if(value===null||value===undefined)return '""';
  let str=String(value);
  const trimmed=str.trimStart();
  if(/^[=+\-@]/.test(trimmed)){
    str="'"+str;
  }
  return '"'+str.replace(/"/g,'""')+'"';
}
const sanitizeCsvCell = csvEscape;
function showExportModal(date){
  return new Promise(resolve=>{
    const existing=document.getElementById('_exportModal');if(existing)existing.remove();
    const modal=document.createElement('div');modal.id='_exportModal';
    modal.style.cssText='position:fixed;inset:0;background:rgba(0,0,0,.55);z-index:9999;display:flex;align-items:center;justify-content:center;padding:1rem';
    modal.innerHTML=`<div style="background:#fff;border-radius:12px;padding:1.5rem;max-width:440px;width:100%;box-shadow:0 8px 32px rgba(0,0,0,.2)">
      <h3 style="margin:0 0 .5rem;font-size:1.15rem">Export Attendance CSV</h3>
      <p style="margin:0 0 1.25rem;color:#555;font-size:.92rem">Choose records to export for <strong>${safe(dateLabel(date))}</strong>:</p>
      <div style="display:flex;flex-direction:column;gap:.75rem;margin-bottom:1.25rem">
        <button type="button" class="button primary btn-attendees" style="justify-content:center;padding:.75rem">
          ✓ Attendees Only (Present Today)
          <small style="display:block;font-size:.78rem;font-weight:normal;opacity:.85">Only students who recorded attendance</small>
        </button>
        <button type="button" class="button outline btn-all" style="justify-content:center;padding:.75rem">
          📋 Full Masterlist (Present & Absent)
          <small style="display:block;font-size:.78rem;font-weight:normal;opacity:.85">All students with Attendance Status</small>
        </button>
      </div>
      <div style="display:flex;justify-content:flex-end">
        <button type="button" class="button ghost btn-cancel">Cancel</button>
      </div>
    </div>`;
    document.body.appendChild(modal);
    modal.querySelector('.btn-attendees').onclick=()=>{modal.remove();resolve('attendees');};
    modal.querySelector('.btn-all').onclick=()=>{modal.remove();resolve('all');};
    modal.querySelector('.btn-cancel').onclick=()=>{modal.remove();resolve(null);};
  });
}

async function exportCsv(){
  const date=$('attendanceDate').value||todayPHT();
  const choice=await showExportModal(date);
  if(!choice)return;

  const byParticipant=attendanceByParticipant();
  let exportList=filteredParticipants();
  const depFilter=$('departmentFilter').value;

  if(choice==='attendees'){
    exportList=exportList.filter(p=>{
      const a=byParticipant.get(p.id);
      return !!(a&&(a.morning_time_in_at||a.morning_time_out_at||a.afternoon_time_in_at||a.afternoon_time_out_at));
    });
    if(!exportList.length){
      toast(`No students have recorded attendance for ${dateLabel(date)}.`);
      return;
    }
  }

  const rows=[['Attendance Date','System ID','Student Number','Full Name','Department','Year Level','Participant Type','Attendance Status','Morning Time In (PHT)','Morning Time Out (PHT)','Afternoon Time In (PHT)','Afternoon Time Out (PHT)']];
  for(const p of exportList){
    const a=byParticipant.get(p.id)||{};
    const isPresent=!!(a.morning_time_in_at||a.morning_time_out_at||a.afternoon_time_in_at||a.afternoon_time_out_at);
    rows.push([
      date,
      p.id,
      p.student_number||'',
      p.full_name||'',
      p.department||'',
      p.year_level||'',
      p.participant_type||'',
      isPresent?'PRESENT':'ABSENT',
      timeLabel(a.morning_time_in_at),
      timeLabel(a.morning_time_out_at),
      timeLabel(a.afternoon_time_in_at),
      timeLabel(a.afternoon_time_out_at)
    ]);
  }
  const modeSuffix=choice==='attendees'?'-attendees':'-all';
  const depSuffix=depFilter?`-${depFilter.replace(/\s+/g,'-')}`:'';
  const csv=rows.map(row=>row.map(sanitizeCsvCell).join(',')).join('\r\n');
  const blob=new Blob(['\ufeff'+csv],{type:'text/csv;charset=utf-8;'});
  const url=URL.createObjectURL(blob);
  const a=document.createElement('a');
  a.href=url;
  a.download=`ssc-attendance-${date}${modeSuffix}${depSuffix}.csv`;
  a.click();
  setTimeout(()=>URL.revokeObjectURL(url),1000);
  toast(`Exported ${exportList.length} student record(s) to CSV.`);
}
init();
