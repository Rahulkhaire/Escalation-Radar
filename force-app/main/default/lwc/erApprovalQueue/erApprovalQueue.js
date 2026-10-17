import { LightningElement, api } from 'lwc';

const LABELS = {
    DRAFT_CUSTOMER_UPDATE: 'Draft customer update',
    REASSIGN_CASE: 'Reassign case to queue',
    REQUEST_MANAGER_REVIEW: 'Request manager review',
    ESCALATE_CASE: 'Escalate case',
    SEND_SLACK_ALERT: 'Send Slack alert',
    ADD_INTERNAL_NOTE: 'Add internal note'
};

export default class ErApprovalQueue extends LightningElement {
    @api actions = [];
    @api canApprove = false;

    get items() {
        return (this.actions || []).map((a) => ({ ...a, typeLabel: LABELS[a.actionType] || a.actionType }));
    }
    get hasItems() {
        return this.items.length > 0;
    }
    get count() {
        return this.items.length;
    }
    comment(id) {
        const input = this.template.querySelector(`lightning-input[data-comment="${id}"]`);
        return input ? input.value : null;
    }
    handleApprove(event) {
        const id = event.target.dataset.id;
        this.dispatchEvent(new CustomEvent('decide', { detail: { id, approve: true, comment: this.comment(id) } }));
    }
    handleReject(event) {
        const id = event.target.dataset.id;
        this.dispatchEvent(new CustomEvent('decide', { detail: { id, approve: false, comment: this.comment(id) } }));
    }
    handleShow(event) {
        this.dispatchEvent(new CustomEvent('showcase', { detail: event.target.dataset.case }));
    }
}
