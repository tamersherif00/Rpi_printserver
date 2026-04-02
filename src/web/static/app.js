/**
 * Print Server Web Interface JavaScript
 * Includes connection monitoring, adaptive polling, and retry logic.
 */

// --- Connection State ---
let connectionOk = true;
let retryCount = 0;
const MAX_RETRIES = 3;
const BASE_INTERVAL = 10000;  // 10s normal polling (was 30s - too slow for job status)
const FAST_INTERVAL = 3000;   // 3s when recovering or jobs are active
const FETCH_TIMEOUT = 10000;  // 10s fetch timeout

/**
 * Set the connection status indicator in the navbar
 */
function setConnectionStatus(status) {
    const el = document.getElementById('connection-status');
    if (!el) return;

    const wasOffline = !connectionOk;
    connectionOk = status === 'connected';

    const config = {
        'connected':    { cls: 'bg-success', title: 'Connected', icon: 'bi-circle-fill' },
        'reconnecting': { cls: 'bg-warning', title: 'Reconnecting...', icon: 'bi-arrow-repeat' },
        'offline':      { cls: 'bg-danger',  title: 'Offline', icon: 'bi-circle-fill' },
    };
    const c = config[status] || config['offline'];

    el.className = `badge ${c.cls} ms-2`;
    el.title = c.title;
    el.innerHTML = `<i class="${c.icon}" style="font-size: 0.5rem;"></i>`;

    // Show recovery toast
    if (connectionOk && wasOffline) {
        showToast('Connection restored', 'success');
    }

    // Toggle CUPS error banner based on API response
    updateCupsErrorBanner(status === 'offline');
}

/**
 * Show/hide the CUPS error banner dynamically (for JS-polled updates)
 */
function updateCupsErrorBanner(show) {
    const banner = document.getElementById('cups-error-banner');
    if (banner) {
        banner.style.display = show ? 'block' : 'none';
    }
}

/**
 * Refresh server status and update dashboard
 */
async function refreshStatus() {
    try {
        const response = await fetch('/api/status', {
            signal: AbortSignal.timeout(FETCH_TIMEOUT),
        });
        if (!response.ok) throw new Error(`HTTP ${response.status}`);

        const data = await response.json();
        updateDashboard(data);
        setConnectionStatus('connected');
        retryCount = 0;

        // Check for CUPS degraded state
        if (data.server && data.server.cups_error) {
            updateCupsErrorBanner(true);
        } else {
            updateCupsErrorBanner(false);
        }
    } catch (error) {
        retryCount++;
        if (retryCount >= MAX_RETRIES) {
            setConnectionStatus('offline');
        } else {
            setConnectionStatus('reconnecting');
        }
        console.error('Status refresh failed:', error);
    }
}

/**
 * Refresh dashboard with visual feedback
 */
async function refreshDashboard() {
    const btn = document.getElementById('refreshBtn');
    if (!btn) return;

    btn.disabled = true;
    btn.classList.add('btn-refreshing');

    try {
        await refreshStatus();
        showToast('Dashboard refreshed', 'success');
    } catch (error) {
        console.error('Error refreshing dashboard:', error);
        showToast('Failed to refresh dashboard', 'error');
    } finally {
        btn.disabled = false;
        btn.classList.remove('btn-refreshing');
    }
}

/**
 * Update dashboard with new status data
 */
function updateDashboard(data) {
    if (!data.server) return;

    // Update uptime
    const uptimeEl = document.getElementById('uptime');
    if (uptimeEl && data.server.uptime !== undefined) {
        const hours = Math.floor(data.server.uptime / 3600);
        const minutes = Math.floor((data.server.uptime % 3600) / 60);
        uptimeEl.textContent = `${hours}h ${minutes}m`;
    }
}

/**
 * Refresh print jobs list
 */
async function refreshJobs() {
    const filter = document.getElementById('statusFilter')?.value || 'all';

    try {
        const response = await fetch(`/api/jobs?status=${filter}`, {
            signal: AbortSignal.timeout(FETCH_TIMEOUT),
        });
        if (!response.ok) throw new Error(`HTTP ${response.status}`);

        const jobs = await response.json();

        // Check for CUPS error in response
        if (jobs.error && jobs.code === 'CUPS_ERROR') {
            updateCupsErrorBanner(true);
            return;
        }

        updateJobsTable(jobs);
        updateJobStats(jobs);
        updateCupsErrorBanner(false);
        setConnectionStatus('connected');
        retryCount = 0;
    } catch (error) {
        retryCount++;
        if (retryCount >= MAX_RETRIES) {
            setConnectionStatus('offline');
        } else {
            setConnectionStatus('reconnecting');
        }
        console.error('Error refreshing jobs:', error);
    }
}

