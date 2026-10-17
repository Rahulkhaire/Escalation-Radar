import { LightningElement } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { subscribe, unsubscribe, onError } from 'lightning/empApi';

import getSummary from '@salesforce/apex/ER_DashboardController.getSummary';
import getFilterOptions from '@salesforce/apex/ER_DashboardController.getFilterOptions';
import getCases from '@salesforce/apex/ER_DashboardController.getCases';
import getCaseDetail from '@salesforce/apex/ER_DashboardController.getCaseDetail';
import getApprovalQueue from '@salesforce/apex/ER_DashboardController.getApprovalQueue';
import getReadyToRun from '@salesforce/apex/ER_DashboardController.getReadyToRun';
import getAudit from '@salesforce/apex/ER_DashboardController.getAudit';
import getHealth from '@salesforce/apex/ER_DashboardController.getHealth';
import approveAction from '@salesforce/apex/ER_DashboardController.approveAction';
import rejectAction from '@salesforce/apex/ER_DashboardController.rejectAction';
import runAction from '@salesforce/apex/ER_DashboardController.runAction';
import reassessCase from '@salesforce/apex/ER_DashboardController.reassessCase';
import retryFailedAi from '@salesforce/apex/ER_DashboardController.retryFailedAi';

const CHANNEL = '/event/ER_Risk_Update__e';
const EVENT_REFRESH_DEBOUNCE_MS = 1500;
const STALE_AFTER_MS = 5 * 60 * 1000;
const STALE_CHECK_MS = 30 * 1000;
const DEFAULT_FILTERS = { searchText: '', priority: '', caseStatus: '', ownerId: '', category: '', assessmentStatus: '', sortField: 'score', sortDir: 'desc', pageNumber: 1, pageSize: 10 };

export default class EscalationRadarDashboard extends NavigationMixin(LightningElement) {
    summary;
    cases = { rows: [], total: 0, pageNumber: 1, pageSize: 10 };
    options = { priorities: [], statuses: [], owners: [] };
    health;
    approvalQueue = [];
    readyToRun = [];
    detail;
    audit = [];
    filters = { ...DEFAULT_FILTERS };
    loading = false;
    errorMessage;
    lastRefreshed;
    eventsConnected = false;
    liveText = '';
    subscription;
    refreshTimer;
    staleTimer;
    now = Date.now();
    staleMinutes = STALE_AFTER_MS / 60000;

    // ---------- lifecycle ----------
    connectedCallback() {
        this.loadOptions();
        this.refreshAll();
        this.subscribeToEvents();
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this.staleTimer = window.setInterval(() => {
            this.now = Date.now();
        }, STALE_CHECK_MS);
    }

    disconnectedCallback() {
        window.clearInterval(this.staleTimer);
        window.clearTimeout(this.refreshTimer);
        if (this.subscription) {
            unsubscribe(this.subscription, () => {});
        }
    }

    // ---------- getters ----------
    get distribution() {
        return this.summary ? this.summary.distribution : {};
    }
    get canApprove() {
        return !!(this.health && this.health.canApprove);
    }
    get canExecute() {
        return !!(this.health && this.health.canExecute);
    }
    get hasDetail() {
        return !!this.detail;
    }
    get tableColumnClass() {
        return this.hasDetail ? 'slds-col slds-size_1-of-1 slds-large-size_7-of-12' : 'slds-col slds-size_1-of-1';
    }
    get lastRefreshedText() {
        return this.lastRefreshed ? new Date(this.lastRefreshed).toLocaleTimeString() : '';
    }
    get isStale() {
        if (!this.lastRefreshed) {
            return false;
        }
        return this.now - this.lastRefreshed > STALE_AFTER_MS || !this.eventsConnected;
    }

    // ---------- data loading ----------
    async loadOptions() {
        try {
            const opts = await getFilterOptions();
            this.options = { priorities: opts.priorities, statuses: opts.statuses, owners: opts.owners };
        } catch (e) {
            this.errorMessage = this.reduce(e);
        }
    }

    async refreshAll() {
        this.loading = true;
        this.errorMessage = undefined;
        try {
            const [summary, cases, queue, ready, health] = await Promise.all([
                getSummary(),
                getCases({ filters: this.filters }),
                getApprovalQueue(),
                getReadyToRun(),
                getHealth()
            ]);
            this.summary = summary;
            this.cases = cases;
            this.approvalQueue = queue;
            this.readyToRun = ready;
            this.health = health;
            this.lastRefreshed = Date.now();
            this.now = this.lastRefreshed;
            if (this.detail) {
                await this.loadDetail(this.detail.row.assessmentId, true);
            }
        } catch (e) {
            this.errorMessage = this.reduce(e);
        } finally {
            this.loading = false;
        }
    }

