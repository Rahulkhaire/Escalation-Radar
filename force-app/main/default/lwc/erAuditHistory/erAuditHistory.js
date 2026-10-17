import { LightningElement, api } from 'lwc';

export default class ErAuditHistory extends LightningElement {
    @api entries = [];

    get rows() {
        return (this.entries || []).map((e) => ({
            ...e,
            outcomeClass: e.outcome === 'FAILURE' ? 'slds-text-color_error' : e.outcome === 'SUCCESS' ? 'slds-text-color_success' : 'slds-text-color_weak'
        }));
    }
    get hasEntries() {
        return this.rows.length > 0;
    }
}