/**
 * Refresh jobs with visual feedback
 */
async function refreshJobsWithFeedback() {
    const btn = document.getElementById('refreshJobsBtn');
    if (!btn) return;

    btn.disabled = true;
    btn.classList.add('btn-refreshing');

    try {
        await refreshJobs();
        showToast('Jobs refreshed', 'success');
    } catch (error) {
        console.error('Error refreshing jobs:', error);
        showToast('Failed to refresh jobs', 'error');
    } finally {
        btn.disabled = false;
        btn.classList.remove('btn-refreshing');
    }
}

/**
 * Update jobs table with new data
 */
function updateJobsTable(jobs) {
    const tbody = document.querySelector('#jobsTable tbody');
    if (!tbody) return;

    if (jobs.length === 0) {
        tbody.innerHTML = `
            <tr>
                <td colspan="10" class="text-center text-muted py-4">
                    <i class="bi bi-inbox fs-1"></i>
                    <p class="mt-2">No print jobs in queue</p>
                </td>
            </tr>
        `;
        return;
    }

    tbody.innerHTML = jobs.map(job => {
        // Build the "From" cell: always show IP first, username as secondary
        let fromCell;
        const hasUser = job.user && !['anonymous', 'unknown', ''].includes(job.user);
        const hasHost = job.origin_host && job.origin_host.length > 0;
        if (hasHost && hasUser) {
            fromCell = `<i class="bi bi-pc-display-horizontal"></i> ${escapeHtml(job.origin_host)}<br><small class="text-muted">${escapeHtml(job.user)}</small>`;
        } else if (hasHost) {
            fromCell = `<i class="bi bi-pc-display-horizontal"></i> ${escapeHtml(job.origin_host)}`;
        } else if (hasUser) {
            fromCell = escapeHtml(job.user);
        } else {
            fromCell = '<span class="text-muted">local</span>';
        }

        // Status cell with state reasons (detailed) or state message (fallback)
        let statusCell = `<span class="badge ${getStatusBadgeClass(job.state)}">${formatState(job.state)}</span>`;
        if (job.state_message) {
            statusCell += `<br><small class="text-muted" title="${escapeHtml(job.state_reasons || job.state_message)}">${escapeHtml(truncate(job.state_message, 40))}</small>`;
        }

        return `
        <tr data-job-id="${job.id}" class="job-row">
            <td>${job.id}</td>
            <td title="${escapeHtml(job.title)}">${escapeHtml(truncate(job.title, 40))}</td>
            <td>${fromCell}</td>
            <td>${escapeHtml(job.printer_name || '-')}</td>
            <td>${statusCell}</td>
            <td>${job.pages ? `${job.pages_completed}/${job.pages}` : '-'}</td>
            <td>${job.size_display || '-'}</td>
            <td>${job.created_at ? formatDate(job.created_at) : '-'}</td>
            <td>${job.duration || '-'}</td>
            <td>
                ${canCancel(job.state) ?
                    `<button class="btn btn-sm btn-danger" onclick="cancelJob(${job.id})">
                        <i class="bi bi-x-circle"></i> Cancel
                    </button>` :
                    '<span class="text-muted">-</span>'
                }
            </td>
        </tr>
    `}).join('');
}

/**
 * Update job statistics and track active jobs for adaptive polling
 */
function updateJobStats(jobs) {
    const pending = jobs.filter(j => ['pending', 'pending-held'].includes(j.state)).length;
    const processing = jobs.filter(j => ['processing', 'processing-stopped'].includes(j.state)).length;
    const completed = jobs.filter(j => ['completed', 'canceled', 'aborted'].includes(j.state)).length;

    // Track active jobs so polling can speed up/slow down
    hasActiveJobs = processing > 0 || pending > 0;

    updateStatElement('stat-total', jobs.length);
    updateStatElement('stat-pending', pending);
    updateStatElement('stat-processing', processing);
    updateStatElement('stat-completed', completed);
}