    async loadDetail(assessmentId, silent) {
        try {
            const d = await getCaseDetail({ assessmentId });
            this.detail = d;
            this.audit = await getAudit({ caseId: d.row.caseId });
        } catch (e) {
            if (!silent) {
                this.errorMessage = this.reduce(e);
            } else {
                this.detail = undefined; // case no longer visible or monitored
            }
        }
    }

    // ---------- platform events ----------
    subscribeToEvents() {
        onError((error) => {
            this.eventsConnected = false;
            this.liveText = 'Live updates disconnected.';
            // eslint-disable-next-line no-console
            console.warn('empApi error', JSON.stringify(error));
        });
        subscribe(CHANNEL, -1, (message) => this.handleRiskEvent(message))
            .then((response) => {
                this.subscription = response;
                this.eventsConnected = true;
                this.liveText = 'Live updates on.';
            })
            .catch(() => {
                this.eventsConnected = false;
                this.liveText = 'Live updates unavailable; use Refresh.';
            });
    }

    handleRiskEvent(message) {
        // Events are at-least-once hints, not data: debounce and refetch authoritative state from the server.
        const p = message && message.data && message.data.payload;
        if (p) {
            this.liveText = `Live update: ${p.Risk_Category__c || ''} risk change received.`;
        }
        window.clearTimeout(this.refreshTimer);
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this.refreshTimer = window.setTimeout(() => this.refreshAll(), EVENT_REFRESH_DEBOUNCE_MS);
    }

    // ---------- handlers ----------
    handleRefresh() {
        this.refreshAll();
    }
    handleFilterChange(event) {
        const { field, value } = event.detail;
        this.filters = { ...this.filters, [field]: value, pageNumber: 1 };
        this.refreshAll();
    }
    handleReset() {
        this.filters = { ...DEFAULT_FILTERS };
        this.refreshAll();
    }
    handleCategorySelect(event) {
        this.filters = { ...this.filters, category: event.detail, pageNumber: 1 };
        this.refreshAll();
    }
    handleSort(event) {
        this.filters = { ...this.filters, sortField: event.detail.field, sortDir: event.detail.direction, pageNumber: 1 };
        this.refreshAll();
    }
    handlePage(event) {
        this.filters = { ...this.filters, pageNumber: event.detail };
        this.refreshAll();
    }
    handleCaseSelect(event) {
        this.loading = true;
        this.loadDetail(event.detail, false).finally(() => {
            this.loading = false;
        });
    }
    handleShowCase(event) {
        const row = (this.cases.rows || []).find((r) => r.caseId === event.detail);
        if (row) {
            this.loadDetail(row.assessmentId, false);
        } else {
            this.navigateToRecord(event.detail);
        }
    }
    handleCloseDetail() {
        this.detail = undefined;
        this.audit = [];
    }
    handleOpenRecord(event) {
        this.navigateToRecord(event.detail);
    }
    navigateToRecord(recordId) {
        this[NavigationMixin.Navigate]({ type: 'standard__recordPage', attributes: { recordId, objectApiName: 'Case', actionName: 'view' } });
    }

    // ---------- mutations ----------
    async handleDecide(event) {
        const { id, approve, comment } = event.detail;
        await this.decide(id, approve, comment);
    }
    handleInlineApprove(event) {
        return this.decide(event.detail.id, true, null);
    }
    handleInlineReject(event) {
        return this.decide(event.detail.id, false, null);
    }
    async decide(id, approve, comment) {
        try {
            if (approve) {
                await approveAction({ actionId: id, comment });
                this.toast('Action approved', 'Execution has been queued. The result appears in the audit history.', 'success');
            } else {
                await rejectAction({ actionId: id, comment });
                this.toast('Action rejected', 'No change was made to the case.', 'success');
            }
        } catch (e) {
            this.toast(approve ? 'Approval failed' : 'Rejection failed', this.reduce(e), 'error');
        }
        this.refreshAll();
    }
    async handleInlineRun(event) {
        try {
            await runAction({ actionId: event.detail.id });
            this.toast('Action queued', 'The action will run shortly.', 'success');
        } catch (e) {
            this.toast('Could not run action', this.reduce(e), 'error');
        }
        window.setTimeout(() => this.refreshAll(), 2500); // eslint-disable-line @lwc/lwc/no-async-operation
    }
    async handleReassess(event) {
        try {
            await reassessCase({ caseId: event.detail });
            this.toast('Reassessment queued', 'The score will update shortly.', 'success');
        } catch (e) {
            this.toast('Could not queue reassessment', this.reduce(e), 'error');
        }
    }
    async handleRetryFailed() {
        try {
            const n = await retryFailedAi();
            this.toast('Recovery started', `${n} failed analysis(es) re-queued.`, 'success');
        } catch (e) {
            this.toast('Could not start recovery', this.reduce(e), 'error');
        }
        this.refreshAll();
    }

    // ---------- helpers ----------
    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
    reduce(e) {
        if (!e) {
            return 'Unknown error';
        }
        if (e.body && e.body.message) {
            return e.body.message;
        }
        return e.message || 'Unexpected error';
    }
}
