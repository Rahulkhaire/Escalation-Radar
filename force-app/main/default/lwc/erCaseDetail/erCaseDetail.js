import { LightningElement, api } from 'lwc';

export default class ErCaseDetail extends LightningElement {
    @api detail;
    @api audit = [];
    @api canApprove = false;
    @api canExecute = false;

    get factors() {
        return ((this.detail && this.detail.factors) || []).map((f) => {
            const pct = f.maxPoints ? Math.round((f.points / f.maxPoints) * 100) : 0;
            return { ...f, pct, style: `width: ${pct}%` };
        });
    }
    get upliftValue() {
        return this.detail && this.detail.aiUplift ? this.detail.aiUplift : 0;
    }
    relay(event) {
        event.stopPropagation();
        this.dispatchEvent(new CustomEvent(event.type, { detail: event.detail }));
    }
    handleClose() {
        this.dispatchEvent(new CustomEvent('close'));
    }
    handleOpen() {
        this.dispatchEvent(new CustomEvent('openrecord', { detail: this.detail.row.caseId }));
    }
    handleReassess() {
        this.dispatchEvent(new CustomEvent('reassess', { detail: this.detail.row.caseId }));
    }
}
