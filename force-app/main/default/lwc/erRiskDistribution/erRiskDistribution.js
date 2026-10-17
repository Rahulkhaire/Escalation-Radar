import { LightningElement, api } from 'lwc';

const CATEGORIES = ['CRITICAL', 'HIGH', 'MEDIUM', 'LOW'];

export default class ErRiskDistribution extends LightningElement {
    @api distribution = {};

    get bars() {
        const d = this.distribution || {};
        const max = Math.max(1, ...CATEGORIES.map((c) => d[c] || 0));
        return CATEGORIES.map((category) => {
            const count = d[category] || 0;
            return {
                category,
                count,
                aria: `${category}: ${count} cases. Select to filter.`,
                barClass: `er-bar er-bar-${category.toLowerCase()}`,
                style: `width: ${Math.round((count / max) * 100)}%`
            };
        });
    }

    handleSelect(event) {
        this.dispatchEvent(new CustomEvent('categoryselect', { detail: event.currentTarget.dataset.category }));
    }
}