function updateStatElement(id, value) {
    const el = document.getElementById(id);
    if (el) el.textContent = value;
}

/**
 * Filter jobs by status
 */
function filterJobs() {
    refreshJobs();
}

/**
 * Cancel a print job
 */
async function cancelJob(jobId) {
    if (!confirm(`Cancel job ${jobId}?`)) return;

    try {
        const response = await fetch(`/api/jobs/${jobId}`, {
            method: 'DELETE',
            signal: AbortSignal.timeout(FETCH_TIMEOUT),
        });

        const data = await response.json();

        if (response.ok) {
            showToast(`Job ${jobId} canceled`, 'success');
            refreshJobs();
        } else {
            showToast(data.error || 'Failed to cancel job', 'error');
        }
    } catch (error) {
        console.error('Error canceling job:', error);
        showToast('Failed to cancel job', 'error');
    }
}

/**
 * Get badge CSS class for job state
 */
function getStatusBadgeClass(state) {
    const classes = {
        'pending': 'bg-warning text-dark',
        'pending-held': 'bg-warning text-dark',
        'processing': 'bg-primary',
        'processing-stopped': 'bg-info',
        'completed': 'bg-success',
        'canceled': 'bg-secondary',
        'aborted': 'bg-danger'
    };
    return classes[state] || 'bg-secondary';
}

/**
 * Format job state for display
 */
function formatState(state) {
    return state.replace(/-/g, ' ').replace(/\b\w/g, l => l.toUpperCase());
}

/**
 * Check if job can be canceled
 */
function canCancel(state) {
    return !['completed', 'canceled', 'aborted'].includes(state);
}

/**
 * Format ISO date string for display
 */
function formatDate(isoString) {
    try {
        const date = new Date(isoString);
        return date.toLocaleString('en-US', {
            year: 'numeric',
            month: '2-digit',
            day: '2-digit',
            hour: '2-digit',
            minute: '2-digit'
        });
    } catch {
        return isoString;
    }
}

/**
 * Escape HTML to prevent XSS
 */
function escapeHtml(text) {
    const div = document.createElement('div');
    div.textContent = text;
    return div.innerHTML;
}

/**
 * Truncate a string to maxLen characters with ellipsis
 */
function truncate(text, maxLen) {
    if (!text) return '';
    if (text.length <= maxLen) return text;
    return text.substring(0, maxLen) + '...';
}

/**
 * Show a toast notification
 */
function showToast(message, type = 'info') {
    if (type === 'error') {
        console.error(message);
    } else {
        console.log(message);
    }

    // Create and show a Bootstrap toast if container exists
    const container = document.getElementById('toast-container');
    if (container) {
        const toast = document.createElement('div');
        toast.className = `toast align-items-center text-white bg-${type === 'error' ? 'danger' : 'success'}`;
        toast.setAttribute('role', 'alert');
        toast.innerHTML = `
            <div class="d-flex">
                <div class="toast-body">${escapeHtml(message)}</div>
                <button type="button" class="btn-close btn-close-white me-2 m-auto" data-bs-dismiss="toast"></button>
            </div>
        `;
        container.appendChild(toast);
        new bootstrap.Toast(toast).show();
        setTimeout(() => toast.remove(), 5000);
    }
}

// --- Adaptive Polling ---

// Track whether there are active (processing) jobs to poll faster
let hasActiveJobs = false;

/**
 * Start adaptive polling. Polls faster when:
 * - Connection is recovering (FAST_INTERVAL)
 * - Jobs are actively processing (FAST_INTERVAL) - so status updates appear quickly
 * - Otherwise uses BASE_INTERVAL to reduce load on the Pi
 */
function startPolling() {
    const isDashboard = !!document.getElementById('uptime');
    const isQueue = !!document.getElementById('jobsTable');

    async function poll() {
        if (isDashboard) {
            await refreshStatus();
        } else if (isQueue) {
            await refreshJobs();
        }

        // Poll faster when disconnected OR when jobs are actively printing
        const interval = (!connectionOk || hasActiveJobs) ? FAST_INTERVAL : BASE_INTERVAL;
        setTimeout(poll, interval);
    }

    // Start first poll quickly to show current state
    setTimeout(poll, 1000);
}

// Initialize on page load
document.addEventListener('DOMContentLoaded', function() {
    console.log('Print Server Web Interface loaded');
    startPolling();
});
