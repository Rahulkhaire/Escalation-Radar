import { LightningElement, api } from 'lwc';

const COLUMNS = [
    { label: 'Case', fieldName: 'caseUrl', type: 'url', sortable: true, initialWidth: 110,
        typeAttributes: { label: { fieldName: 'caseNumber' }, target: '_blank' } },
    { label: 'Subject', fieldName: 'subject', wrapText: true },
    { label: 'Customer', fieldName: 'accountName' },
    { label: 'Priority', fieldName: 'priority', sortable: true, initialWidth: 95 },
    { label: 'Owner', fieldName: 'ownerName' },
    { label: 'Score', fieldName: 'score', type: 'number', sortable: true, initialWidth: 85, cellAttributes: { alignment: 'left' } },
    { label: 'Risk', fieldName: 'category', sortable: true, initialWidth: 105,
        cellAttributes: { class: { fieldName: 'categoryClass' } } },
    { label: 'SLA %', fieldName: 'slaPct', type: 'number', sortable: true, initialWidth: 85,
        typeAttributes: { maximumFractionDigits: 1 }, cellAttributes: { alignment: 'left' } },
    { label: 'Status', fieldName: 'assessmentStatus', sortable: true, initialWidth: 120 },
    { type: 'button', initialWidth: 100, typeAttributes: { label: 'Details', name: 'details', variant: 'base' } }
];
const SORT_KEYS = { caseUrl: 'caseNumber' };
const CATEGORY_CLASS = {
    CRITICAL: 'slds-text-color_error slds-text-title_bold',
    HIGH: 'slds-text-color_error',
    MEDIUM: 'slds-text-color_default',
    LOW: 'slds-text-color_success'
};

export default class ErCaseTable extends LightningElement {
    @api rows = [];
    @api total = 0;
    @api pageNumber = 1;
    @api pageSize = 10;
    @api loading = false;
    @api sortField = 'score';
    @api sortDirection = 'desc';
    columns = COLUMNS;

    get displayRows() {
        return (this.rows || []).map((r) => ({
            ...r,
            caseUrl: `/${r.caseId}`,
            categoryClass: CATEGORY_CLASS[r.category] || ''
        }));
    }
    get isEmpty() {
        return !this.loading && (!this.rows || this.rows.length === 0);
    }
    get totalPages() {
        return Math.max(1, Math.ceil((this.total || 0) / (this.pageSize || 10)));
    }
    get isFirst() {
        return this.pageNumber <= 1;
    }
    get isLast() {
        return this.pageNumber >= this.totalPages;
    }

    handleSort(event) {
        const field = SORT_KEYS[event.detail.fieldName] || event.detail.fieldName;
        this.dispatchEvent(new CustomEvent('sortchange', { detail: { field, direction: event.detail.sortDirection } }));
    }
    handlePrev() {
        this.dispatchEvent(new CustomEvent('pagechange', { detail: this.pageNumber - 1 }));
    }
    handleNext() {
        this.dispatchEvent(new CustomEvent('pagechange', { detail: this.pageNumber + 1 }));
    }
    handleRowAction(event) {
        if (event.detail.action.name === 'details') {
            this.dispatchEvent(new CustomEvent('caseselect', { detail: event.detail.row.assessmentId }));
        }
    }
}
