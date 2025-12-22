/**
 * Print Server Web Interface JavaScript
 */

/**
 * Refresh server status and update dashboard
 */
async function refreshStatus() {
    try {
        const response = await fetch('/api/status');
        if (!response.ok) throw new Error('Failed to fetch status');

        const data = await response.json();
        updateDashboard(data);
    } catch (error) {
        console.error('Error refreshing status:', error);
        showToast('Failed to refresh status', 'error');
    }
}

/**
 * Refresh dashboard with visual feedback
 */
async function refreshDashboard() {
    const btn = document.getElementById('refreshBtn');
    if (!btn) return;

    // Add loading state
    btn.disabled = true;
    btn.classList.add('btn-refreshing');

    try {
        await refreshStatus();
        showToast('Dashboard refreshed', 'success');
    } catch (error) {
        console.error('Error refreshing dashboard:', error);
        showToast('Failed to refresh dashboard', 'error');
    } finally {
        // Remove loading state
        btn.disabled = false;
        btn.classList.remove('btn-refreshing');
    }
}

/**
 * Update dashboard with new status data
 */
function updateDashboard(data) {
    // Update uptime
    const uptimeEl = document.getElementById('uptime');
    if (uptimeEl && data.uptime !== undefined) {
        const hours = Math.floor(data.uptime / 3600);
        const minutes = Math.floor((data.uptime % 3600) / 60);
        uptimeEl.textContent = `${hours}h ${minutes}m`;
    }

    // Update WiFi status
    // Note: Full dashboard update would require more DOM manipulation
    // For now, we just refresh the page data
}

/**
 * Refresh print jobs list
 */
async function refreshJobs() {
    const filter = document.getElementById('statusFilter')?.value || 'all';

    try {
        const response = await fetch(`/api/jobs?status=${filter}`);
        if (!response.ok) throw new Error('Failed to fetch jobs');

        const jobs = await response.json();
        updateJobsTable(jobs);
        updateJobStats(jobs);
    } catch (error) {
        console.error('Error refreshing jobs:', error);
        showToast('Failed to refresh jobs', 'error');
    }
}

/**
 * Refresh jobs with visual feedback
 */
async function refreshJobsWithFeedback() {
    const btn = document.getElementById('refreshJobsBtn');
    if (!btn) return;

    // Add loading state
    btn.disabled = true;
    btn.classList.add('btn-refreshing');

    try {
        await refreshJobs();
        showToast('Jobs refreshed', 'success');
    } catch (error) {
        console.error('Error refreshing jobs:', error);
        showToast('Failed to refresh jobs', 'error');
    } finally {
        // Remove loading state
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
                <td colspan="7" class="text-center text-muted py-4">
                    <i class="bi bi-inbox fs-1"></i>
                    <p class="mt-2">No print jobs in queue</p>
                </td>
            </tr>
        `;
        return;
    }

    tbody.innerHTML = jobs.map(job => `
        <tr data-job-id="${job.id}" class="job-row">
            <td>${job.id}</td>
            <td>${escapeHtml(job.title)}</td>
            <td>${escapeHtml(job.user)}</td>
            <td>
                <span class="badge ${getStatusBadgeClass(job.state)}">
                    ${formatState(job.state)}
                </span>
            </td>
            <td>${job.pages ? `${job.pages_completed}/${job.pages}` : '-'}</td>
            <td>${job.created_at ? formatDate(job.created_at) : '-'}</td>
            <td>
                ${canCancel(job.state) ?
                    `<button class="btn btn-sm btn-danger" onclick="cancelJob(${job.id})">
                        <i class="bi bi-x-circle"></i> Cancel
                    </button>` :
                    '<span class="text-muted">-</span>'
                }
            </td>
        </tr>
    `).join('');
}

/**
 * Update job statistics
 */
function updateJobStats(jobs) {
    const pending = jobs.filter(j => ['pending', 'pending-held'].includes(j.state)).length;
    const processing = jobs.filter(j => ['processing', 'processing-stopped'].includes(j.state)).length;
    const completed = jobs.filter(j => ['completed', 'canceled', 'aborted'].includes(j.state)).length;

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
            method: 'DELETE'
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
 * Show a toast notification
 */
function showToast(message, type = 'info') {
    // Simple alert for now - could be replaced with proper toast library
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

// Initialize on page load
document.addEventListener('DOMContentLoaded', function() {
    console.log('Print Server Web Interface loaded');
});
