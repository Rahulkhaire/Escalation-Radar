import { LightningElement, api } from 'lwc';

const LABELS = {
    DRAFT_CUSTOMER_UPDATE: 'Draft customer update',
    REASSIGN_CASE: 'Reassign case to queue',
    REQUEST_MANAGER_REVIEW: 'Request manager review',
    ESCALATE_CASE: 'Escalate case',
    SEND_SLACK_ALERT: 'Send Slack alert',
    ADD_INTERNAL_NOTE: 'Add internal note'
};

export default class ErActionPanel extends LightningElement {
    @api actions = [];
    @api canApprove = false;
    @api canExecute = false;

    get hasActions() {
        return this.items.length > 0;
    }
    get items() {
        // Buttons are a convenience only: the server re-checks permission, approval state and Case access for every call.
        return (this.actions || []).map((a) => {
            const pending = a.approvalStatus === 'Pending' && a.executionStatus === 'Not_Started';
            const ready = a.approvalStatus === 'Not_Required' && a.executionStatus === 'Not_Started';
            return {
                ...a,
                typeLabel: LABELS[a.actionType] || a.actionType,
                statusLabel: pending ? 'Awaiting approval' : a.executionStatus === 'Not_Started' ? (a.approvalStatus === 'Approved' ? 'Approved, queued' : 'Ready') : `${a.approvalStatus} / ${a.executionStatus}`,
                requestedByText: a.requestedBy ? `, requested by ${a.requestedBy}` : '',
                canDecide: pending && this.canApprove,
                canRun: ready && this.canExecute
            };
        });
    }

    handleApprove(event) {
        this.fire('actionapprove', event.target.dataset.id);
    }
    handleReject(event) {
        this.fire('actionreject', event.target.dataset.id);
    }
    handleRun(event) {
        this.fire('actionrun', event.target.dataset.id);
    }
    fire(name, id) {
        this.dispatchEvent(new CustomEvent(name, { detail: { id } }));
    }
}
