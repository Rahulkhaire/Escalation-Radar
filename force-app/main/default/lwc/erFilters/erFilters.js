import { LightningElement, api } from 'lwc';

const ALL = { label: 'All', value: '' };
const SEARCH_DEBOUNCE_MS = 400;

export default class ErFilters extends LightningElement {
    @api filters = {};
    @api options = { priorities: [], statuses: [], owners: [] };
    timer;

    get priorityOptions() {
        return [ALL, ...(this.options.priorities || []).map((v) => ({ label: v, value: v }))];
    }
    get statusOptions() {
        return [ALL, ...(this.options.statuses || []).map((v) => ({ label: v, value: v }))];
    }
    get ownerOptions() {
        return [ALL, ...(this.options.owners || [])];
    }
    get categoryOptions() {
        return [ALL, ...['LOW', 'MEDIUM', 'HIGH', 'CRITICAL'].map((v) => ({ label: v, value: v }))];
    }

    handleSearch(event) {
        const value = event.target.value;
        window.clearTimeout(this.timer);
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this.timer = window.setTimeout(() => this.emit('searchText', value), SEARCH_DEBOUNCE_MS);
    }
    handleCombo(event) {
        this.emit(event.target.name, event.detail.value);
    }
    handleReset() {
        this.dispatchEvent(new CustomEvent('reset'));
    }
    emit(field, value) {
        this.dispatchEvent(new CustomEvent('filterchange', { detail: { field, value } }));
    }
    disconnectedCallback() {
        window.clearTimeout(this.timer);
    }
}
